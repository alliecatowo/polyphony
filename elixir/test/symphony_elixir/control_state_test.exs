defmodule SymphonyElixir.ControlStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ControlState

  test "starts running and admits every supported role" do
    state = ControlState.new(now_ms: 1_000)

    assert state.state == :running
    assert ControlState.obligations_zero?(state)

    for role <- ControlState.admission_kinds() do
      assert %{decision: :admit, role: ^role, reason: :running} = ControlState.admission(state, role)
      assert ControlState.admit?(state, role)
    end
  end

  test "pause closes admission before active obligations drain" do
    state = ControlState.new(obligations: %{execution: 1, delivery: 1, cleanup: 1}, now_ms: 1)

    assert {:ok, pausing} = ControlState.request_pause(state, now_ms: 2)
    assert pausing.state == :pausing
    assert pausing.generation == 1

    for role <- ControlState.admission_kinds() do
      assert %{decision: :wait, reason: :pause_requested} = ControlState.admission(pausing, role)
    end

    assert {:ok, draining} = ControlState.begin_drain(pausing, now_ms: 3)
    assert draining.state == :draining

    assert {:ok, draining} =
             ControlState.set_obligations(draining, %{execution: 0}, now_ms: 4)

    assert draining.state == :draining

    assert {:ok, draining} =
             ControlState.set_obligations(draining, %{delivery: 0}, now_ms: 5)

    assert draining.state == :draining

    assert {:ok, paused} =
             ControlState.set_obligations(draining, %{cleanup: 0}, now_ms: 6)

    assert paused.state == :paused
    refute ControlState.admit?(paused, :worker)
  end

  test "a pause with no obligations reaches paused immediately" do
    assert {:ok, paused} = ControlState.transition(ControlState.new(), :pause, now_ms: 10)
    assert paused.state == :paused
    assert ControlState.admission(paused, :retry).decision == :wait
  end

  test "obligation counters cannot become negative" do
    state = ControlState.new(obligations: %{execution: 1})

    assert {:error, {:negative_obligation, :execution, -1}} =
             ControlState.update_obligation(state, :execution, -2)

    assert {:error, {:invalid_obligation_count, :delivery, -1}} =
             ControlState.set_obligations(state, %{delivery: -1})
  end

  test "graceful stop waits for obligations and then becomes stopped" do
    state = ControlState.new(obligations: %{execution: 1})

    assert {:ok, stopping} = ControlState.stop(state, now_ms: 20)
    assert stopping.state == :stopping
    assert ControlState.admission(stopping, :reconciler).decision == :reject

    assert {:ok, stopped} = ControlState.update_obligation(stopping, :execution, -1, now_ms: 21)
    assert stopped.state == :stopped
  end

  test "resume enters recovery and requires reconciliation before admission" do
    {:ok, paused} = ControlState.request_pause(ControlState.new(), now_ms: 30)
    assert paused.state == :paused

    assert {:ok, recovering} = ControlState.resume(paused, reason: :operator_resume, now_ms: 31)
    assert recovering.state == :recovering
    assert recovering.recovery_target == :running
    assert ControlState.admission(recovering, :worker).decision == :wait

    assert {:error, :reconciliation_required} = ControlState.complete_recovery(recovering)

    assert {:ok, running} = ControlState.complete_recovery(recovering, reconciled?: true, now_ms: 32)
    assert running.state == :running
    assert running.recovery_target == nil
    assert ControlState.admit?(running, :worker)
  end

  test "resume cancels a pending pause whose delivery obligations still need retries" do
    state = ControlState.new(obligations: %{delivery: 1}, now_ms: 33)
    assert {:ok, %{state: :pausing} = pausing} = ControlState.request_pause(state, now_ms: 34)
    assert {:ok, %{state: :recovering} = recovering} = ControlState.resume(pausing, now_ms: 35)
    assert recovering.recovery_target == :running
  end

  test "loading with recovery requested gates a previously running snapshot" do
    path = temporary_snapshot_path()
    on_exit(fn -> cleanup_snapshot(path) end)

    state = ControlState.new(path: path, metadata: %{project: "patches"}, now_ms: 40)
    assert :ok = ControlState.persist(state)

    assert {:ok, loaded} = ControlState.load(path)
    assert loaded.state == :running
    assert loaded.path == path
    assert loaded.metadata == %{"project" => "patches"}

    assert {:ok, recovering} = ControlState.load(path, recover?: true, now_ms: 41)
    assert recovering.state == :recovering
    assert recovering.recovery_reason == :restart_reconciliation
  end

  test "persistence replaces the snapshot atomically and leaves no temporary file" do
    path = temporary_snapshot_path()
    on_exit(fn -> cleanup_snapshot(path) end)

    first = ControlState.new(path: path, metadata: %{sequence: 1}, now_ms: 50)
    second = %{first | metadata: %{sequence: 2}, generation: 4, updated_at_ms: 51}

    assert :ok = ControlState.persist(first)
    assert :ok = ControlState.persist(second, path)
    assert {:ok, loaded} = ControlState.load(path)
    assert loaded.metadata == %{"sequence" => 2}
    assert loaded.generation == 4
    assert Path.wildcard(path <> ".tmp-*") == []

    assert {:ok, decoded} = path |> File.read() |> elem(1) |> Jason.decode()
    assert decoded["version"] == 1
    assert decoded["state"] == "running"
  end

  test "transition_and_persist writes the resulting control state" do
    path = temporary_snapshot_path()
    on_exit(fn -> cleanup_snapshot(path) end)

    state = ControlState.new(path: path, now_ms: 60)
    assert {:ok, paused} = ControlState.transition_and_persist(state, :pause, path, now_ms: 61)
    assert paused.state == :paused
    assert {:ok, loaded} = ControlState.load(path)
    assert loaded.state == :paused
  end

  test "hard stop returns only a project-scoped action description" do
    state = ControlState.new(obligations: %{execution: 1})

    assert {:ok, stopping, action} =
             ControlState.hard_stop(
               state,
               %{project: "patches", cgroup: "user.slice/polyphony-patches"},
               reason: :operator_requested,
               now_ms: 70
             )

    assert stopping.state == :stopping
    assert stopping.stop_mode == :hard
    assert stopping.stop_scope == %{project: "patches", cgroup: "user.slice/polyphony-patches"}
    assert action.type == :hard_stop
    assert action.operation == :terminate_project_cgroup
    assert action.scope.project == "patches"
    assert action.scope.cgroup == "user.slice/polyphony-patches"
    refute action.performed?
    refute action.os_kill_performed?
  end

  test "hard stop refuses an unscoped target and unknown admissions" do
    state = ControlState.new()

    assert {:error, :invalid_stop_scope} = ControlState.hard_stop(state, %{project: "patches"})

    assert %{decision: :reject, reason: {:invalid_admission_kind, "bot"}} =
             ControlState.admission(state, "bot")
  end

  defp temporary_snapshot_path do
    root = Path.join(System.tmp_dir!(), "symphony-control-state-#{System.unique_integer([:positive])}")
    Path.join(root, "control-state.json")
  end

  defp cleanup_snapshot(path) do
    path
    |> Path.dirname()
    |> File.rm_rf()
  end
end

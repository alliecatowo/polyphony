defmodule SymphonyElixir.OrchestratorControlTest do
  use SymphonyElixir.TestSupport

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 900_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-control-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "control-state.json")
    projection_path = Path.join(root, "github-projection.term")
    name = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        control_state_path: path,
        github_projection_path: projection_path
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(root)
    end)

    %{name: name, pid: pid, path: path, projection_path: projection_path}
  end

  test "pause closes admission immediately and persists", %{name: name, path: path} do
    assert {:ok, payload} = Orchestrator.control(name, :pause, %{})
    assert payload.state == :paused
    assert payload.admission.worker.decision == :wait
    assert File.exists?(path)
    refute GenServer.call(name, :worker_admission)
  end

  test "pause drains an accepted worker before becoming paused", %{name: name, pid: orchestrator} do
    worker = spawn(fn -> receive do: (:stop -> :ok) end)
    issue = issue("issue-drain", "#701")

    send(orchestrator, {:worker_started, issue.id, worker, issue, nil, [issue.id]})
    wait_until(fn -> map_size(:sys.get_state(orchestrator).running) == 1 end)

    assert {:ok, payload} = Orchestrator.control(name, :pause, %{})
    assert payload.state == :pausing
    assert payload.obligations.execution == 1
    refute GenServer.call(name, :worker_admission)

    send(worker, :stop)
    wait_until(fn -> Orchestrator.snapshot(name, 1_000).control.state == :paused end)

    snapshot = Orchestrator.snapshot(name, 1_000)
    assert snapshot.control.obligations.execution == 0
    assert snapshot.control.state == :paused
  end

  test "resume reconciles before reopening admission", %{name: name} do
    assert {:ok, %{state: :paused}} = Orchestrator.control(name, :pause, %{})
    assert {:ok, payload} = Orchestrator.control(name, :resume, %{})
    assert payload.state == :recovering
    assert payload.admission.worker.decision == :wait

    wait_until(fn -> Orchestrator.snapshot(name, 1_000).control.state == :running end)
    assert GenServer.call(name, :worker_admission)
  end

  test "hard stop rejects a foreign scope and terminates only this runtime's workers", %{
    name: name,
    pid: orchestrator
  } do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    issue = issue("issue-stop", "#702")
    send(orchestrator, {:worker_started, issue.id, worker, issue, nil, [issue.id]})
    wait_until(fn -> map_size(:sys.get_state(orchestrator).running) == 1 end)

    assert {:error, {:control_scope_mismatch, _expected}} =
             Orchestrator.control(name, :hard_stop, %{
               scope: %{project: "other", cgroup: "system.slice/other"}
             })

    assert Process.alive?(worker)

    assert {:ok, payload} =
             Orchestrator.control(name, :hard_stop, %{
               scope: %{project: "patches", cgroup: "polyphony-patches.service"}
             })

    assert payload.action.terminated_workers == 1
    wait_until(fn -> not Process.alive?(worker) end)
    wait_until(fn -> Orchestrator.snapshot(name, 1_000).control.state == :stopped end)
  end

  test "a paused state survives an orchestrator restart", %{
    name: name,
    pid: pid,
    path: path,
    projection_path: projection_path
  } do
    assert {:ok, %{state: :paused}} = Orchestrator.control(name, :pause, %{})
    :ok = GenServer.stop(pid)

    {:ok, restarted} =
      Orchestrator.start_link(
        name: name,
        control_state_path: path,
        github_projection_path: projection_path
      )

    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    assert Orchestrator.snapshot(name, 1_000).control.state == :paused
    refute GenServer.call(name, :worker_admission)
  end

  test "targeted webhook work coalesces durably and does not call providers while paused", %{
    name: name,
    pid: pid,
    path: control_path,
    projection_path: projection_path
  } do
    assert {:ok, %{state: :paused}} = Orchestrator.control(name, :pause, %{})

    targets = %{
      "issues" => [%{"node_id" => "I_kwDO-targeted", "number" => 703}],
      "pull_requests" => [],
      "checks" => [],
      "workflows" => [],
      "refs" => []
    }

    assert %{queue_size: 1, pending_size: 1} =
             Orchestrator.request_targeted_refresh(name, targets)

    assert %{queue_size: 1, pending_size: 1} =
             Orchestrator.request_targeted_refresh(name, targets)

    Process.sleep(30)
    snapshot = Orchestrator.snapshot(name, 1_000)
    assert snapshot.github_events.queue_size == 1
    refute snapshot.github_events.processing?

    :ok = GenServer.stop(pid)

    {:ok, restarted} =
      Orchestrator.start_link(
        name: name,
        control_state_path: control_path,
        github_projection_path: projection_path
      )

    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    restarted_snapshot = Orchestrator.snapshot(name, 1_000)
    assert restarted_snapshot.control.state == :paused
    assert restarted_snapshot.github_events.queue_size == 1
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Control test",
      description: "Exercise runtime controls",
      state: "In Progress",
      url: "https://example.test/issues/#{identifier}"
    }
  end

  defp wait_until(predicate, attempts \\ 100)

  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  defp wait_until(_predicate, 0), do: flunk("condition did not become true")
end

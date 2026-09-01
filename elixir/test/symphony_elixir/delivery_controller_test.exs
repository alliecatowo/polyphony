defmodule SymphonyElixir.DeliveryControllerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Delivery
  alias SymphonyElixir.DeliveryController
  alias SymphonyElixir.DeliveryController.SystemCommandAdapter

  setup do
    runtime_dir = Path.join(System.tmp_dir!(), "polyphony-delivery-controller-#{System.unique_integer([:positive])}")
    File.mkdir_p!(runtime_dir)

    on_exit(fn -> File.rm_rf(runtime_dir) end)
    {:ok, runtime_dir: runtime_dir}
  end

  test "delivers, proves, waits for green CI, merges, and cleans up", %{runtime_dir: runtime_dir} do
    test_pid = self()
    workspace = "/work/issue-42"
    branch = "agent/issue-42"

    command = command_adapter(test_pid, workspace, branch, [" M lib/result.ex"])

    github = %{
      find_or_create_pull_request: fn attrs ->
        send(test_pid, {:find_or_create_pr, attrs})
        {:ok, %{"number" => 42, "head" => branch, "url" => "https://example.test/pr/42"}}
      end,
      enable_auto_merge: fn pr, attrs ->
        send(test_pid, {:auto_merge, pr, attrs})
        {:ok, %{"method" => "squash"}}
      end
    }

    cleanup = fn path ->
      send(test_pid, {:cleanup, path})
      :ok
    end

    {:ok, pid} = start_controller(runtime_dir, workspace, branch, command, github, cleanup)

    assert {:ok, %{state: :waiting_ci, commit_sha: "commit-42", pr_number: 42} = delivered} =
             DeliveryController.codex_turn_completed(pid, %{session_id: "thread-42", summary: "implemented"})

    assert delivered.delivery_proof["commit_sha"] == "commit-42"
    assert delivered.delivery_proof["auto_merge"]["enabled"]
    assert delivered.metadata["session_id"] == "thread-42"
    assert_receive {:find_or_create_pr, %{commit_sha: "commit-42", branch: ^branch}}
    assert_receive {:auto_merge, _pr, %{commit_sha: "commit-42"}}

    assert {:ok, %{state: :waiting_merge}} =
             DeliveryController.handle_ci_event(pid, %{"conclusion" => "success", "id" => 9})

    assert {:ok, %{state: :complete}} =
             DeliveryController.handle_pull_request_event(pid, %{
               "merged" => true,
               "merge_commit_sha" => "merge-42"
             })

    assert_receive {:cleanup, ^workspace}
    assert {:ok, persisted} = DeliveryController.load(runtime_dir, "issue-42")
    assert persisted.state == :complete
    assert persisted.merge_proof == %{"merge_sha" => "merge-42"}
    assert is_map(persisted.cleanup_proof)
  end

  test "find-or-create and auto-merge are injectable and no network adapter is implicit", %{runtime_dir: runtime_dir} do
    command = command_adapter(self(), "/work/issue-1", "agent/issue-1", [])
    {:ok, pid} = start_controller(runtime_dir, "/work/issue-1", "agent/issue-1", command, nil, fn _ -> :ok end)

    assert {:error, {:github, :missing_github_adapter}, %{state: :retry_ready, attempt: 1}} =
             DeliveryController.codex_turn_completed(pid)
  end

  test "rejects a non-canonical workspace before staging or pushing", %{runtime_dir: runtime_dir} do
    test_pid = self()

    command = fn cwd, argv, _opts ->
      send(test_pid, {:command, cwd, argv})

      case argv do
        ["rev-parse", "--show-toplevel"] -> {:ok, "/work/parent\n", 0}
        _ -> flunk("unexpected command after canonical validation: #{inspect(argv)}")
      end
    end

    {:ok, pid} = start_controller(runtime_dir, "/work/issue-2", "agent/issue-2", command, github_ok(), fn _ -> :ok end)

    assert {:error, {:workspace_not_canonical, "/work/parent", "/work/issue-2"}, delivery} =
             DeliveryController.codex_turn_completed(pid)

    assert delivery.state == :retry_ready
    assert delivery.attempt == 1
    refute_received {:command, _, ["add" | _]}
    refute_received {:command, _, ["push" | _]}
  end

  test "rejects the wrong or base branch before changing the workspace", %{runtime_dir: runtime_dir} do
    test_pid = self()

    command = fn cwd, argv, _opts ->
      send(test_pid, {:command, cwd, argv})

      case argv do
        ["rev-parse", "--show-toplevel"] -> {:ok, cwd <> "\n", 0}
        ["branch", "--show-current"] -> {:ok, "main\n", 0}
        _ -> flunk("unexpected command after branch validation: #{inspect(argv)}")
      end
    end

    {:ok, pid} = start_controller(runtime_dir, "/work/issue-3", "agent/issue-3", command, github_ok(), fn _ -> :ok end)

    assert {:error, {:workspace_wrong_branch, "main", "agent/issue-3"}, delivery} =
             DeliveryController.codex_turn_completed(pid)

    assert delivery.state == :retry_ready
    refute_received {:command, _, ["status" | _]}
  end

  test "provider and rate-limit errors park without consuming attempts", %{runtime_dir: runtime_dir} do
    command = command_adapter(self(), "/work/issue-4", "agent/issue-4", [])

    github = %{
      find_or_create_pull_request: fn _ -> {:error, %{status: 429, retry_at: 123}} end,
      enable_auto_merge: fn _, _ -> flunk("auto merge must not run") end
    }

    {:ok, pid} = start_controller(runtime_dir, "/work/issue-4", "agent/issue-4", command, github, fn _ -> :ok end)

    assert {:error, {:provider_unavailable, _}, delivery} = DeliveryController.codex_turn_completed(pid)
    assert delivery.state == :waiting_provider
    assert delivery.attempt == 0
    assert delivery.failures == []
    assert delivery.provider_retry_at == 123

    assert {:ok, %{state: :delivering}} = DeliveryController.provider_available(pid)
    assert {:ok, restored} = DeliveryController.load(runtime_dir, "issue-4")
    assert restored.state == :delivering
  end

  test "provider recovery resumes the interrupted delivery protocol", %{runtime_dir: runtime_dir} do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)
    workspace = "/work/issue-provider-resume"
    branch = "agent/issue-provider-resume"

    github = %{
      find_or_create_pull_request: fn attrs ->
        call = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

        if call == 0 do
          {:error, %{status: 429, retry_at: 123}}
        else
          {:ok, %{"number" => 91, "head" => attrs.branch}}
        end
      end,
      enable_auto_merge: fn _, _ -> :ok end
    }

    {:ok, pid} =
      start_controller(
        runtime_dir,
        workspace,
        branch,
        command_adapter(self(), workspace, branch, []),
        github,
        fn _ -> :ok end
      )

    assert {:error, {:provider_unavailable, _}, %{state: :waiting_provider, attempt: 0}} =
             DeliveryController.codex_turn_completed(pid, %{session_id: "thread-provider"})

    assert {:ok, %{state: :delivering, attempt: 0}} = DeliveryController.provider_available(pid)

    assert {:ok, %{state: :waiting_ci, attempt: 0, pr_number: 91}} =
             DeliveryController.resume_delivery(pid)

    assert Agent.get(calls, & &1) == 2
  end

  test "invalid PR proof and auto-merge failures are classified as code delivery failures", %{runtime_dir: runtime_dir} do
    invalid_pr = %{
      find_or_create_pull_request: fn _ -> {:ok, %{"number" => 12, "head" => "agent/another-issue"}} end,
      enable_auto_merge: fn _, _ -> flunk("auto merge must not run for invalid proof") end
    }

    {:ok, pid} = start_controller(runtime_dir, "/work/issue-11", "agent/issue-11", command_adapter(self(), "/work/issue-11", "agent/issue-11", []), invalid_pr, fn _ -> :ok end)
    assert {:error, {:invalid_pull_request_proof, _}, %{state: :retry_ready, attempt: 1}} = DeliveryController.codex_turn_completed(pid)

    auto_merge_failure = %{
      find_or_create_pull_request: fn attrs -> {:ok, %{"number" => 13, "head" => attrs.branch}} end,
      enable_auto_merge: fn _, _ -> {:error, :merge_permission_denied} end
    }

    {:ok, pid} = start_controller(runtime_dir, "/work/issue-12", "agent/issue-12", command_adapter(self(), "/work/issue-12", "agent/issue-12", []), auto_merge_failure, fn _ -> :ok end)
    assert {:error, {:github, :merge_permission_denied}, %{state: :retry_ready, attempt: 1}} = DeliveryController.codex_turn_completed(pid)
  end

  test "a command-side provider outage also parks without a failure counter", %{runtime_dir: runtime_dir} do
    command = fn _cwd, ["rev-parse", "--show-toplevel"], _opts -> {:error, :rate_limited} end
    {:ok, pid} = start_controller(runtime_dir, "/work/issue-5", "agent/issue-5", command, github_ok(), fn _ -> :ok end)

    assert {:error, {:provider_unavailable, _}, delivery} = DeliveryController.codex_turn_completed(pid)
    assert delivery.state == :waiting_provider
    assert delivery.attempt == 0
  end

  test "CI failure parks the same session/workspace for a retry", %{runtime_dir: runtime_dir} do
    workspace = "/work/issue-6"
    {:ok, pid} = start_controller(runtime_dir, workspace, "agent/issue-6", command_adapter(self(), workspace, "agent/issue-6", []), github_ok(), fn _ -> :ok end)

    assert {:ok, %{state: :waiting_ci}} = DeliveryController.codex_turn_completed(pid, %{session_id: "same-thread"})

    assert {:ok, %{state: :retry_ready, attempt: 1}} =
             DeliveryController.handle_ci_event(pid, %{"conclusion" => "failure", "id" => 6, "failure_reason" => "tests"})

    assert {:ok, %{state: :executing, workspace: ^workspace, attempt: 1, metadata: metadata}} =
             DeliveryController.admit_retry(pid)

    assert metadata["session_id"] == "same-thread"
  end

  test "merge conflicts are classified as code failures and retain delivery context", %{runtime_dir: runtime_dir} do
    {:ok, pid} = start_controller(runtime_dir, "/work/issue-7", "agent/issue-7", command_adapter(self(), "/work/issue-7", "agent/issue-7", []), github_ok(), fn _ -> :ok end)
    assert {:ok, %{state: :waiting_ci}} = DeliveryController.codex_turn_completed(pid)
    assert {:ok, %{state: :waiting_merge}} = DeliveryController.handle_ci_event(pid, %{"conclusion" => "success"})

    assert {:ok, retry} =
             DeliveryController.handle_pull_request_event(pid, %{"conflict" => true})

    assert retry.state == :retry_ready

    assert {:ok, %{state: :executing}} = DeliveryController.admit_retry(pid)
  end

  test "equivalent classified failures recommend Luna, Terra, then Sol", %{runtime_dir: runtime_dir} do
    workspace = "/work/issue-8"

    command = fn _cwd, ["rev-parse", "--show-toplevel"], _opts -> {:ok, "/wrong-parent\n", 0} end
    {:ok, pid} = start_controller(runtime_dir, workspace, "agent/issue-8", command, github_ok(), fn _ -> :ok end)

    assert {:error, _, first} = DeliveryController.codex_turn_completed(pid)
    assert first.metadata["recommended_profile"] == "luna"
    assert DeliveryController.escalation_recommendation(first) == :luna

    assert {:ok, _} = DeliveryController.admit_retry(pid)
    assert {:error, _, second} = DeliveryController.codex_turn_completed(pid)
    assert second.metadata["recommended_profile"] == "terra"
    assert DeliveryController.escalation_recommendation(second) == :terra

    assert {:ok, _} = DeliveryController.admit_retry(pid)
    assert {:error, _, third} = DeliveryController.codex_turn_completed(pid)
    assert third.metadata["recommended_profile"] == "sol"
    assert DeliveryController.escalation_recommendation(third) == :sol
    assert third.attempt == 3
  end

  test "merge and cleanup are proof-gated", %{runtime_dir: runtime_dir} do
    cleanup_called = Agent.start_link(fn -> 0 end) |> elem(1)

    cleanup = fn _ ->
      Agent.update(cleanup_called, &(&1 + 1))
      :ok
    end

    {:ok, pid} = start_controller(runtime_dir, "/work/issue-9", "agent/issue-9", command_adapter(self(), "/work/issue-9", "agent/issue-9", []), github_ok(), cleanup)

    assert {:error, {:invalid_transition, :cleanup_started}, _} = DeliveryController.cleanup(pid)
    assert Agent.get(cleanup_called, & &1) == 0

    assert {:ok, %{state: :waiting_ci}} = DeliveryController.codex_turn_completed(pid)
    assert {:ok, %{state: :waiting_merge}} = DeliveryController.handle_ci_event(pid, %{"conclusion" => "success"})
    assert {:error, :missing_merge_proof, _} = DeliveryController.handle_pull_request_event(pid, %{"merged" => true})
    assert Agent.get(cleanup_called, & &1) == 0
  end

  test "cleanup failure remains durably parked in cleaning", %{runtime_dir: runtime_dir} do
    cleanup = fn _ -> {:error, :workspace_busy} end
    {:ok, pid} = start_controller(runtime_dir, "/work/issue-13", "agent/issue-13", command_adapter(self(), "/work/issue-13", "agent/issue-13", []), github_ok(), cleanup)

    assert {:ok, %{state: :waiting_ci}} = DeliveryController.codex_turn_completed(pid)
    assert {:ok, %{state: :waiting_merge}} = DeliveryController.handle_ci_event(pid, %{"conclusion" => "success"})

    assert {:error, :workspace_busy, %{state: :cleaning}} =
             DeliveryController.handle_pull_request_event(pid, %{"merged" => true, "merge_commit_sha" => "merge-13"})

    assert {:ok, persisted} = DeliveryController.load(runtime_dir, "issue-13")
    assert persisted.state == :cleaning
    assert persisted.merge_proof == %{"merge_sha" => "merge-13"}
  end

  test "state survives controller restart from the per-delivery JSON file", %{runtime_dir: runtime_dir} do
    workspace = "/work/issue-14"

    opts = [
      delivery_id: "issue-14",
      delivery: Delivery.new(issue_id: "issue-14", workspace: workspace, branch: "agent/issue-14", state: :executing),
      runtime_dir: runtime_dir,
      command_adapter: command_adapter(self(), workspace, "agent/issue-14", []),
      github_adapter: github_ok(),
      cleanup_adapter: fn _ -> :ok end
    ]

    {:ok, pid} = DeliveryController.start_link(opts)
    assert {:ok, %{state: :waiting_ci}} = DeliveryController.codex_turn_completed(pid, %{session_id: "restartable"})
    GenServer.stop(pid)

    {:ok, restarted} = DeliveryController.start_link(Keyword.drop(opts, [:delivery]))
    assert {:ok, %{state: :waiting_ci, metadata: %{"session_id" => "restartable"}}} = DeliveryController.snapshot(restarted)
  end

  test "webhook event dispatcher accepts check and pull-request event names", %{runtime_dir: runtime_dir} do
    {:ok, pid} = start_controller(runtime_dir, "/work/issue-10", "agent/issue-10", command_adapter(self(), "/work/issue-10", "agent/issue-10", []), github_ok(), fn _ -> :ok end)
    assert {:ok, %{state: :waiting_ci}} = DeliveryController.codex_turn_completed(pid)
    assert {:ok, %{state: :waiting_merge}} = DeliveryController.handle_webhook_event(pid, "check_run", %{"conclusion" => "success"})
    assert {:ok, %{state: :complete}} = DeliveryController.handle_webhook_event(pid, :pull_request, %{"merged" => true, "merge_commit_sha" => "merge-10"})
  end

  test "system command adapter terminates commands that exceed the configured timeout", %{runtime_dir: runtime_dir} do
    bin_dir = Path.join(runtime_dir, "bin")
    File.mkdir_p!(bin_dir)
    git_path = Path.join(bin_dir, "git")
    File.write!(git_path, "#!/bin/sh\nexec sleep 5\n")
    File.chmod!(git_path, 0o700)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:command_timeout, 100}} =
             SystemCommandAdapter.run(runtime_dir, [],
               timeout: 100,
               env: [{"PATH", bin_dir <> ":" <> System.fetch_env!("PATH")}]
             )

    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  defp start_controller(runtime_dir, workspace, branch, command, github, cleanup) do
    DeliveryController.start_link(
      delivery: Delivery.new(issue_id: Path.basename(workspace), workspace: workspace, branch: branch, state: :executing),
      runtime_dir: runtime_dir,
      command_adapter: command,
      github_adapter: github,
      cleanup_adapter: cleanup,
      clock: fn -> ~U[2026-01-01 00:00:00Z] end
    )
  end

  defp github_ok do
    %{
      find_or_create_pull_request: fn attrs ->
        {:ok, %{"number" => 1, "head" => attrs.branch}}
      end,
      enable_auto_merge: fn _, _ -> :ok end
    }
  end

  defp command_adapter(test_pid, workspace, branch, status) do
    fn cwd, argv, _opts ->
      send(test_pid, {:command, cwd, argv})
      assert cwd == workspace

      case argv do
        ["rev-parse", "--show-toplevel"] -> {:ok, workspace <> "\n", 0}
        ["branch", "--show-current"] -> {:ok, branch <> "\n", 0}
        ["status", "--porcelain=v1"] -> {:ok, Enum.join(status, "\n") <> if(status == [], do: "", else: "\n"), 0}
        ["add", "--all"] -> {:ok, "", 0}
        ["diff", "--cached", "--quiet"] -> if(status == [], do: {:ok, "", 0}, else: {:ok, "", 1})
        ["commit", "-m", _message] -> {:ok, "[branch commit]\n", 0}
        ["rev-parse", "HEAD"] -> {:ok, "commit-42\n", 0}
        ["push", "--set-upstream", "origin", ^branch] -> {:ok, "pushed\n", 0}
        _ -> flunk("unexpected argv: #{inspect(argv)}")
      end
    end
  end
end

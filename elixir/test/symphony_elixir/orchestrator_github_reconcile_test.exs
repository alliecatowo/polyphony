defmodule SymphonyElixir.OrchestratorGitHubReconcileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Issue, as: GitHubIssue
  alias SymphonyElixir.Orchestrator.State, as: OrchestratorState

  defmodule FakeGitHubClient do
    alias SymphonyElixir.GitHub.Issue, as: GitHubIssue

    def fetch_candidate_issues do
      {:ok, [issue_fixture()]}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, [issue_fixture()]}
    def create_comment(_issue_id, _body), do: :ok
    def update_issue_state(_issue_id, _state_name), do: :ok

    def reconcile_issue_milestone(issue_id, milestone_number) do
      send_message({:reconcile_issue_milestone, issue_id, milestone_number})

      if fail_step() == :milestone do
        {:error, :boom}
      else
        :ok
      end
    end

    def reconcile_issue_assignees(issue_id, assignees) do
      send_message({:reconcile_issue_assignees, issue_id, assignees})
      :ok
    end

    def reconcile_issue_labels(issue_id, labels) do
      send_message({:reconcile_issue_labels, issue_id, labels})
      :ok
    end

    def reconcile_issue_blocked_by(issue_id, blocked_by_ids) do
      send_message({:reconcile_issue_blocked_by, issue_id, blocked_by_ids})
      :ok
    end

    def reconcile_issue_project_custom_fields(%GitHubIssue{id: issue_id}, desired_fields) do
      send_message({:reconcile_issue_project_custom_fields, issue_id, desired_fields})

      if fail_step() == :project_custom_fields do
        {:error, :boom}
      else
        :ok
      end
    end

    def reconcile_issue_state_from_project_status(%GitHubIssue{id: issue_id} = issue) do
      send_message({:reconcile_issue_state_from_project_status, issue_id, issue.tracker_metadata})
      :ok
    end

    defp send_message(message) do
      if pid = Application.get_env(:symphony_elixir, :github_reconcile_test_recipient) do
        send(pid, message)
      end
    end

    defp fail_step do
      Application.get_env(:symphony_elixir, :github_reconcile_test_fail_step)
    end

    defp issue_fixture do
      %GitHubIssue{
        id: "ISSUE1",
        identifier: "#1",
        title: "GitHub reconcile",
        description: "test",
        state: "OPEN",
        assignee_id: "allie",
        labels: ["bug", "Urgent"],
        blocked_by: [%{id: "ISSUE0", identifier: "#0", state: "OPEN"}],
        tracker_metadata: %{
          "milestone" => %{"number" => 42},
          "project_desired_fields" => %{"Progress" => %{"number" => 10}}
        }
      }
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :github_client)
    previous_recipient = Application.get_env(:symphony_elixir, :github_reconcile_test_recipient)
    previous_fail_step = Application.get_env(:symphony_elixir, :github_reconcile_test_fail_step)

    Application.put_env(:symphony_elixir, :github_client, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_reconcile_test_recipient, self())
    Application.delete_env(:symphony_elixir, :github_reconcile_test_fail_step)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :github_client)
      else
        Application.put_env(:symphony_elixir, :github_client, previous_client)
      end

      if is_nil(previous_recipient) do
        Application.delete_env(:symphony_elixir, :github_reconcile_test_recipient)
      else
        Application.put_env(:symphony_elixir, :github_reconcile_test_recipient, previous_recipient)
      end

      if is_nil(previous_fail_step) do
        Application.delete_env(:symphony_elixir, :github_reconcile_test_fail_step)
      else
        Application.put_env(:symphony_elixir, :github_reconcile_test_fail_step, previous_fail_step)
      end
    end)

    :ok
  end

  test "reconciliation is invoked for dispatch-eligible github issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["OPEN"],
      tracker_terminal_states: ["CLOSED"]
    )

    issue = %GitHubIssue{
      id: "ISSUE1",
      identifier: "#1",
      title: "Eligible",
      description: "Dispatch me",
      state: "OPEN",
      assignee_id: "allie",
      labels: ["bug", "Urgent"],
      blocked_by: [%{id: "ISSUE0", identifier: "#0", state: "OPEN"}],
      tracker_metadata: %{"milestone" => %{"number" => 42}}
    }

    assert :ok = Orchestrator.reconcile_issue_primitives_for_test(issue)
    assert_receive {:reconcile_issue_milestone, "ISSUE1", 42}
    assert_receive {:reconcile_issue_assignees, "ISSUE1", ["allie"]}
    assert_receive {:reconcile_issue_labels, "ISSUE1", ["bug", "urgent"]}
    assert_receive {:reconcile_issue_blocked_by, "ISSUE1", ["ISSUE0"]}
  end

  test "reconciliation is a no-op for memory and linear trackers" do
    issue = %GitHubIssue{
      id: "ISSUE1",
      identifier: "#1",
      title: "No-op",
      description: "No reconciliation for non-github",
      state: "OPEN"
    }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert :ok = Orchestrator.reconcile_issue_primitives_for_test(issue)
    refute_receive {:reconcile_issue_milestone, _, _}, 50

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert :ok = Orchestrator.reconcile_issue_primitives_for_test(issue)
    refute_receive {:reconcile_issue_milestone, _, _}, 50
  end

  test "reconciliation failures do not crash orchestrator poll loop" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["OPEN"],
      tracker_terminal_states: ["CLOSED"]
    )

    Application.put_env(:symphony_elixir, :github_reconcile_test_fail_step, :milestone)

    orchestrator_name = Module.concat(__MODULE__, :ReconcileFailureOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(60)

    assert Process.alive?(pid)
    snapshot = Orchestrator.snapshot(orchestrator_name, 500)
    assert is_map(snapshot)
    assert snapshot.running == []
  end

  test "custom fields are passed through when present" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["OPEN"],
      tracker_terminal_states: ["CLOSED"]
    )

    issue = %GitHubIssue{
      id: "ISSUE-CUSTOM-1",
      identifier: "#301",
      title: "Custom fields reconcile",
      description: "Pass through desired project field values",
      state: "OPEN",
      tracker_metadata: %{
        "project_custom_fields" => %{
          "Points" => %{"number" => 5},
          "Progress" => %{"number" => 40},
          "Target Date" => %{"date" => "2026-05-31"},
          "Notes" => %{"text" => "agent update"}
        }
      }
    }

    assert :ok = Orchestrator.reconcile_issue_primitives_for_test(issue)

    assert_receive {:reconcile_issue_project_custom_fields, "ISSUE-CUSTOM-1", desired_fields}
    assert desired_fields["Points"] == %{"number" => 5}
    assert desired_fields["Progress"] == %{"number" => 40}
    assert desired_fields["Target Date"] == %{"date" => "2026-05-31"}
    assert desired_fields["Notes"] == %{"text" => "agent update"}
  end

  test "custom fields are not reconciled when absent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["OPEN"],
      tracker_terminal_states: ["CLOSED"]
    )

    issue = %GitHubIssue{
      id: "ISSUE-CUSTOM-2",
      identifier: "#302",
      title: "No custom fields",
      description: "No custom field reconcile call expected",
      state: "OPEN",
      tracker_metadata: %{}
    }

    assert :ok = Orchestrator.reconcile_issue_primitives_for_test(issue)
    refute_receive {:reconcile_issue_project_custom_fields, _, _}, 50
  end

  test "custom field reconcile failure does not crash orchestrator poll loop" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["OPEN"],
      tracker_terminal_states: ["CLOSED"]
    )

    Application.put_env(:symphony_elixir, :github_reconcile_test_fail_step, :project_custom_fields)

    orchestrator_name = Module.concat(__MODULE__, :CustomFieldFailureOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(60)

    assert Process.alive?(pid)
    snapshot = Orchestrator.snapshot(orchestrator_name, 500)
    assert is_map(snapshot)
    assert snapshot.running == []
  end

  test "policy-derived custom fields are passed through to reconciliation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["OPEN"],
      tracker_terminal_states: ["CLOSED"]
    )

    issue = %GitHubIssue{
      id: "ISSUE-POLICY-1",
      identifier: "#401",
      title: "Policy custom fields",
      description: "Pass through policy-derived values",
      state: "OPEN",
      tracker_metadata: %{
        "project_desired_fields" => %{
          "Points" => %{"number" => 8},
          "Progress" => %{"number" => 65},
          "Target Date" => %{"date" => "2026-06-10"}
        }
      }
    }

    assert :ok = Orchestrator.reconcile_issue_primitives_for_test(issue)

    assert_receive {:reconcile_issue_project_custom_fields, "ISSUE-POLICY-1", desired_fields}
    assert desired_fields["Points"] == %{"number" => 8}
    assert desired_fields["Progress"] == %{"number" => 65}
    assert desired_fields["Target Date"] == %{"date" => "2026-06-10"}
  end

  test "dispatch gating skips todo issue when a blocker is non-terminal" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed"]
    )

    issue = %GitHubIssue{
      id: "ISSUE-BLOCKED",
      identifier: "#101",
      title: "Blocked Todo",
      description: "Should be skipped",
      state: "Todo",
      blocked_by: [%{id: "ISSUE-B1", identifier: "#90", state: "In Progress"}]
    }

    state = %OrchestratorState{running: %{}, claimed: MapSet.new(), max_concurrent_agents: 5}
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch gating allows todo issue when all blockers are terminal" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_project_title: "Polyphony",
      tracker_project_owner_login: "acme",
      tracker_project_owner_type: "organization",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed"]
    )

    issue = %GitHubIssue{
      id: "ISSUE-UNBLOCKED",
      identifier: "#102",
      title: "Unblocked Todo",
      description: "Should dispatch",
      state: "Todo",
      blocked_by: [
        %{id: "ISSUE-B2", identifier: "#91", state: "Done"},
        %{id: "ISSUE-B3", identifier: "#92", state: "Closed"}
      ]
    }

    state = %OrchestratorState{running: %{}, claimed: MapSet.new(), max_concurrent_agents: 5}
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end
end

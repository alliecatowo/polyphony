defmodule SymphonyElixir.GitHub.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Adapter

  defmodule StubClient do
    @moduledoc false
    # Records every call as a message to the test process and returns whatever the test
    # configured under {:stub_result, function_name} (default :ok).
    @functions [
      fetch_candidate_issues: 0,
      fetch_issues_by_states: 1,
      fetch_issue_states_by_ids: 1,
      create_comment: 2,
      update_issue_state: 2,
      update_project_item_field_value: 4,
      clear_project_item_field_value: 3,
      add_sub_issue: 2,
      remove_sub_issue: 2,
      reprioritize_sub_issue: 3,
      reconcile_issue_milestone: 2,
      reconcile_issue_assignees: 2,
      reconcile_issue_labels: 2,
      reconcile_issue_blocked_by: 2,
      reconcile_issue_hierarchy: 2,
      reconcile_issue_state_from_project_status: 1,
      reconcile_issue_project_custom_fields: 2
    ]

    for {name, arity} <- @functions do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)) do
        send(:persistent_term.get({__MODULE__, :test_pid}), {unquote(name), [unquote_splicing(args)]})
        :persistent_term.get({__MODULE__, :result, unquote(name)}, :ok)
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client)
    Application.put_env(:symphony_elixir, :github_client, StubClient)
    :persistent_term.put({StubClient, :test_pid}, self())

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:symphony_elixir, :github_client),
        else: Application.put_env(:symphony_elixir, :github_client, previous)

      :persistent_term.erase({StubClient, :test_pid})

      for {{StubClient, :result, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    end)

    :ok
  end

  test "reads delegate to the configured client" do
    assert :ok = Adapter.fetch_candidate_issues()
    assert :ok = Adapter.fetch_issues_by_states(["OPEN"])
    assert :ok = Adapter.fetch_issue_states_by_ids(["1"])

    assert_received {:fetch_candidate_issues, []}
    assert_received {:fetch_issues_by_states, [["OPEN"]]}
    assert_received {:fetch_issue_states_by_ids, [["1"]]}
  end

  test "issue and hierarchy writes delegate with their arguments" do
    assert :ok = Adapter.create_comment("1", "hi")
    assert :ok = Adapter.update_issue_state("1", "CLOSED")
    assert :ok = Adapter.add_sub_issue("1", "2")
    assert :ok = Adapter.remove_sub_issue("1", "2")
    assert :ok = Adapter.reprioritize_sub_issue("1", "2")
    assert :ok = Adapter.reprioritize_sub_issue("1", "2", "3")
    assert :ok = Adapter.reconcile_issue_milestone("1", 4)
    assert :ok = Adapter.reconcile_issue_milestone("1", nil)
    assert :ok = Adapter.reconcile_issue_assignees("1", ["octo"])
    assert :ok = Adapter.reconcile_issue_labels("1", ["bug"])
    assert :ok = Adapter.reconcile_issue_blocked_by("1", ["9"])
    assert :ok = Adapter.reconcile_issue_hierarchy(%{id: "1"}, %{parent: "0"})
    assert :ok = Adapter.reconcile_issue_state_from_project_status(%{id: "1"})
    assert :ok = Adapter.reconcile_issue_project_custom_fields(%{id: "1"}, %{"Points" => 3})

    assert_received {:create_comment, ["1", "hi"]}
    assert_received {:update_issue_state, ["1", "CLOSED"]}
    assert_received {:add_sub_issue, ["1", "2"]}
    assert_received {:remove_sub_issue, ["1", "2"]}
    assert_received {:reprioritize_sub_issue, ["1", "2", nil]}
    assert_received {:reprioritize_sub_issue, ["1", "2", "3"]}
    assert_received {:reconcile_issue_milestone, ["1", 4]}
    assert_received {:reconcile_issue_milestone, ["1", nil]}
    assert_received {:reconcile_issue_assignees, ["1", ["octo"]]}
    assert_received {:reconcile_issue_labels, ["1", ["bug"]]}
    assert_received {:reconcile_issue_blocked_by, ["1", ["9"]]}
    assert_received {:reconcile_issue_hierarchy, [%{id: "1"}, %{parent: "0"}]}
    assert_received {:reconcile_issue_state_from_project_status, [%{id: "1"}]}
    assert_received {:reconcile_issue_project_custom_fields, [%{id: "1"}, %{"Points" => 3}]}
  end

  test "project field writes delegate" do
    assert :ok = Adapter.update_project_item_field_value("p", "i", "f", %{"number" => 1})
    assert :ok = Adapter.clear_project_item_field_value("p", "i", "f")
    assert_received {:update_project_item_field_value, ["p", "i", "f", %{"number" => 1}]}
    assert_received {:clear_project_item_field_value, ["p", "i", "f"]}
  end

  describe "apply_orchestrator_tracker_writes/2" do
    test "applies custom fields, field updates, state transition and comments in order" do
      writes = %{
        project_custom_fields: %{"Points" => 3},
        project_field_updates: [
          %{project_id: "p", item_id: "i", field_id: "f", value: %{"number" => 5}},
          %{"project_id" => "p", "item_id" => "i", "field_id" => "g", "clear" => true}
        ],
        state_transition: "In Review",
        comment: "  first  ",
        comments: ["second", "", 42]
      }

      assert :ok = Adapter.apply_orchestrator_tracker_writes(%{id: "issue-1"}, writes)

      assert_received {:reconcile_issue_project_custom_fields, [%{id: "issue-1"}, %{"Points" => 3}]}
      assert_received {:update_project_item_field_value, ["p", "i", "f", %{"number" => 5}]}
      assert_received {:clear_project_item_field_value, ["p", "i", "g"]}
      assert_received {:update_issue_state, ["issue-1", "In Review"]}
      assert_received {:create_comment, ["issue-1", "first"]}
      assert_received {:create_comment, ["issue-1", "second"]}
      refute_received {:create_comment, _}
    end

    test "accepts string keys and skips incomplete field updates" do
      writes = %{
        "project_fields" => %{"Status" => "Done"},
        "project_field_updates" => [%{"project_id" => "p"}, %{"project_id" => "p", "item_id" => "i", "field_id" => "f"}, :junk],
        "state" => "CLOSED",
        "comments" => ["bye"]
      }

      assert :ok = Adapter.apply_orchestrator_tracker_writes(%{"id" => "7"}, writes)

      assert_received {:reconcile_issue_project_custom_fields, [_, %{"Status" => "Done"}]}
      refute_received {:update_project_item_field_value, _}
      refute_received {:clear_project_item_field_value, _}
      assert_received {:update_issue_state, ["7", "CLOSED"]}
      assert_received {:create_comment, ["7", "bye"]}
    end

    test "does nothing for empty writes or issues without an id" do
      assert :ok = Adapter.apply_orchestrator_tracker_writes(%{}, %{state_transition: "CLOSED", comment: "x"})
      assert :ok = Adapter.apply_orchestrator_tracker_writes(%{id: "1"}, %{state_transition: "   "})
      refute_received {:update_issue_state, _}
      refute_received {:create_comment, _}
    end

    test "stops at the first failing step" do
      :persistent_term.put({StubClient, :result, :reconcile_issue_project_custom_fields}, {:error, :boom})

      assert {:error, :boom} =
               Adapter.apply_orchestrator_tracker_writes(%{id: "1"}, %{project_custom_fields: %{"A" => 1}, state_transition: "CLOSED"})

      refute_received {:update_issue_state, _}
    end

    test "a failing comment halts the remaining comments" do
      :persistent_term.put({StubClient, :result, :create_comment}, {:error, :rate_limited})

      assert {:error, :rate_limited} = Adapter.apply_orchestrator_tracker_writes(%{id: "1"}, %{comments: ["a", "b"]})
      assert_received {:create_comment, ["1", "a"]}
      refute_received {:create_comment, ["1", "b"]}
    end

    test "a failing field update halts" do
      :persistent_term.put({StubClient, :result, :update_project_item_field_value}, {:error, :denied})
      updates = [%{project_id: "p", item_id: "i", field_id: "f", value: %{"text" => "x"}}]

      assert {:error, :denied} = Adapter.apply_orchestrator_tracker_writes(%{id: "1"}, %{project_field_updates: updates, state: "CLOSED"})
      refute_received {:update_issue_state, _}
    end
  end
end

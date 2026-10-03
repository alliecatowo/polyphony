defmodule SymphonyElixir.GitHubClientMutationsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Auth
  alias SymphonyElixir.GitHub.Client

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://example.test/graphql",
      tracker_api_token: "ghs_test_token",
      tracker_repo_owner: "acme",
      tracker_repo_name: "polyphony",
      tracker_active_states: ["OPEN"],
      tracker_terminal_states: ["CLOSED"]
    )

    previous_req_options = Req.default_options()
    Auth.clear_cache()

    on_exit(fn ->
      Req.default_options(previous_req_options)
      Auth.clear_cache()
    end)

    :ok
  end

  # Stub that reports each request to the test process and answers via `respond`.
  defp stub!(respond) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      send(test_pid, {:request, conn.method, conn.request_path, body})
      respond.(conn, body)
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
  end

  defp graphql_ok(conn, _body), do: Req.Test.json(conn, %{"data" => %{"ok" => true}})

  describe "GraphQL sub-issue and project-field mutations" do
    test "add_sub_issue / remove_sub_issue send both ids" do
      stub!(&graphql_ok/2)

      assert :ok = Client.add_sub_issue("I_parent", "I_child")
      assert_received {:request, "POST", _, %{"variables" => %{"issueId" => "I_parent", "subIssueId" => "I_child"}}}

      assert :ok = Client.remove_sub_issue("I_parent", "I_child")
      assert_received {:request, "POST", _, %{"variables" => %{"issueId" => "I_parent", "subIssueId" => "I_child"}}}
    end

    test "reprioritize_sub_issue passes an optional after id" do
      stub!(&graphql_ok/2)

      assert :ok = Client.reprioritize_sub_issue("I_parent", "I_child")
      assert_received {:request, _, _, %{"variables" => %{"afterId" => nil}}}

      assert :ok = Client.reprioritize_sub_issue("I_parent", "I_child", "I_other")
      assert_received {:request, _, _, %{"variables" => %{"afterId" => "I_other"}}}
    end

    test "clear_project_item_field_value sends project, item and field ids" do
      stub!(&graphql_ok/2)

      assert :ok = Client.clear_project_item_field_value("P1", "ITEM1", "F1")
      assert_received {:request, _, _, %{"variables" => %{"projectId" => "P1", "itemId" => "ITEM1", "fieldId" => "F1"}}}
    end

    test "blank ids are rejected before any request is made" do
      stub!(fn _conn, _body -> flunk("no request expected") end)

      assert {:error, {:missing_required, :issue_id}} = Client.add_sub_issue(" ", "I_child")
      assert {:error, {:missing_required, :sub_issue_id}} = Client.remove_sub_issue("I_parent", "")
      assert {:error, {:missing_required, :after_id}} = Client.reprioritize_sub_issue("I_parent", "I_child", " ")
      assert {:error, {:missing_required, :project_id}} = Client.clear_project_item_field_value("", "i", "f")
      assert {:error, {:missing_required, :item_id}} = Client.clear_project_item_field_value("p", " ", "f")
      assert {:error, {:missing_required, :field_id}} = Client.clear_project_item_field_value("p", "i", "")
    end

    test "GraphQL errors and HTTP failures surface as tagged errors" do
      stub!(fn conn, _body -> Req.Test.json(conn, %{"errors" => [%{"message" => "nope"}]}) end)
      assert {:error, {:github_graphql_errors, [%{"message" => "nope"}]}} = Client.add_sub_issue("a", "b")

      stub!(fn conn, _body -> conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{"message" => "bad gateway"}) end)
      assert {:error, {:github_api_status, 502}} = Client.remove_sub_issue("a", "b")
    end
  end

  describe "reconcile_issue_blocked_by/2" do
    @deps "/repos/acme/polyphony/issues/7/dependencies/blocked_by"

    test "adds missing and removes stale blockers" do
      stub!(fn conn, _body ->
        case {conn.method, conn.request_path} do
          {"GET", @deps} -> Req.Test.json(conn, %{"blocked_by" => [%{"number" => 3}, %{"number" => 4}]})
          {"POST", @deps} -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
          {"DELETE", @deps <> "/4"} -> Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = Client.reconcile_issue_blocked_by("7", ["#3", "5", "5"])

      assert_received {:request, "GET", @deps, _}
      assert_received {:request, "POST", @deps, %{"blocked_by_issue_number" => 5}}
      assert_received {:request, "DELETE", _, _}
    end

    test "does nothing when the blockers already match" do
      stub!(fn conn, _body -> Req.Test.json(conn, %{"issues" => [%{"number" => 3}]}) end)

      assert :ok = Client.reconcile_issue_blocked_by("7", ["3"])
      assert_received {:request, "GET", _, _}
      refute_received {:request, "POST", _, _}
      refute_received {:request, "DELETE", _, _}
    end

    test "a failed add halts and reports the status" do
      stub!(fn conn, _body ->
        case conn.method do
          "GET" -> Req.Test.json(conn, %{"blocked_by" => []})
          "POST" -> conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "invalid"})
        end
      end)

      assert {:error, {:github_api_status, 422}} = Client.reconcile_issue_blocked_by("7", ["3", "4"])
    end

    test "a failed lookup is reported" do
      # 404 (not 5xx): Req retries failed GETs with backoff, which would stall the test for seconds.
      stub!(fn conn, _body -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{}) end)
      assert {:error, {:github_api_status, 404}} = Client.reconcile_issue_blocked_by("7", ["3"])
    end
  end

  describe "reconcile_issue_hierarchy/2 and reconcile_issue_primitives_in_order/2" do
    test "issues without an id are ignored" do
      assert :ok = Client.reconcile_issue_hierarchy(%{}, %{parent_issue_id: "P"})
      assert :ok = Client.reconcile_issue_primitives_in_order(%{}, %{})
    end

    test "adds, removes and reorders sub-issues to match the desired set" do
      stub!(&graphql_ok/2)

      issue = %{id: "I_parent", tracker_metadata: %{"sub_issues" => [%{"id" => "I_old"}, %{"id" => "I_keep"}]}}

      assert :ok = Client.reconcile_issue_hierarchy(issue, %{sub_issue_ids: ["I_keep", "I_new"]})

      assert_received {:request, "POST", _, %{"variables" => %{"subIssueId" => "I_new"}}}
      assert_received {:request, "POST", _, %{"variables" => %{"subIssueId" => "I_old"}}}
      assert_received {:request, "POST", _, %{"variables" => %{"subIssueId" => "I_keep"}}}
    end
  end
end

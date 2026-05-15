defmodule SymphonyElixir.GitHubClientIntegrationTest do
  use SymphonyElixir.TestSupport

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

    on_exit(fn ->
      Req.default_options(previous_req_options)
    end)

    :ok
  end

  test "fetch_candidate_issues paginates across cursors and filters by project status field" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      vars = get_in(conn.body_params, ["variables"]) || %{}

      send(test_pid, {:graphql_request, vars["after"], vars["states"]})

      page =
        case vars["after"] do
          nil ->
            %{
              "data" => %{
                "repository" => %{
                  "issues" => %{
                    "nodes" => [
                      issue_node("I1", 1, "OPEN", status_name: "Backlog"),
                      issue_node("I2", 2, "CLOSED", status_name: "OPEN")
                    ],
                    "pageInfo" => %{"hasNextPage" => true, "endCursor" => "CURSOR-1"}
                  }
                }
              }
            }

          "CURSOR-1" ->
            %{
              "data" => %{
                "repository" => %{
                  "issues" => %{
                    "nodes" => [
                      issue_node("I3", 3, "CLOSED", status_name: "DONE")
                    ],
                    "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                  }
                }
              }
            }
        end

      Req.Test.json(conn, page)
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    assert {:ok, issues} = Client.fetch_candidate_issues()
    assert Enum.map(issues, & &1.id) == ["I1", "I2"]

    assert_receive {:graphql_request, nil, ["OPEN"]}
    assert_receive {:graphql_request, "CURSOR-1", ["OPEN"]}
  end

  test "fetch_issue_states_by_ids preserves requested ordering" do
    Req.Test.stub(__MODULE__, fn conn ->
      payload = %{
        "data" => %{
          "nodes" => [
            issue_node("I3", 3, "OPEN"),
            issue_node("I1", 1, "OPEN"),
            issue_node("I2", 2, "CLOSED")
          ]
        }
      }

      Req.Test.json(conn, payload)
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    assert {:ok, issues} = Client.fetch_issue_states_by_ids(["I1", "I2", "I3"])
    assert Enum.map(issues, & &1.id) == ["I1", "I2", "I3"]
  end

  test "update_issue_state maps terminal states to closed and other states to open" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.method == "PATCH" and String.contains?(conn.request_path, "/issues/") do
        send(test_pid, {:patch_issue_state, conn.request_path, conn.body_params["state"]})
      end

      Req.Test.json(conn, %{"ok" => true})
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    assert :ok = Client.update_issue_state("#42", "Done")
    assert_receive {:patch_issue_state, "/repos/acme/polyphony/issues/42", "closed"}

    assert :ok = Client.update_issue_state("42", "In Progress")
    assert_receive {:patch_issue_state, "/repos/acme/polyphony/issues/42", "open"}
  end

  test "create_comment returns ok on success and github_api_status on failure" do
    Req.Test.stub(__MODULE__, fn conn ->
      status = if conn.body_params["body"] == "ship it", do: 201, else: 422

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(%{"message" => "result"}))
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    assert :ok = Client.create_comment("#7", "ship it")

    assert {:error, {:github_api_status, 422}} =
             Client.create_comment("#7", "nope")
  end

  defp issue_node(id, number, state, opts \\ []) do
    status_name = Keyword.get(opts, :status_name)

    %{
      "id" => id,
      "number" => number,
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => state,
      "stateReason" => nil,
      "url" => "https://github.com/acme/polyphony/issues/#{number}",
      "assignees" => %{"nodes" => []},
      "labels" => %{"nodes" => []},
      "milestone" => nil,
      "parent" => nil,
      "subIssues" => %{"nodes" => []},
      "projectItems" => %{"nodes" => project_items(status_name)},
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-01T00:00:00Z"
    }
  end

  defp project_items(nil), do: []

  defp project_items(status_name) do
    [
      %{
        "id" => "ITEM-#{status_name}",
        "isArchived" => false,
        "project" => %{"id" => "P1", "number" => 1, "title" => "Roadmap", "url" => "https://github.com/orgs/acme/projects/1"},
        "fieldValues" => %{
          "nodes" => [
            %{
              "__typename" => "ProjectV2ItemFieldSingleSelectValue",
              "name" => status_name,
              "optionId" => "OPT-#{status_name}",
              "field" => %{"id" => "F1", "name" => "Status"}
            }
          ]
        }
      }
    ]
  end
end

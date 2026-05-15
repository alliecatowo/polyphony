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
      query = get_in(conn.body_params, ["query"]) || ""
      vars = get_in(conn.body_params, ["variables"]) || %{}

      cond do
        String.contains?(query, "OwnerLookup") ->
          Req.Test.json(conn, %{
            "data" => %{
              "organization" => %{
                "id" => "ORG1",
                "projectsV2" => %{"nodes" => [%{"id" => "PROJ1", "title" => "Polyphony", "url" => "u", "number" => 1}]}
              }
            }
          })

        String.contains?(query, "ProjectFields") ->
          Req.Test.json(conn, %{
            "data" => %{
              "node" => %{
                "fields" => %{"nodes" => [%{"id" => "F1", "name" => "Status", "dataType" => "SINGLE_SELECT"}]}
              }
            }
          })

        String.contains?(query, "RepositoryIssues") ->
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

        String.contains?(query, "AddProjectItem") ->
          Req.Test.json(conn, %{"data" => %{"addProjectV2ItemById" => %{"item" => %{"id" => "ITEMNEW"}}}})

        String.contains?(query, "ProjectIssues") ->
          Req.Test.json(conn, %{
            "data" => %{
              "node" => %{
                "items" => %{
                  "nodes" => [
                    %{
                      "id" => "ITEM-A",
                      "isArchived" => false,
                      "content" => Map.put(issue_node("I1", 1, "OPEN", status_name: "Backlog"), "repository", %{"nameWithOwner" => "acme/polyphony"}),
                      "fieldValues" => %{"nodes" => status_field_nodes("Backlog")}
                    },
                    %{
                      "id" => "ITEM-B",
                      "isArchived" => false,
                      "content" => Map.put(issue_node("I2", 2, "CLOSED", status_name: "OPEN"), "repository", %{"nameWithOwner" => "acme/polyphony"}),
                      "fieldValues" => %{"nodes" => status_field_nodes("OPEN")}
                    }
                  ],
                  "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                }
              }
            }
          })

        true ->
          Req.Test.json(conn, %{"data" => %{}})
      end
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    assert {:ok, issues} = Client.fetch_candidate_issues()
    assert Enum.map(issues, & &1.id) == ["I2"]

    assert_receive {:graphql_request, nil, ["OPEN"]}
    assert_receive {:graphql_request, "CURSOR-1", ["OPEN"]}
  end

  test "project status takes precedence over issue state for dispatch eligibility" do
    Req.Test.stub(__MODULE__, fn conn ->
      query = get_in(conn.body_params, ["query"]) || ""

      cond do
        String.contains?(query, "OwnerLookup") ->
          Req.Test.json(conn, %{
            "data" => %{
              "organization" => %{
                "id" => "ORG1",
                "projectsV2" => %{"nodes" => [%{"id" => "PROJ1", "title" => "Polyphony", "url" => "u", "number" => 1}]}
              }
            }
          })

        String.contains?(query, "ProjectFields") ->
          Req.Test.json(conn, %{
            "data" => %{
              "node" => %{
                "fields" => %{"nodes" => [%{"id" => "F1", "name" => "Status", "dataType" => "SINGLE_SELECT"}]}
              }
            }
          })

        String.contains?(query, "RepositoryIssues") ->
          Req.Test.json(conn, %{
            "data" => %{
              "repository" => %{
                "issues" => %{
                  "nodes" => [
                    issue_node("I10", 10, "OPEN", status_name: "Done")
                  ],
                  "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                }
              }
            }
          })

        String.contains?(query, "ProjectIssues") ->
          Req.Test.json(conn, %{
            "data" => %{
              "node" => %{
                "items" => %{
                  "nodes" => [
                    %{
                      "id" => "ITEM-10",
                      "isArchived" => false,
                      "content" => Map.put(issue_node("I10", 10, "OPEN", status_name: "Done"), "repository", %{"nameWithOwner" => "acme/polyphony"}),
                      "fieldValues" => %{"nodes" => status_field_nodes("Done")}
                    }
                  ],
                  "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                }
              }
            }
          })

        String.contains?(query, "AddProjectItem") ->
          Req.Test.json(conn, %{"data" => %{"addProjectV2ItemById" => %{"item" => %{"id" => "ITEMNEW"}}}})

        true ->
          Req.Test.json(conn, %{"data" => %{}})
      end
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    assert {:ok, []} = Client.fetch_candidate_issues()
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

  test "normalization includes milestone assignee label and parent dependency helpers" do
    Req.Test.stub(__MODULE__, fn conn ->
      payload = %{
        "data" => %{
          "nodes" => [
            issue_node("I42", 42, "OPEN",
              assignees: [%{"login" => "allie"}],
              labels: [%{"name" => "Bug"}, %{"name" => "Needs-Review"}],
              milestone: %{
                "id" => "M1",
                "number" => 9,
                "title" => "v1",
                "dueOn" => "2026-06-01T00:00:00Z",
                "state" => "OPEN",
                "description" => "launch"
              },
              parent: %{
                "id" => "PARENT1",
                "number" => 7,
                "title" => "Parent",
                "state" => "OPEN",
                "url" => "https://github.com/acme/polyphony/issues/7"
              }
            )
          ]
        }
      }

      Req.Test.json(conn, payload)
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["I42"])
    assert issue.assignee_id == "allie"
    assert issue.labels == ["bug", "needs-review"]
    assert issue.blocked_by == [%{id: "PARENT1", identifier: "#7", state: "OPEN"}]

    assert %{
             "milestone" => %{
               "id" => "M1",
               "number" => 9,
               "title" => "v1",
               "state" => "OPEN",
               "description" => "launch",
               "due_on" => "2026-06-01T00:00:00Z"
             },
             "parent" => %{
               "id" => "PARENT1",
               "identifier" => "#7",
               "title" => "Parent",
               "state" => "OPEN"
             }
           } = issue.tracker_metadata
  end

  test "project field helper captures labels and milestone field variants in tracker metadata" do
    Req.Test.stub(__MODULE__, fn conn ->
      payload = %{
        "data" => %{
          "nodes" => [
            issue_node("I99", 99, "OPEN",
              project_item_field_values: [
                %{
                  "__typename" => "ProjectV2ItemFieldLabelValue",
                  "labels" => %{"nodes" => [%{"id" => "L1", "name" => "backend"}]},
                  "field" => %{"id" => "FL", "name" => "Labels"}
                },
                %{
                  "__typename" => "ProjectV2ItemFieldMilestoneValue",
                  "milestone" => %{"id" => "M2", "number" => 10, "title" => "Beta", "dueOn" => nil, "state" => "OPEN"},
                  "field" => %{"id" => "FM", "name" => "Milestone"}
                }
              ]
            )
          ]
        }
      }

      Req.Test.json(conn, payload)
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["I99"])

    [project_item] = issue.tracker_metadata["project_items"]
    fields = project_item["field_values"]

    assert Enum.any?(fields, fn field ->
             field["type"] == "ProjectV2ItemFieldLabelValue" and
               field["field"]["name"] == "Labels" and
               field["labels"] == [%{"id" => "L1", "name" => "backend"}]
           end)

    assert Enum.any?(fields, fn field ->
             field["type"] == "ProjectV2ItemFieldMilestoneValue" and
               field["field"]["name"] == "Milestone" and
               field["milestone"]["id"] == "M2"
           end)
  end

  test "dependency helper is empty when no parent dependency is present" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => %{"nodes" => [issue_node("I100", 100, "OPEN")]}})
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["I100"])
    assert issue.blocked_by == []
    assert issue.tracker_metadata["parent"] == nil
  end

  defp issue_node(id, number, state, opts \\ []) do
    status_name = Keyword.get(opts, :status_name)
    assignees = Keyword.get(opts, :assignees, [])
    labels = Keyword.get(opts, :labels, [])
    milestone = Keyword.get(opts, :milestone, nil)
    parent = Keyword.get(opts, :parent, nil)
    project_item_field_values = Keyword.get(opts, :project_item_field_values, nil)

    %{
      "id" => id,
      "number" => number,
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => state,
      "stateReason" => nil,
      "url" => "https://github.com/acme/polyphony/issues/#{number}",
      "assignees" => %{"nodes" => assignees},
      "labels" => %{"nodes" => labels},
      "milestone" => milestone,
      "parent" => parent,
      "subIssues" => %{"nodes" => []},
      "projectItems" => %{"nodes" => project_items(status_name, project_item_field_values)},
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-01T00:00:00Z"
    }
  end

  defp project_items(nil, override_field_values) when is_list(override_field_values) do
    [
      %{
        "id" => "ITEM-CUSTOM",
        "isArchived" => false,
        "project" => %{"id" => "P1", "number" => 1, "title" => "Roadmap", "url" => "https://github.com/orgs/acme/projects/1"},
        "fieldValues" => %{"nodes" => override_field_values}
      }
    ]
  end

  defp project_items(nil, _override), do: []

  defp project_items(status_name, override_field_values) do
    field_nodes =
      cond do
        is_list(override_field_values) -> override_field_values
        true -> status_field_nodes(status_name)
      end

    [
      %{
        "id" => "ITEM-#{status_name}",
        "isArchived" => false,
        "project" => %{"id" => "P1", "number" => 1, "title" => "Roadmap", "url" => "https://github.com/orgs/acme/projects/1"},
        "fieldValues" => %{
          "nodes" => field_nodes
        }
      }
    ]
  end

  defp status_field_nodes(status_name) do
    [
      %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => status_name,
        "optionId" => "OPT-#{status_name}",
        "field" => %{"id" => "F1", "name" => "Status"}
      }
    ]
  end
end

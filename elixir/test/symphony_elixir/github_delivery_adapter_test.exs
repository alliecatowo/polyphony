defmodule SymphonyElixir.GitHub.DeliveryAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.{DeliveryAdapter, Gateway}

  setup do
    gateway = String.to_atom("delivery-adapter-gateway-#{System.unique_integer([:positive])}")
    {:ok, gateway_pid} = Gateway.start_link(name: gateway)

    on_exit(fn ->
      if Process.alive?(gateway_pid), do: GenServer.stop(gateway_pid)
    end)

    {:ok, gateway: gateway}
  end

  test "finds an existing PR idempotently and returns delivery proof", %{gateway: gateway} do
    parent = self()

    request = fn :get, url, headers, nil ->
      send(parent, {:request, :get, url, headers})

      {:ok,
       response(200, [
         %{
           "number" => 17,
           "node_id" => "PR_node_17",
           "html_url" => "https://github.com/acme/patches/pull/17",
           "head" => %{"ref" => "agent/patch-17"},
           "base" => %{"ref" => "main"}
         }
       ])}
    end

    attrs = attrs(gateway, request, branch: "agent/patch-17")
    assert {:ok, proof} = DeliveryAdapter.find_or_create_pull_request(attrs)
    assert proof["number"] == 17
    assert proof["head"] == "agent/patch-17"
    assert proof["node_id"] == "PR_node_17"
    assert proof["url"] == "https://github.com/acme/patches/pull/17"
    refute_receive {:request, :post, _, _}
    assert_receive {:request, :get, "https://api.github.test/repos/acme/patches/pulls?" <> _, _}
  end

  test "creates a PR when the branch has no existing PR", %{gateway: gateway} do
    parent = self()

    request = fn method, url, _headers, body ->
      send(parent, {:request, method, url, body})

      case method do
        :get ->
          {:ok, response(200, [])}

        :post ->
          assert body["head"] == "agent/new"
          assert body["base"] == "main"
          assert body["title"] == "Implement delivery"
          assert body["body"] == "A complete delivery body"

          {:ok,
           response(201, %{
             "number" => 18,
             "node_id" => "PR_node_18",
             "html_url" => "https://github.com/acme/patches/pull/18",
             "head" => %{"ref" => "agent/new"}
           })}
      end
    end

    assert {:ok, %{"number" => 18, "head" => "agent/new", "node_id" => "PR_node_18", "existing" => false}} =
             DeliveryAdapter.find_or_create_pull_request(
               attrs(gateway, request,
                 branch: "agent/new",
                 issue_id: "PATCH-18",
                 title: "Implement delivery",
                 body: "A complete delivery body"
               )
             )

    assert_receive {:request, :get, _, _}
    assert_receive {:request, :post, "https://api.github.test/repos/acme/patches/pulls", _}
  end

  test "repairs missing metadata on an existing PR", %{gateway: gateway} do
    parent = self()

    request = fn method, url, _headers, body ->
      send(parent, {:request, method, url, body})

      case method do
        :get ->
          {:ok,
           response(200, [
             %{
               "number" => 21,
               "node_id" => "PR_node_21",
               "html_url" => "https://github.com/acme/patches/pull/21",
               "title" => "Symphony: nodeid",
               "body" => nil,
               "head" => %{"ref" => "agent/repair-metadata"},
               "base" => %{"ref" => "main"}
             }
           ])}

        :patch ->
          assert body == %{"title" => "PATCH-21: Repair metadata", "body" => "Source issue and handoff"}

          {:ok,
           response(200, %{
             "number" => 21,
             "node_id" => "PR_node_21",
             "html_url" => "https://github.com/acme/patches/pull/21",
             "title" => body["title"],
             "body" => body["body"],
             "head" => %{"ref" => "agent/repair-metadata"},
             "base" => %{"ref" => "main"}
           })}
      end
    end

    assert {:ok, %{"number" => 21, "existing" => true}} =
             DeliveryAdapter.find_or_create_pull_request(
               attrs(gateway, request,
                 branch: "agent/repair-metadata",
                 title: "PATCH-21: Repair metadata",
                 body: "Source issue and handoff"
               )
             )

    assert_receive {:request, :patch, "https://api.github.test/repos/acme/patches/pulls/21", _}
  end

  test "enables auto-merge through GraphQL using the PR node id", %{gateway: gateway} do
    parent = self()

    request = fn :post, "https://api.github.test/graphql", headers, body ->
      send(parent, {:graphql, headers, body})

      {:ok,
       response(200, %{
         "data" => %{
           "enablePullRequestAutoMerge" => %{
             "pullRequest" => %{
               "id" => "PR_node_18",
               "number" => 18,
               "url" => "https://github.com/acme/patches/pull/18",
               "autoMergeRequest" => %{"enabledAt" => "2026-08-29T00:00:00Z", "mergeMethod" => "SQUASH"}
             }
           }
         }
       })}
    end

    assert {:ok, proof} =
             DeliveryAdapter.enable_auto_merge(
               %{"number" => 18, "node_id" => "PR_node_18", "head" => "agent/new"},
               attrs(gateway, request)
             )

    assert proof["enabled"]
    assert proof["node_id"] == "PR_node_18"
    assert_receive {:graphql, headers, %{"variables" => %{"pullRequestId" => "PR_node_18", "mergeMethod" => "SQUASH"}}}
    assert {"Authorization", "Bearer test-token"} in headers
  end

  test "already enabled auto-merge is idempotent and does not issue a mutation", %{gateway: gateway} do
    request = fn _method, _url, _headers, _body -> flunk("already-enabled proof should not make a request") end

    assert {:ok, %{"enabled" => true, "already_enabled" => true}} =
             DeliveryAdapter.enable_auto_merge(
               %{
                 "number" => 19,
                 "node_id" => "PR_node_19",
                 "head" => "agent/ready",
                 "auto_merge" => %{"enabled" => true}
               },
               attrs(gateway, request)
             )
  end

  test "classifies permission failures separately from provider rate limits", %{gateway: gateway} do
    permission_request = fn :get, _url, _headers, nil -> {:ok, response(403, %{"message" => "Resource not accessible by integration"})} end

    assert {:error, {:github_permission_denied, %{status: 403}}} =
             DeliveryAdapter.find_or_create_pull_request(attrs(gateway, permission_request, branch: "agent/no-access"))

    rate_request = fn :get, _url, _headers, nil ->
      {:ok, response(429, %{"message" => "API rate limit exceeded"}, [{"retry-after", "12"}])}
    end

    assert {:error, {:github_rate_limited, _reset, _retry}} =
             DeliveryAdapter.find_or_create_pull_request(attrs(gateway, rate_request, branch: "agent/limited"))
  end

  test "redacts non-success response bodies from API errors", %{gateway: gateway} do
    secret = "sensitive-provider-response"
    request = fn :get, _url, _headers, nil -> {:ok, response(400, %{"message" => secret, "token" => secret})} end

    assert {:error, {:github_api_error, metadata}} =
             DeliveryAdapter.find_or_create_pull_request(attrs(gateway, request, branch: "agent/bad-request"))

    refute Map.has_key?(metadata, :body)
    refute Map.has_key?(metadata, :message)
    refute inspect(metadata) =~ secret
  end

  test "classifies a GraphQL permission error without mistaking it for success", %{gateway: gateway} do
    request = fn :post, _url, _headers, _body ->
      {:ok, response(200, %{"data" => nil, "errors" => [%{"type" => "FORBIDDEN", "message" => "permission denied"}]})}
    end

    assert {:error, {:github_permission_denied, %{status: 200}}} =
             DeliveryAdapter.enable_auto_merge(
               %{"number" => 20, "node_id" => "PR_node_20", "head" => "agent/denied"},
               attrs(gateway, request)
             )
  end

  test "redacts GraphQL error payloads after classifying them", %{gateway: gateway} do
    secret = "sensitive-graphql-response"

    request = fn :post, _url, _headers, _body ->
      {:ok,
       response(200, %{
         "data" => nil,
         "errors" => [
           %{
             "message" => secret,
             "path" => ["enablePullRequestAutoMerge", secret],
             "extensions" => %{"requestId" => secret, "details" => secret},
             "id" => secret
           }
         ]
       })}
    end

    assert {:error, {:github_api_error, %{kind: :graphql} = metadata}} =
             DeliveryAdapter.enable_auto_merge(
               %{"number" => 22, "node_id" => "PR_node_22", "head" => "agent/redacted"},
               attrs(gateway, request)
             )

    refute inspect(metadata) =~ secret
  end

  test "inspects only one PR and reports aggregate failed checks", %{gateway: gateway} do
    request = fn :get, url, _headers, nil ->
      cond do
        String.ends_with?(url, "/pulls/428") ->
          {:ok,
           response(200, %{
             "number" => 428,
             "state" => "open",
             "merged" => false,
             "mergeable_state" => "blocked",
             "head" => %{"sha" => "commit-428"}
           })}

        String.contains?(url, "/commits/commit-428/check-runs?") ->
          {:ok,
           response(200, %{
             "check_runs" => [
               %{"id" => 1, "name" => "quality", "status" => "completed", "conclusion" => "failure"},
               %{"id" => 2, "name" => "test", "status" => "completed", "conclusion" => "success"}
             ]
           })}
      end
    end

    assert {:ok, %{status: :failed, reason: :checks_failed, check_count: 2} = summary} =
             DeliveryAdapter.inspect_pull_request(attrs(gateway, request, pr_number: 428, commit_sha: "commit-428"))

    assert [%{name: "quality", conclusion: "failure"}] = summary.failed_checks
  end

  test "merge proof wins over stale check results", %{gateway: gateway} do
    request = fn :get, url, _headers, nil ->
      if String.ends_with?(url, "/pulls/429") do
        {:ok,
         response(200, %{
           "number" => 429,
           "state" => "closed",
           "merged" => true,
           "merge_commit_sha" => "merge-429",
           "head" => %{"sha" => "commit-429"}
         })}
      else
        {:ok, response(200, %{"check_runs" => []})}
      end
    end

    assert {:ok, %{status: :merged, merge_sha: "merge-429"}} =
             DeliveryAdapter.inspect_pull_request(attrs(gateway, request, pr_number: 429, commit_sha: "commit-429"))
  end

  test "merge conflicts are actionable even when no checks exist", %{gateway: gateway} do
    request = fn :get, url, _headers, nil ->
      cond do
        String.ends_with?(url, "/pulls/430") ->
          {:ok,
           response(200, %{
             "number" => 430,
             "state" => "open",
             "merged" => false,
             "mergeable_state" => "dirty",
             "head" => %{"sha" => "commit-430"}
           })}

        String.contains?(url, "/commits/commit-430/check-runs?") ->
          {:ok, response(200, %{"check_runs" => []})}
      end
    end

    assert {:ok, %{status: :conflict, reason: :merge_conflict, check_count: 0}} =
             DeliveryAdapter.inspect_pull_request(attrs(gateway, request, pr_number: 430, commit_sha: "commit-430"))
  end

  defp attrs(gateway, request, overrides \\ []) do
    Map.merge(
      %{
        tracker: %{api_key: "test-token", repo_owner: "acme", repo_name: "patches", endpoint: "https://api.github.test/graphql"},
        repo_owner: "acme",
        repo_name: "patches",
        branch: "agent/ready",
        base_branch: "main",
        issue_id: "PATCH-1",
        gateway_server: gateway,
        request_fun: request,
        base_url: "https://api.github.test"
      },
      Map.new(overrides)
    )
  end

  defp response(status, body, headers \\ []), do: %{status: status, body: body, headers: headers}
end

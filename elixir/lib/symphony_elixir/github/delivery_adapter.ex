defmodule SymphonyElixir.GitHub.DeliveryAdapter do
  @moduledoc """
  GitHub delivery adapter used by `SymphonyElixir.DeliveryController`.

  Pull-request discovery and creation use REST. Auto-merge uses the GitHub
  GraphQL mutation because it requires the pull request node id. Every request
  (including requests made while resolving GitHub App credentials) crosses the
  shared `GitHub.Gateway` boundary.

  `request_fun` and `base_url` may be supplied in the attribute map for tests.
  The production path obtains the repository and credentials from
  `SymphonyElixir.Config` and `SymphonyElixir.GitHub.Auth`.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.{Auth, Gateway}

  @github_api_base "https://api.github.com"
  @default_base_branch "main"

  @enable_auto_merge_mutation """
  mutation SymphonyEnablePullRequestAutoMerge(
    $pullRequestId: ID!,
    $mergeMethod: PullRequestMergeMethod
  ) {
    enablePullRequestAutoMerge(
      input: {pullRequestId: $pullRequestId, mergeMethod: $mergeMethod}
    ) {
      pullRequest {
        id
        number
        url
        autoMergeRequest {
          enabledAt
          mergeMethod
        }
      }
    }
  }
  """

  @type proof :: %{
          required(:number) => pos_integer(),
          required(:head) => String.t(),
          required(:node_id) => String.t(),
          required(:url) => String.t() | nil
        }

  @spec find_or_create_pull_request(map()) :: {:ok, map()} | {:error, term()}
  def find_or_create_pull_request(attrs) when is_map(attrs) do
    with {:ok, context} <- context(attrs) do
      case find_pull_request(context, attrs) do
        {:ok, pull_request} ->
          with {:ok, pull_request} <- update_pull_request_metadata(context, pull_request, attrs) do
            normalize_pull_request(pull_request, context, true)
          end

        :not_found ->
          create_pull_request(context, attrs)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def find_or_create_pull_request(_attrs), do: {:error, :invalid_delivery_attributes}

  @spec enable_auto_merge(map(), map()) :: {:ok, map()} | {:error, term()}
  def enable_auto_merge(pr, attrs) when is_map(pr) and is_map(attrs) do
    if auto_merge_enabled?(pr) do
      {:ok, auto_merge_proof(pr, true)}
    else
      with {:ok, context} <- context(attrs),
           {:ok, pull_request_id} <- pull_request_node_id(pr),
           {:ok, response} <-
             graphql_request(context, @enable_auto_merge_mutation, %{
               "pullRequestId" => pull_request_id,
               "mergeMethod" => merge_method(attrs)
             }),
           {:ok, mutation} <- graphql_field(response, "enablePullRequestAutoMerge") do
        pull_request = value(mutation, :pull_request) || value(mutation, :pullRequest) || %{}

        {:ok,
         %{
           "enabled" => true,
           "already_enabled" => false,
           "pull_request" => normalize_graphql_pull_request(pull_request, pr),
           "node_id" => pull_request_node_id_value(pull_request) || pull_request_id
         }}
      else
        {:error, {:graphql_errors, errors}} when is_list(errors) ->
          classify_graphql_errors(errors)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def enable_auto_merge(_pr, _attrs), do: {:error, :invalid_pull_request_attributes}

  @doc "Inspects one harness-owned pull request without scanning issues or the project board."
  @spec inspect_pull_request(map()) :: {:ok, map()} | {:error, term()}
  def inspect_pull_request(attrs) when is_map(attrs) do
    with {:ok, context} <- context(attrs),
         {:ok, pr_number} <- positive_integer(value(attrs, :pr_number), :missing_pull_request_number),
         {:ok, pull_request} <-
           rest_request(context, :get, "/repos/#{context.owner}/#{context.repo}/pulls/#{pr_number}"),
         {:ok, commit_sha} <- pull_request_commit_sha(pull_request, attrs),
         {:ok, checks} <-
           rest_request(
             context,
             :get,
             "/repos/#{context.owner}/#{context.repo}/commits/#{commit_sha}/check-runs?filter=latest&per_page=100"
           ) do
      summarize_pull_request(pull_request, checks, commit_sha)
    end
  end

  def inspect_pull_request(_attrs), do: {:error, :invalid_delivery_attributes}

  @doc "Normalizes a REST or GraphQL pull-request payload into delivery proof."
  @spec normalize_pull_request(map(), map() | nil, boolean()) :: {:ok, map()} | {:error, term()}
  def normalize_pull_request(pr, context \\ %{}, existing? \\ false)

  @spec normalize_pull_request(map(), map() | nil, boolean()) :: {:ok, map()} | {:error, term()}
  def normalize_pull_request(pr, context, existing?) when is_map(pr) do
    number = value(pr, :number) || value(pr, :pr_number)
    head = head_ref(pr)
    node_id = pull_request_node_id_value(pr)
    url = value(pr, :html_url) || value(pr, :url)

    cond do
      not positive_integer?(number) ->
        {:error, {:invalid_pull_request_proof, %{reason: :missing_number, response: pr}}}

      not is_binary(head) or String.trim(head) == "" ->
        {:error, {:invalid_pull_request_proof, %{reason: :missing_head, response: pr}}}

      not is_binary(node_id) or String.trim(node_id) == "" ->
        {:error, {:invalid_pull_request_proof, %{reason: :missing_node_id, response: pr}}}

      true ->
        repository =
          if is_map(context) and is_binary(Map.get(context, :owner)) and
               is_binary(Map.get(context, :repo)) do
            "#{context.owner}/#{context.repo}"
          end

        {:ok,
         %{
           "number" => normalize_integer(number),
           "head" => head,
           "head_ref" => head,
           "node_id" => node_id,
           "url" => url,
           "base" => value(pr, :base_branch) || value(pr, :base),
           "existing" => existing?,
           "auto_merge_enabled" => auto_merge_enabled?(pr),
           "repository" => repository
         }}
    end
  end

  def normalize_pull_request(_pr, _context, _existing?),
    do: {:error, {:invalid_pull_request_proof, :not_a_map}}

  @doc "Returns the normalized webhook-facing fields from a pull request payload."
  @spec normalize_webhook_pull_request(map()) :: map()
  def normalize_webhook_pull_request(payload) when is_map(payload) do
    %{
      "number" => value(payload, :number),
      "node_id" => pull_request_node_id_value(payload),
      "head" => head_ref(payload),
      "base" => base_ref(payload),
      "url" => value(payload, :html_url) || value(payload, :url),
      "merged" => truthy?(value(payload, :merged)),
      "auto_merge_enabled" => auto_merge_enabled?(payload)
    }
  end

  def normalize_webhook_pull_request(_payload), do: %{}

  defp summarize_pull_request(pull_request, checks_response, commit_sha) do
    check_runs = value(checks_response, :check_runs) || []
    merged? = truthy?(value(pull_request, :merged))
    merge_sha = value(pull_request, :merge_commit_sha)
    state = value(pull_request, :state)
    mergeable_state = value(pull_request, :mergeable_state)

    pending = Enum.filter(check_runs, &(value(&1, :status) != "completed"))

    failed =
      Enum.filter(check_runs, fn check ->
        value(check, :status) == "completed" and
          value(check, :conclusion) in [
            "action_required",
            "cancelled",
            "failure",
            "stale",
            "startup_failure",
            "timed_out"
          ]
      end)

    summary = %{
      pr_number: normalize_integer(value(pull_request, :number)),
      commit_sha: commit_sha,
      merge_sha: merge_sha,
      pending_checks: Enum.map(pending, &check_summary/1),
      failed_checks: Enum.map(failed, &check_summary/1),
      check_count: length(check_runs)
    }

    cond do
      merged? and is_binary(merge_sha) and merge_sha != "" -> {:ok, Map.put(summary, :status, :merged)}
      state == "closed" -> {:ok, Map.merge(summary, %{status: :failed, reason: :pull_request_closed})}
      pending != [] or check_runs == [] -> {:ok, Map.put(summary, :status, :pending)}
      failed != [] -> {:ok, Map.merge(summary, %{status: :failed, reason: :checks_failed})}
      mergeable_state == "dirty" -> {:ok, Map.merge(summary, %{status: :conflict, reason: :merge_conflict})}
      true -> {:ok, Map.put(summary, :status, :passed)}
    end
  end

  defp check_summary(check) do
    %{
      id: value(check, :id),
      name: value(check, :name),
      status: value(check, :status),
      conclusion: value(check, :conclusion),
      url: value(check, :html_url) || value(check, :details_url)
    }
  end

  defp pull_request_commit_sha(pull_request, attrs) do
    head = value(pull_request, :head) || %{}
    sha = value(head, :sha) || value(attrs, :commit_sha)

    if is_binary(sha) and sha != "", do: {:ok, sha}, else: {:error, :missing_pull_request_commit_sha}
  end

  defp positive_integer(value, _reason) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, reason) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, reason}
    end
  end

  defp positive_integer(_value, reason), do: {:error, reason}

  defp find_pull_request(context, attrs) do
    branch = required_string(attrs, :branch)
    base_branch = attrs |> value(:base_branch) |> default(@default_base_branch)

    if is_binary(branch) and branch != "" and is_binary(base_branch) and base_branch != "" do
      query = URI.encode_query(%{"head" => "#{context.owner}:#{branch}", "base" => base_branch, "state" => "open", "per_page" => "100"})

      case rest_request(context, :get, "/repos/#{context.owner}/#{context.repo}/pulls?#{query}") do
        {:ok, body} when is_list(body) ->
          case Enum.find(body, &same_pull_request?(&1, branch, base_branch)) do
            nil -> :not_found
            pull_request -> {:ok, pull_request}
          end

        {:ok, body} ->
          {:error, {:github_api_error, %{kind: :invalid_pull_request_list, body: body}}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :missing_github_branch}
    end
  end

  defp create_pull_request(context, attrs) do
    branch = required_string(attrs, :branch)
    base_branch = attrs |> value(:base_branch) |> default(@default_base_branch)
    issue_id = required_string(attrs, :issue_id) || "delivery"
    title = required_string(attrs, :title) || "Symphony: #{issue_id}"
    body = required_string(attrs, :body) || required_string(attrs, :description)

    payload = %{
      "title" => title,
      "head" => branch,
      "base" => base_branch,
      "body" => body
    }

    case rest_request(context, :post, "/repos/#{context.owner}/#{context.repo}/pulls", payload) do
      {:ok, pull_request} when is_map(pull_request) ->
        normalize_pull_request(pull_request, context, false)

      {:error, {:github_api_error, %{status: 422}}} ->
        # A concurrent delivery may have created the PR between our list and
        # create calls. Re-listing is idempotent and remains gateway-bound.
        case find_pull_request(context, attrs) do
          {:ok, pull_request} -> normalize_pull_request(pull_request, context, true)
          :not_found -> {:error, {:github_api_error, %{status: 422, kind: :unprocessable_entity}}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, body} ->
        {:error, {:github_api_error, %{kind: :invalid_pull_request_response, body: body}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_pull_request_metadata(context, pull_request, attrs) do
    desired =
      %{}
      |> maybe_put_changed("title", value(pull_request, :title), required_string(attrs, :title))
      |> maybe_put_changed("body", value(pull_request, :body), required_string(attrs, :body))

    if desired == %{} do
      {:ok, pull_request}
    else
      number = value(pull_request, :number)

      case rest_request(context, :patch, "/repos/#{context.owner}/#{context.repo}/pulls/#{number}", desired) do
        {:ok, updated} when is_map(updated) -> {:ok, updated}
        {:ok, body} -> {:error, {:github_api_error, %{kind: :invalid_pull_request_update, body: body}}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_put_changed(map, _key, _current, nil), do: map
  defp maybe_put_changed(map, _key, current, desired) when current == desired, do: map
  defp maybe_put_changed(map, key, _current, desired), do: Map.put(map, key, desired)

  defp rest_request(context, method, path, body \\ nil) do
    url = context.rest_base_url <> path

    result =
      Gateway.request(
        :rest,
        fn -> invoke_request(context.request_fun, method, url, context.headers, body) end,
        gateway_options(context)
      )

    normalize_http_result(result, method, url)
  end

  defp graphql_request(context, query, variables) do
    result =
      Gateway.request(
        :graphql,
        fn ->
          invoke_request(
            context.request_fun,
            :post,
            context.graphql_url,
            context.headers,
            %{"query" => query, "variables" => variables}
          )
        end,
        gateway_options(context)
      )

    with {:ok, body} <- normalize_http_result(result, :post, context.graphql_url) do
      if is_map(body) and is_list(Map.get(body, "errors")) and Map.has_key?(body, "data") do
        {:error, {:graphql_errors, Map.get(body, "errors")}}
      else
        {:ok, body}
      end
    end
  end

  defp normalize_http_result({:ok, %{status: status} = response}, method, url) when is_integer(status) do
    body = Map.get(response, :body)

    cond do
      status in 200..299 -> {:ok, body}
      status in [401, 403] and rate_limited_response?(response) -> {:error, rate_limit_error(response)}
      status in [401, 403] -> {:error, permission_error(status, response, method, url)}
      status == 429 -> {:error, rate_limit_error(response)}
      status == 408 or status in 500..599 -> {:error, provider_error(status, response, method, url)}
      true -> {:error, api_error(status, response, method, url)}
    end
  end

  defp normalize_http_result({:error, {:github_rate_limited, _reset, _retry} = error}, _method, _url), do: {:error, error}

  defp normalize_http_result({:error, {:github_gateway_unavailable, _reason} = error}, _method, _url),
    do: {:error, {:github_provider_unavailable, error}}

  defp normalize_http_result({:error, reason}, method, url),
    do: {:error, {:github_provider_unavailable, %{reason: reason, method: method, url: url}}}

  defp normalize_http_result(other, method, url),
    do: {:error, {:github_provider_unavailable, %{reason: {:invalid_response, other}, method: method, url: url}}}

  defp graphql_field(body, field) when is_map(body) do
    case Map.get(body, "data") || Map.get(body, :data) do
      data when is_map(data) ->
        case Map.get(data, field) || Map.get(data, String.to_atom(field)) do
          nil -> {:error, {:github_api_error, %{kind: :missing_graphql_field, field: field}}}
          value -> {:ok, value}
        end

      _ ->
        {:error, {:github_api_error, %{kind: :missing_graphql_data}}}
    end
  end

  defp graphql_field(_body, _field), do: {:error, {:github_api_error, %{kind: :invalid_graphql_response}}}

  defp classify_graphql_errors(errors) do
    message = errors |> Enum.map(&error_message/1) |> Enum.join("; ")
    downcased = String.downcase(message)

    cond do
      Enum.any?(errors, &already_enabled_error?/1) or String.contains?(downcased, "already enabled") ->
        {:ok, %{"enabled" => true, "already_enabled" => true, "errors" => errors}}

      Enum.any?(errors, &rate_limit_error?/1) ->
        {:error, {:github_rate_limited, nil, nil}}

      String.contains?(downcased, "forbidden") or
        String.contains?(downcased, "permission") or
          String.contains?(downcased, "resource not accessible") ->
        {:error, {:github_permission_denied, %{status: 200, message: message}}}

      true ->
        {:error, {:github_api_error, %{kind: :graphql, message: message, errors: errors}}}
    end
  end

  defp context(attrs) do
    tracker = value(attrs, :tracker) || configured_tracker()
    request_fun = value(attrs, :request_fun) || (&default_request/4)
    gateway_server = value(attrs, :gateway_server) || Gateway

    with {:ok, tracker} <- valid_tracker(tracker),
         {:ok, token} <- authorization_token(tracker, request_fun, gateway_server),
         {:ok, owner} <- required_config_string(value(attrs, :repo_owner) || tracker.repo_owner, :missing_github_repo_owner),
         {:ok, repo} <- required_config_string(value(attrs, :repo_name) || tracker.repo_name, :missing_github_repo_name) do
      graphql_url = value(attrs, :graphql_url) || tracker.endpoint || graphql_endpoint(tracker)
      rest_base_url = value(attrs, :base_url) || value(attrs, :rest_base_url) || rest_base_url(graphql_url)

      {:ok,
       %{
         owner: owner,
         repo: repo,
         token: token,
         headers: github_headers(token),
         request_fun: request_fun,
         gateway_server: gateway_server,
         graphql_url: graphql_url,
         rest_base_url: String.trim_trailing(rest_base_url, "/"),
         base_branch: value(attrs, :base_branch) || @default_base_branch
       }}
    end
  rescue
    error -> {:error, {:github_configuration_error, Exception.message(error)}}
  end

  defp configured_tracker, do: Config.settings!().tracker

  defp valid_tracker(tracker) when is_map(tracker), do: {:ok, tracker}
  defp valid_tracker(_tracker), do: {:error, :missing_github_tracker_config}

  defp authorization_token(tracker, request_fun, gateway_server) do
    auth_request_fun = fn method, url, body, headers ->
      invoke_request(request_fun, method, url, headers, body)
    end

    case Auth.project_authorization_token(tracker,
           request_fun: auth_request_fun,
           gateway_server: gateway_server
         ) do
      {:ok, token} -> {:ok, token}
      {:error, :missing_github_api_token} -> {:error, :missing_github_api_token}
      {:error, :missing_github_oauth_token} -> {:error, :missing_github_oauth_token}
      {:error, {:github_rate_limited, _reset, _retry} = error} -> {:error, error}
      {:error, reason} -> {:error, {:github_authentication_error, reason}}
    end
  end

  defp default_request(:get, url, headers, _body), do: Req.get(url, headers: headers, receive_timeout: 35_000)

  defp default_request(:post, url, headers, body),
    do: Req.post(url, headers: headers, json: body, receive_timeout: 35_000)

  defp default_request(:patch, url, headers, body),
    do: Req.patch(url, headers: headers, json: body, receive_timeout: 35_000)

  defp invoke_request(fun, method, url, headers, body) when is_function(fun, 4),
    do: fun.(method, url, headers, body)

  defp invoke_request(fun, method, url, headers, body) when is_function(fun, 3),
    do: fun.(method, url, %{headers: headers, body: body})

  defp invoke_request(_fun, _method, _url, _headers, _body), do: {:error, :invalid_request_function}

  defp gateway_options(%{gateway_server: server}), do: [server: server]

  defp github_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"Content-Type", "application/json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  defp rest_base_url(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        port_suffix = if is_integer(port) and port not in [80, 443], do: ":#{port}", else: ""
        scheme <> "://" <> host <> port_suffix

      _ ->
        @github_api_base
    end
  end

  defp rest_base_url(_endpoint), do: @github_api_base
  defp graphql_endpoint(%{endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp graphql_endpoint(_tracker), do: @github_api_base <> "/graphql"

  defp same_pull_request?(pull_request, branch, base_branch) when is_map(pull_request) do
    head = head_ref(pull_request)
    base = base_ref(pull_request)
    head == branch and (is_nil(base) or base == base_branch)
  end

  defp same_pull_request?(_pull_request, _branch, _base_branch), do: false

  defp head_ref(payload) do
    head = value(payload, :head)

    cond do
      is_map(head) -> value(head, :ref) || value(head, :branch)
      is_binary(head) -> head
      true -> value(payload, :head_ref) || value(payload, :branch)
    end
  end

  defp base_ref(payload) do
    base = value(payload, :base)

    if is_map(base), do: value(base, :ref) || value(base, :branch), else: base || value(payload, :base_branch)
  end

  defp pull_request_node_id(pr) do
    case pull_request_node_id_value(pr) do
      node_id when is_binary(node_id) and node_id != "" -> {:ok, node_id}
      _ -> {:error, {:invalid_pull_request_proof, %{reason: :missing_node_id, pull_request: pr}}}
    end
  end

  defp pull_request_node_id_value(payload) when is_map(payload) do
    value(payload, :node_id) || value(payload, :nodeId) ||
      value(payload, :id)
      |> case do
        value when is_binary(value) -> value
        value when is_integer(value) -> Integer.to_string(value)
        _ -> nil
      end
  end

  defp pull_request_node_id_value(_payload), do: nil

  defp normalize_graphql_pull_request(pull_request, fallback) do
    %{
      "number" => value(pull_request, :number) || value(fallback, :number),
      "node_id" => pull_request_node_id_value(pull_request) || pull_request_node_id_value(fallback),
      "url" => value(pull_request, :url) || value(fallback, :url),
      "auto_merge" => value(pull_request, :auto_merge_request) || value(pull_request, :autoMergeRequest)
    }
  end

  defp auto_merge_proof(pr, already_enabled?) do
    %{
      "enabled" => true,
      "already_enabled" => already_enabled?,
      "node_id" => pull_request_node_id_value(pr),
      "number" => value(pr, :number) || value(pr, :pr_number),
      "url" => value(pr, :html_url) || value(pr, :url)
    }
  end

  defp auto_merge_enabled?(payload) when is_map(payload) do
    truthy?(value(payload, :auto_merge_enabled)) or
      truthy?(value(payload, :autoMergeEnabled)) or
      not is_nil(value(payload, :auto_merge)) or
      not is_nil(value(payload, :auto_merge_request)) or
      not is_nil(value(payload, :autoMergeRequest))
  end

  defp auto_merge_enabled?(_payload), do: false

  defp merge_method(attrs) do
    case value(attrs, :merge_method) do
      method when method in [:merge, :squash, :rebase] -> String.upcase(to_string(method))
      method when method in ["MERGE", "SQUASH", "REBASE"] -> method
      _ -> "SQUASH"
    end
  end

  defp permission_error(status, response, method, url),
    do: {:github_permission_denied, %{status: status, message: response_message(response), method: method, url: url}}

  defp provider_error(status, response, method, url),
    do: {:github_provider_unavailable, %{status: status, message: response_message(response), method: method, url: url}}

  defp api_error(status, response, method, url),
    do: {:github_api_error, %{status: status, message: response_message(response), body: Map.get(response, :body), method: method, url: url}}

  defp rate_limit_error(response),
    do: {:github_rate_limited, response_header(response, "x-ratelimit-reset"), response_header(response, "retry-after")}

  defp rate_limited_response?(response) do
    response_header(response, "x-ratelimit-remaining") == "0" or
      response_message(response) |> String.downcase() |> String.contains?("rate limit")
  end

  defp response_message(response) do
    case Map.get(response, :body) do
      %{"message" => message} -> to_string(message)
      %{"errors" => errors} when is_list(errors) -> Enum.map_join(errors, "; ", &error_message/1)
      body when is_binary(body) -> body
      _ -> ""
    end
  end

  defp response_header(%{headers: headers}, name) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == String.downcase(name), do: List.first(List.wrap(value))
    end)
    |> case do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp response_header(%{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == String.downcase(name), do: value |> List.wrap() |> List.first() |> to_string()
    end)
  end

  defp response_header(_response, _name), do: nil

  defp error_message(error) when is_map(error), do: to_string(value(error, :message) || value(error, :type) || "")
  defp error_message(error), do: to_string(error)

  defp already_enabled_error?(error) do
    text = error_message(error) |> String.downcase()
    type = value(error, :type) || value(error, :code)
    type in ["PULL_REQUEST_AUTO_MERGE_ALREADY_ENABLED", "AUTO_MERGE_ALREADY_ENABLED"] or String.contains?(text, "already enabled")
  end

  defp rate_limit_error?(error), do: error_message(error) |> String.downcase() |> String.contains?("rate limit")

  defp required_config_string(value, reason) when is_binary(value) do
    if String.trim(value) == "", do: {:error, reason}, else: {:ok, String.trim(value)}
  end

  defp required_config_string(_value, reason), do: {:error, reason}

  defp required_string(map, key) do
    case value(map, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: String.trim(value)
      _ -> nil
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil
  defp default(nil, fallback), do: fallback
  defp default(value, _fallback), do: value

  defp positive_integer?(value), do: (is_integer(value) and value > 0) or (is_binary(value) and match?({_, ""}, Integer.parse(value)))
  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(value) when is_binary(value), do: String.to_integer(value)
  defp normalize_integer(value), do: value
  defp truthy?(value), do: value in [true, "true", 1, "1"]
end

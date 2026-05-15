defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @issue_fields """
  id
  number
  title
  body
  state
  stateReason
  url
  assignees(first: 10) { nodes { login } }
  labels(first: 30) { nodes { name } }
  milestone { id number title dueOn state description }
  parent { id number title state url }
  subIssues(first: 20) { nodes { id number title state url } }
  projectItems(first: 20) {
    nodes {
      id
      isArchived
      project { id number title url }
      fieldValues(first: 50) {
        nodes {
          __typename
          ... on ProjectV2ItemFieldDateValue {
            date
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldIterationValue {
            title
            startDate
            duration
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldLabelValue {
            labels(first: 20) { nodes { id name } }
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldMilestoneValue {
            milestone { id number title dueOn state }
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldNumberValue {
            number
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldPullRequestValue {
            pullRequests(first: 20) { nodes { id number url title state } }
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldRepositoryValue {
            repository { id nameWithOwner url }
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldReviewerValue {
            reviewers(first: 20) { nodes { ... on User { id login } } }
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldSingleSelectValue {
            name
            optionId
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldTextValue {
            text
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemFieldUserValue {
            users(first: 20) { nodes { id login } }
            field { ... on ProjectV2FieldCommon { id name } }
          }
          ... on ProjectV2ItemIssueFieldValue {
            issue { id number title state url }
            field { ... on ProjectV2FieldCommon { id name } }
          }
        }
      }
    }
  }
  createdAt
  updatedAt
  """

  @query """
  query SymphonyGitHubCandidateIssues($owner: String!, $name: String!, $after: String, $first: Int!, $states: [IssueState!]) {
    repository(owner: $owner, name: $name) {
      issues(first: $first, after: $after, states: $states, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes {
          #{@issue_fields}
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyGitHubIssuesById($ids: [ID!]!) {
    nodes(ids: $ids) {
      ... on Issue {
        #{@issue_fields}
      }
    }
  }
  """

  @resolve_issue_number_query """
  query SymphonyGitHubIssueNumberByNodeId($id: ID!) {
    node(id: $id) {
      ... on Issue {
        number
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker!(tracker),
         {:ok, issues} <- fetch_repository_issues(tracker.repo_owner, tracker.repo_name, tracker.active_states) do
      {:ok, Enum.filter(issues, &candidate_issue?(&1, tracker.active_states))}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker!(tracker),
         {:ok, issues} <- fetch_repository_issues(tracker.repo_owner, tracker.repo_name, normalized_states) do
      {:ok, Enum.filter(issues, &candidate_issue?(&1, normalized_states))}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)
    tracker = Config.settings!().tracker

    case ids do
      [] ->
        {:ok, []}

      _ ->
        with :ok <- validate_tracker!(tracker),
             {:ok, body} <- graphql(@query_by_ids, %{ids: ids}),
             {:ok, issues} <- decode_nodes_response(body) do
          issue_order_index = issue_order_index(ids)

          issues
          |> Enum.sort_by(fn %Issue{id: id} -> Map.get(issue_order_index, id, map_size(issue_order_index)) end)
          |> then(&{:ok, &1})
        end
    end
  end

  @spec graphql(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}) when is_binary(query) and is_map(variables) do
    payload = %{"query" => query, "variables" => variables}

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- post_graphql_request(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error("GitHub GraphQL request failed status=#{response.status} body=#{summarize_error_body(response.body)}")

        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers(),
         {:ok, %{status: status}} when status in [200, 201] <-
           Req.post("https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/comments",
             headers: headers,
             json: %{"body" => body}
           ) do
      :ok
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub create comment failed status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers(),
         state <- normalize_rest_issue_state(state_name),
         {:ok, %{status: status}} when status in [200] <-
           Req.patch("https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}",
             headers: headers,
             json: %{"state" => state}
           ) do
      :ok
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub update issue state failed status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_tracker!(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_github_api_token}
      not is_binary(tracker.repo_owner) -> {:error, :missing_github_repo_owner}
      not is_binary(tracker.repo_name) -> {:error, :missing_github_repo_name}
      true -> :ok
    end
  end

  defp fetch_repository_issues(owner, repo, active_states) do
    fetch_repository_issues_page(owner, repo, active_states, nil, [])
  end

  defp fetch_repository_issues_page(owner, repo, active_states, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             owner: owner,
             name: repo,
             first: @issue_page_size,
             after: after_cursor,
             states: github_states_filter(active_states)
           }),
         {:ok, issues, page_info} <- decode_repository_page_response(body) do
      updated = Enum.reverse(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} -> fetch_repository_issues_page(owner, repo, active_states, next_cursor, updated)
        :done -> {:ok, Enum.reverse(updated)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_repository_page_response(%{
         "data" => %{
           "repository" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         }
       }) do
    issues =
      nodes
      |> Enum.map(&normalize_issue/1)
      |> Enum.reject(&is_nil/1)

    {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_repository_page_response(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}
  defp decode_repository_page_response(_payload), do: {:error, :github_unknown_payload}

  defp decode_nodes_response(%{"data" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      %{} = issue -> normalize_issue(issue)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> then(&{:ok, &1})
  end

  defp decode_nodes_response(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}
  defp decode_nodes_response(_payload), do: {:error, :github_unknown_payload}

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0,
       do: {:ok, end_cursor}

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :github_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue) when is_map(issue) do
    number = issue["number"]
    identifier = if is_integer(number), do: "##{number}", else: nil
    assignees = get_in(issue, ["assignees", "nodes"]) || []
    first_assignee = Enum.at(assignees, 0)

    metadata = %{
      "tracker" => "github",
      "number" => number,
      "state_reason" => issue["stateReason"],
      "milestone" => normalize_milestone(issue["milestone"]),
      "parent" => normalize_linked_issue(issue["parent"]),
      "sub_issues" => normalize_linked_issues(get_in(issue, ["subIssues", "nodes"])),
      "project_items" => normalize_project_items(get_in(issue, ["projectItems", "nodes"]))
    }

    %Issue{
      id: issue["id"],
      identifier: identifier,
      title: issue["title"],
      description: issue["body"],
      priority: nil,
      state: issue["state"],
      branch_name: nil,
      url: issue["url"],
      assignee_id: normalize_assignee(first_assignee),
      blocked_by: normalize_blockers(issue["parent"]),
      labels: normalize_labels(issue),
      assigned_to_worker: true,
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
    |> Map.put(:tracker_metadata, metadata)
  end

  defp normalize_issue(_issue), do: nil

  defp normalize_labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_labels(_), do: []

  defp normalize_blockers(%{} = parent) do
    [
      %{
        id: parent["id"],
        identifier: linked_identifier(parent["number"]),
        state: parent["state"]
      }
    ]
  end

  defp normalize_blockers(_), do: []

  defp normalize_linked_issue(nil), do: nil

  defp normalize_linked_issue(%{} = issue) do
    %{
      "id" => issue["id"],
      "identifier" => linked_identifier(issue["number"]),
      "title" => issue["title"],
      "state" => issue["state"],
      "url" => issue["url"]
    }
  end

  defp normalize_linked_issues(issues) when is_list(issues), do: Enum.map(issues, &normalize_linked_issue/1)
  defp normalize_linked_issues(_), do: []

  defp normalize_milestone(nil), do: nil

  defp normalize_milestone(%{} = milestone) do
    %{
      "id" => milestone["id"],
      "number" => milestone["number"],
      "title" => milestone["title"],
      "state" => milestone["state"],
      "description" => milestone["description"],
      "due_on" => milestone["dueOn"]
    }
  end

  defp normalize_project_items(items) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        "id" => item["id"],
        "is_archived" => item["isArchived"] == true,
        "project" => normalize_project(item["project"]),
        "field_values" => normalize_project_field_values(get_in(item, ["fieldValues", "nodes"]))
      }
    end)
  end

  defp normalize_project_items(_), do: []

  defp normalize_project(nil), do: nil

  defp normalize_project(%{} = project) do
    %{
      "id" => project["id"],
      "number" => project["number"],
      "title" => project["title"],
      "url" => project["url"]
    }
  end

  defp normalize_project_field_values(values) when is_list(values) do
    Enum.map(values, fn value ->
      base = %{
        "type" => value["__typename"],
        "field" => normalize_project_field(value["field"])
      }

      Map.merge(base, extract_field_value_payload(value))
    end)
  end

  defp normalize_project_field_values(_), do: []

  defp normalize_project_field(nil), do: nil
  defp normalize_project_field(%{} = field), do: %{"id" => field["id"], "name" => field["name"]}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldSingleSelectValue"} = value),
    do: %{"name" => value["name"], "option_id" => value["optionId"]}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldDateValue"} = value),
    do: %{"date" => value["date"]}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldIterationValue"} = value),
    do: %{"title" => value["title"], "start_date" => value["startDate"], "duration" => value["duration"]}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldLabelValue"} = value),
    do: %{"labels" => normalize_label_nodes(get_in(value, ["labels", "nodes"]))}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldMilestoneValue"} = value),
    do: %{"milestone" => normalize_milestone(value["milestone"])}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldNumberValue"} = value),
    do: %{"number" => value["number"]}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldPullRequestValue"} = value),
    do: %{"pull_requests" => get_in(value, ["pullRequests", "nodes"]) || []}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldRepositoryValue"} = value),
    do: %{"repository" => value["repository"]}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldReviewerValue"} = value),
    do: %{"reviewers" => get_in(value, ["reviewers", "nodes"]) || []}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldTextValue"} = value),
    do: %{"text" => value["text"]}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemFieldUserValue"} = value),
    do: %{"users" => get_in(value, ["users", "nodes"]) || []}

  defp extract_field_value_payload(%{"__typename" => "ProjectV2ItemIssueFieldValue"} = value),
    do: %{"issue" => normalize_linked_issue(value["issue"])}

  defp extract_field_value_payload(_), do: %{}

  defp normalize_label_nodes(labels) when is_list(labels) do
    Enum.map(labels, fn label -> %{"id" => label["id"], "name" => label["name"]} end)
  end

  defp normalize_label_nodes(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_assignee(%{"login" => login}) when is_binary(login), do: login
  defp normalize_assignee(_assignee), do: nil

  defp linked_identifier(number) when is_integer(number), do: "##{number}"
  defp linked_identifier(_number), do: nil

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp github_states_filter(active_states) when is_list(active_states) do
    has_open? = Enum.any?(active_states, &(normalize_state_name(&1) == "open"))
    has_closed? = Enum.any?(active_states, &(normalize_state_name(&1) == "closed"))

    cond do
      has_open? and has_closed? -> ["OPEN", "CLOSED"]
      has_closed? -> ["CLOSED"]
      true -> ["OPEN"]
    end
  end

  defp normalize_state_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp candidate_issue?(%Issue{} = issue, active_states) when is_list(active_states) do
    normalized_active_states = Enum.map(active_states, &normalize_state_name/1)

    issue_state = normalize_state_name(issue.state || "")
    project_state_values = project_state_values(issue)

    Enum.member?(normalized_active_states, issue_state) or
      Enum.any?(project_state_values, &Enum.member?(normalized_active_states, &1))
  end

  defp candidate_issue?(_issue, _active_states), do: false

  defp project_state_values(%Issue{} = issue) do
    issue
    |> Map.get(:tracker_metadata, %{})
    |> Map.get("project_items", [])
    |> Enum.flat_map(fn item ->
      item
      |> Map.get("field_values", [])
      |> Enum.flat_map(fn value ->
        field_name =
          value
          |> Map.get("field", %{})
          |> Map.get("name")
          |> normalize_state_name()

        value_name = value |> Map.get("name") |> normalize_state_name()

        if field_name == "status" and value_name != "", do: [value_name], else: []
      end)
    end)
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp repo_tracker_config do
    tracker = Config.settings!().tracker

    if is_binary(tracker.repo_owner) and String.trim(tracker.repo_owner) != "" and is_binary(tracker.repo_name) and
         String.trim(tracker.repo_name) != "" do
      {:ok, tracker}
    else
      {:error, :missing_github_repo}
    end
  end

  defp rest_headers do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"}
         ]}

      _ ->
        {:error, :missing_github_api_token}
    end
  end

  defp parse_issue_number(issue_id) do
    id = String.trim(issue_id)

    cond do
      String.match?(id, ~r/^\d+$/) ->
        {number, ""} = Integer.parse(id)
        {:ok, number}

      String.match?(id, ~r/^#\d+$/) ->
        {number, ""} = id |> String.trim_leading("#") |> Integer.parse()
        {:ok, number}

      true ->
        resolve_issue_number_by_node_id(id)
    end
  end

  defp resolve_issue_number_by_node_id(id) when is_binary(id) do
    with {:ok, body} <- graphql(@resolve_issue_number_query, %{id: id}),
         number when is_integer(number) <- get_in(body, ["data", "node", "number"]) do
      {:ok, number}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unsupported_issue_identifier}
    end
  end

  defp normalize_rest_issue_state(state_name) do
    case state_name |> normalize_state_name() do
      "done" -> "closed"
      "closed" -> "closed"
      "completed" -> "closed"
      "cancelled" -> "closed"
      "canceled" -> "closed"
      _ -> "open"
    end
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end

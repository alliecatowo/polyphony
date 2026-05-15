defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub tracker client.

  Supports:
  - reading issues via GraphQL for orchestration polling
  - writing issue comments/state via REST
  - writing Project v2 field values via GraphQL mutations
  - parent/sub-issue graph mutations via GraphQL
  """

  require Logger
  alias SymphonyElixir.{Config, GitHub.Issue}

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
  closedByPullRequestsReferences(first: 20) {
    nodes {
      id
      number
      url
      title
      state
      mergedAt
      repository { nameWithOwner }
    }
  }
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
            iterationId
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

  @repo_issues_query """
  query SymphonyGitHubRepositoryIssues($owner: String!, $name: String!, $after: String, $first: Int!, $states: [IssueState!]) {
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

  @project_items_query """
  query SymphonyGitHubProjectIssues($projectId: ID!, $after: String, $first: Int!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        id
        title
        url
        items(first: $first, after: $after) {
          nodes {
            id
            isArchived
            content {
              ... on Issue {
                #{@issue_fields}
                repository { id nameWithOwner }
              }
            }
            fieldValues(first: 50) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldDateValue {
                  date
                  field { ... on ProjectV2FieldCommon { id name } }
                }
                ... on ProjectV2ItemFieldIterationValue {
                  iterationId
                  title
                  startDate
                  duration
                  field { ... on ProjectV2FieldCommon { id name } }
                }
                ... on ProjectV2ItemFieldNumberValue {
                  number
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
              }
            }
          }
          pageInfo { hasNextPage endCursor }
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

  @mutation_update_project_field """
  mutation SymphonyGitHubUpdateProjectField(
    $projectId: ID!,
    $itemId: ID!,
    $fieldId: ID!,
    $value: ProjectV2FieldValue!
  ) {
    updateProjectV2ItemFieldValue(
      input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value}
    ) {
      projectV2Item { id }
    }
  }
  """

  @mutation_clear_project_field """
  mutation SymphonyGitHubClearProjectField(
    $projectId: ID!,
    $itemId: ID!,
    $fieldId: ID!
  ) {
    clearProjectV2ItemFieldValue(
      input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId}
    ) {
      projectV2Item { id }
    }
  }
  """

  @mutation_add_sub_issue """
  mutation SymphonyGitHubAddSubIssue($issueId: ID!, $subIssueId: ID!) {
    addSubIssue(input: {issueId: $issueId, subIssueId: $subIssueId}) {
      issue { id }
      subIssue { id }
    }
  }
  """

  @mutation_remove_sub_issue """
  mutation SymphonyGitHubRemoveSubIssue($issueId: ID!, $subIssueId: ID!) {
    removeSubIssue(input: {issueId: $issueId, subIssueId: $subIssueId}) {
      issue { id }
      subIssue { id }
    }
  }
  """

  @mutation_reprioritize_sub_issue """
  mutation SymphonyGitHubReprioritizeSubIssue(
    $issueId: ID!,
    $subIssueId: ID!,
    $afterId: ID
  ) {
    reprioritizeSubIssue(input: {issueId: $issueId, subIssueId: $subIssueId, afterId: $afterId}) {
      issue { id }
      subIssue { id }
    }
  }
  """

  @owner_lookup_query """
  query SymphonyGitHubOwnerLookup($login: String!, $isOrg: Boolean!, $isUser: Boolean!) {
    organization(login: $login) @include(if: $isOrg) {
      id
      projectsV2(first: 100) {
        nodes { id title url number }
      }
    }
    user(login: $login) @include(if: $isUser) {
      id
      projectsV2(first: 100) {
        nodes { id title url number }
      }
    }
  }
  """

  @create_project_query """
  mutation SymphonyGitHubCreateProject($ownerId: ID!, $title: String!) {
    createProjectV2(input: {ownerId: $ownerId, title: $title}) {
      projectV2 { id title url number }
    }
  }
  """

  @project_fields_query """
  query SymphonyGitHubProjectFields($projectId: ID!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        fields(first: 100) {
          nodes {
            ... on ProjectV2FieldCommon {
              id
              name
              dataType
            }
            ... on ProjectV2SingleSelectField {
              options { id name }
            }
          }
        }
      }
    }
  }
  """

  @create_project_field_query """
  mutation SymphonyGitHubCreateProjectField($projectId: ID!, $name: String!, $dataType: ProjectV2CustomFieldType!) {
    createProjectV2Field(input: {projectId: $projectId, name: $name, dataType: $dataType}) {
      projectV2Field {
        ... on ProjectV2FieldCommon { id name dataType }
      }
    }
  }
  """

  @add_project_item_query """
  mutation SymphonyGitHubAddProjectItem($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
      item { id }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker!(tracker),
         {:ok, project_ctx} <- ensure_project_context(tracker),
         {:ok, _} <- ensure_project_fields(project_ctx.project_id),
         {:ok, _} <- ensure_repository_issues_in_project(tracker, project_ctx.project_id),
         {:ok, issues} <- fetch_project_issues(project_ctx.project_id, tracker.repo_owner, tracker.repo_name) do
      {:ok, Enum.filter(issues, &candidate_issue?(&1, tracker.active_states))}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker!(tracker),
         {:ok, project_ctx} <- ensure_project_context(tracker),
         {:ok, issues} <- fetch_project_issues(project_ctx.project_id, tracker.repo_owner, tracker.repo_name) do
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
    comment = String.trim(body)

    with true <- comment != "" or {:error, :empty_comment_body},
         {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers(),
         {:ok, %{status: status}} when status in [200, 201] <-
           Req.post("https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/comments",
             headers: headers,
             json: %{"body" => comment}
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
    tracker = Config.settings!().tracker

    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(tracker),
         {:ok, headers} <- rest_headers(),
         {state, state_reason} <- normalize_rest_issue_state(state_name, tracker.status_map),
         payload <- issue_state_payload(state, state_reason),
         {:ok, %{status: status}} when status in [200] <-
           Req.patch("https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}",
             headers: headers,
             json: payload
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

  @spec reconcile_issue_state_from_project_status(map()) :: :ok | {:error, term()}
  def reconcile_issue_state_from_project_status(%{id: issue_id} = issue) when is_binary(issue_id) do
    project_status =
      issue
      |> project_state_values()
      |> List.first()

    if is_binary(project_status) and project_status != "" do
      update_issue_state(issue_id, project_status)
    else
      :ok
    end
  end

  def reconcile_issue_state_from_project_status(_issue), do: :ok

  @spec reconcile_issue_project_custom_fields(map(), map()) :: :ok | {:error, term()}
  def reconcile_issue_project_custom_fields(issue, desired_fields)
      when is_map(issue) and is_map(desired_fields) do
    with {:ok, tracker} <- repo_tracker_config(),
         {:ok, project_id} <- resolve_issue_project_id(issue, tracker),
         {:ok, project_item} <- resolve_issue_project_item(issue),
         item_id when is_binary(item_id) <- project_item["id"] do
      project_item
      |> project_field_values_by_name()
      |> reconcile_project_field_values(project_id, item_id, desired_fields)
    else
      {:error, _reason} -> :ok
      _ -> :ok
    end
  end

  @spec reconcile_issue_milestone(String.t(), integer() | nil) :: :ok | {:error, term()}
  def reconcile_issue_milestone(issue_id, desired_milestone_number)
      when is_binary(issue_id) and (is_integer(desired_milestone_number) or is_nil(desired_milestone_number)) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers(),
         {:ok, current} <- fetch_issue_details(tracker, headers, issue_number),
         current_milestone_number <- get_in(current, ["milestone", "number"]),
         true <- current_milestone_number != desired_milestone_number or :noop,
         payload <- milestone_payload(desired_milestone_number),
         {:ok, %{status: 200}} <- patch_issue(tracker, headers, issue_number, payload) do
      :ok
    else
      :noop ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub reconcile milestone failed status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reconcile_issue_assignees(String.t(), [String.t()]) :: :ok | {:error, term()}
  def reconcile_issue_assignees(issue_id, desired_assignees)
      when is_binary(issue_id) and is_list(desired_assignees) do
    normalized_desired = normalize_string_set(desired_assignees)

    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers(),
         {:ok, current} <- fetch_issue_details(tracker, headers, issue_number),
         normalized_current <- normalize_string_set(current["assignees"] || [], & &1["login"]),
         true <- normalized_current != normalized_desired or :noop,
         {:ok, %{status: 200}} <- patch_issue(tracker, headers, issue_number, %{"assignees" => normalized_desired}) do
      :ok
    else
      :noop ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub reconcile assignees failed status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reconcile_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def reconcile_issue_labels(issue_id, desired_labels) when is_binary(issue_id) and is_list(desired_labels) do
    normalized_desired = normalize_string_set(desired_labels)

    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers(),
         {:ok, current} <- fetch_issue_details(tracker, headers, issue_number),
         normalized_current <- normalize_string_set(current["labels"] || [], & &1["name"]),
         true <- normalized_current != normalized_desired or :noop,
         {:ok, %{status: 200}} <- set_issue_labels(tracker, headers, issue_number, normalized_desired) do
      :ok
    else
      :noop ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub reconcile labels failed status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reconcile_issue_blocked_by(String.t(), [String.t()]) :: :ok | {:error, term()}
  def reconcile_issue_blocked_by(issue_id, desired_blocked_by_ids)
      when is_binary(issue_id) and is_list(desired_blocked_by_ids) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers(),
         {:ok, current_numbers} <- fetch_blocked_by_numbers(tracker, headers, issue_number),
         {:ok, desired_numbers} <- parse_issue_numbers(desired_blocked_by_ids),
         adds <- desired_numbers -- current_numbers,
         removes <- current_numbers -- desired_numbers,
         :ok <- apply_blocked_by_deltas(tracker, headers, issue_number, adds, removes) do
      :ok
    end
  end

  @spec update_project_item_field_value(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_project_item_field_value(project_id, item_id, field_id, value)
      when is_binary(project_id) and is_binary(item_id) and is_binary(field_id) and is_map(value) do
    with :ok <- ensure_present(project_id, :project_id),
         :ok <- ensure_present(item_id, :item_id),
         :ok <- ensure_present(field_id, :field_id),
         :ok <- validate_project_field_value(value),
         {:ok, _body} <-
           graphql_mutation(@mutation_update_project_field, %{
             projectId: project_id,
             itemId: item_id,
             fieldId: field_id,
             value: value
           }) do
      :ok
    end
  end

  @spec clear_project_item_field_value(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear_project_item_field_value(project_id, item_id, field_id)
      when is_binary(project_id) and is_binary(item_id) and is_binary(field_id) do
    with :ok <- ensure_present(project_id, :project_id),
         :ok <- ensure_present(item_id, :item_id),
         :ok <- ensure_present(field_id, :field_id),
         {:ok, _body} <-
           graphql_mutation(@mutation_clear_project_field, %{
             projectId: project_id,
             itemId: item_id,
             fieldId: field_id
           }) do
      :ok
    end
  end

  @spec add_sub_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def add_sub_issue(issue_id, sub_issue_id) when is_binary(issue_id) and is_binary(sub_issue_id) do
    with :ok <- ensure_present(issue_id, :issue_id),
         :ok <- ensure_present(sub_issue_id, :sub_issue_id),
         {:ok, _body} <- graphql_mutation(@mutation_add_sub_issue, %{issueId: issue_id, subIssueId: sub_issue_id}) do
      :ok
    end
  end

  @spec remove_sub_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_sub_issue(issue_id, sub_issue_id) when is_binary(issue_id) and is_binary(sub_issue_id) do
    with :ok <- ensure_present(issue_id, :issue_id),
         :ok <- ensure_present(sub_issue_id, :sub_issue_id),
         {:ok, _body} <- graphql_mutation(@mutation_remove_sub_issue, %{issueId: issue_id, subIssueId: sub_issue_id}) do
      :ok
    end
  end

  @spec reprioritize_sub_issue(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def reprioritize_sub_issue(issue_id, sub_issue_id, after_id \\ nil)
      when is_binary(issue_id) and is_binary(sub_issue_id) and (is_binary(after_id) or is_nil(after_id)) do
    with :ok <- ensure_present(issue_id, :issue_id),
         :ok <- ensure_present(sub_issue_id, :sub_issue_id),
         :ok <- validate_optional_id(after_id, :after_id),
         {:ok, _body} <-
           graphql_mutation(@mutation_reprioritize_sub_issue, %{
             issueId: issue_id,
             subIssueId: sub_issue_id,
             afterId: after_id
           }) do
      :ok
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

  defp ensure_project_context(tracker) do
    owner_login = tracker.project_owner_login || tracker.repo_owner
    owner_type = normalize_owner_type(tracker.project_owner_type)
    project_title = normalized_project_title(tracker.project_title)

    with {:ok, body} <-
           graphql(@owner_lookup_query, %{
             login: owner_login,
             isOrg: owner_type == "organization",
             isUser: owner_type == "user"
           }),
         {:ok, owner} <- extract_owner_node(body, owner_type),
         {:ok, project} <- find_or_create_project(owner, project_title) do
      {:ok, %{owner_login: owner_login, owner_type: owner_type, owner_id: owner["id"], project_id: project["id"]}}
    end
  end

  defp ensure_project_fields(project_id) do
    with {:ok, body} <- graphql(@project_fields_query, %{projectId: project_id}),
         fields when is_list(fields) <- get_in(body, ["data", "node", "fields", "nodes"]) do
      field_names =
        fields
        |> Enum.map(fn field -> normalize_state_name(field["name"] || "") end)
        |> MapSet.new()

      with :ok <- maybe_create_number_field(project_id, field_names, "Points"),
           :ok <- maybe_create_number_field(project_id, field_names, "Progress") do
        {:ok, :ensured}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp ensure_repository_issues_in_project(tracker, project_id) do
    with {:ok, issues} <- fetch_repository_issues(tracker.repo_owner, tracker.repo_name, tracker.active_states) do
      Enum.reduce_while(issues, {:ok, :done}, fn %Issue{} = issue, _acc ->
        case has_project_item_for_project?(issue, project_id) do
          true ->
            {:cont, {:ok, :done}}

          false ->
            case graphql_mutation(@add_project_item_query, %{projectId: project_id, contentId: issue.id}) do
              {:ok, _} -> {:cont, {:ok, :done}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)
    end
  end

  defp fetch_repository_issues(owner, repo, active_states) do
    fetch_repository_issues_page(owner, repo, active_states, nil, [])
  end

  defp fetch_project_issues(project_id, repo_owner, repo_name) do
    fetch_project_issues_page(project_id, repo_owner, repo_name, nil, [])
  end

  defp fetch_project_issues_page(project_id, repo_owner, repo_name, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@project_items_query, %{
             projectId: project_id,
             first: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_project_page_response(body, repo_owner, repo_name) do
      updated = Enum.reverse(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} -> fetch_project_issues_page(project_id, repo_owner, repo_name, next_cursor, updated)
        :done -> {:ok, Enum.reverse(updated)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_repository_issues_page(owner, repo, active_states, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@repo_issues_query, %{
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

    {:ok, enrich_issues_with_relationship_signals(issues), %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_repository_page_response(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}
  defp decode_repository_page_response(_payload), do: {:error, :github_unknown_payload}

  defp decode_project_page_response(
         %{
           "data" => %{
             "node" => %{
               "items" => %{
                 "nodes" => item_nodes,
                 "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
               }
             }
           }
         },
         repo_owner,
         repo_name
       ) do
    expected_repo = String.downcase("#{repo_owner}/#{repo_name}")

    issues =
      item_nodes
      |> Enum.flat_map(fn item ->
        with %{} = content <- item["content"],
             repo when is_binary(repo) <- get_in(content, ["repository", "nameWithOwner"]),
             true <- String.downcase(repo) == expected_repo,
             %Issue{} = issue <- normalize_issue(content) do
          item_payload = %{
            "id" => item["id"],
            "is_archived" => item["isArchived"] == true,
            "project" => nil,
            "field_values" => normalize_project_field_values(get_in(item, ["fieldValues", "nodes"]))
          }

          metadata =
            issue
            |> Map.get(:tracker_metadata, %{})
            |> Map.put("project_items", [item_payload])

          [Map.put(issue, :tracker_metadata, metadata)]
        else
          _ -> []
        end
      end)

    {:ok, enrich_issues_with_relationship_signals(issues), %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_project_page_response(%{"errors" => errors}, _repo_owner, _repo_name),
    do: {:error, {:github_graphql_errors, errors}}

  defp decode_project_page_response(_payload, _repo_owner, _repo_name), do: {:error, :github_unknown_payload}

  defp decode_nodes_response(%{"data" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      %{} = issue -> normalize_issue(issue)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> enrich_issues_with_relationship_signals()
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
      "project_items" => normalize_project_items(get_in(issue, ["projectItems", "nodes"])),
      "linked_pull_requests" => normalize_linked_pr_signals(issue)
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
      blocked_by: normalize_blockers([], issue["parent"]),
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

  defp normalize_blockers(blocked_by_edges, parent, blocker_states \\ %{})

  defp normalize_blockers(blocked_by_edges, %{} = parent, blocker_states) when is_list(blocked_by_edges) do
    if blocked_by_edges == [] do
      [
        %{
          id: parent["id"],
          identifier: parent["identifier"] || linked_identifier(parent["number"]),
          state: parent["state"]
        }
      ]
    else
      normalize_blockers(blocked_by_edges, nil, blocker_states)
    end
  end

  defp normalize_blockers(blocked_by_edges, _parent, blocker_states) when is_list(blocked_by_edges) do
    Enum.map(normalize_dependency_links(blocked_by_edges), fn edge ->
      blocker_id = edge["id"]

      %{
        id: blocker_id,
        identifier: edge["identifier"],
        state: Map.get(blocker_states, blocker_id) || edge["state"]
      }
    end)
  end

  defp normalize_blockers(_blocked_by_edges, %{} = parent, _blocker_states) do
    [
      %{
        id: parent["id"],
        identifier: linked_identifier(parent["number"]),
        state: parent["state"]
      }
    ]
  end

  defp normalize_blockers(_, _, _), do: []

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

  defp normalize_linked_pr_signals(issue) when is_map(issue) do
    graphql_prs =
      issue
      |> get_in(["closedByPullRequestsReferences", "nodes"])
      |> normalize_linked_prs()

    project_prs =
      issue
      |> get_in(["projectItems", "nodes"])
      |> normalize_project_item_linked_prs()

    dedupe_linked_prs(graphql_prs ++ project_prs)
  end

  defp normalize_linked_pr_signals(_), do: []

  defp normalize_linked_prs(prs) when is_list(prs) do
    Enum.map(prs, fn pr ->
      %{
        "id" => pr["id"],
        "number" => pr["number"],
        "identifier" => linked_identifier(pr["number"]),
        "title" => pr["title"],
        "state" => pr["state"],
        "url" => pr["url"],
        "merged_at" => pr["mergedAt"],
        "repository" => get_in(pr, ["repository", "nameWithOwner"])
      }
    end)
  end

  defp normalize_linked_prs(_), do: []

  defp normalize_project_item_linked_prs(items) when is_list(items) do
    items
    |> Enum.flat_map(fn item ->
      item
      |> get_in(["fieldValues", "nodes"])
      |> List.wrap()
      |> Enum.flat_map(fn value ->
        if value["__typename"] == "ProjectV2ItemFieldPullRequestValue" do
          normalize_linked_prs(get_in(value, ["pullRequests", "nodes"]))
        else
          []
        end
      end)
    end)
  end

  defp normalize_project_item_linked_prs(_), do: []

  defp dedupe_linked_prs(prs) when is_list(prs) do
    prs
    |> Enum.reduce(%{}, fn pr, acc ->
      key = pr["id"] || pr["url"] || pr["identifier"] || inspect(pr)
      Map.put_new(acc, key, pr)
    end)
    |> Map.values()
  end

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
    do: %{
      "iteration_id" => value["iterationId"],
      "title" => value["title"],
      "start_date" => value["startDate"],
      "duration" => value["duration"]
    }

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

  defp enrich_issues_with_relationship_signals(issues) when is_list(issues) do
    with {:ok, tracker} <- repo_tracker_config(),
         {:ok, headers} <- rest_headers() do
      issues
      |> Enum.map(&enrich_issue_relationship_signals(&1, tracker, headers))
      |> hydrate_blocker_states()
    else
      _ -> issues
    end
  end

  defp hydrate_blocker_states(issues) when is_list(issues) do
    blocker_ids =
      issues
      |> Enum.flat_map(&blocked_by_ids/1)
      |> Enum.uniq()

    case fetch_issue_workflow_states_by_ids(blocker_ids) do
      {:ok, blocker_states} ->
        Enum.map(issues, &apply_blocker_states(&1, blocker_states))

      {:error, _reason} ->
        issues
    end
  end

  defp hydrate_blocker_states(issues), do: issues

  defp blocked_by_ids(%Issue{} = issue) do
    issue
    |> Map.get(:tracker_metadata, %{})
    |> Map.get("dependencies", %{})
    |> Map.get("blocked_by", [])
    |> Enum.flat_map(fn
      %{"id" => id} when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp blocked_by_ids(_issue), do: []

  defp apply_blocker_states(%Issue{} = issue, blocker_states) when is_map(blocker_states) do
    metadata = Map.get(issue, :tracker_metadata, %{})
    dependencies = Map.get(metadata, "dependencies", %{})

    blocked_by = normalize_blockers(Map.get(dependencies, "blocked_by", []), metadata["parent"], blocker_states)

    %{issue | blocked_by: blocked_by}
  end

  defp apply_blocker_states(issue, _blocker_states), do: issue

  defp enrich_issue_relationship_signals(%Issue{} = issue, tracker, headers) do
    issue_number =
      issue
      |> Map.get(:tracker_metadata, %{})
      |> Map.get("number")

    case issue_number do
      n when is_integer(n) ->
        case fetch_issue_dependency_edges(tracker, headers, n) do
          {:ok, dependencies} ->
            metadata =
              issue
              |> Map.get(:tracker_metadata, %{})
              |> Map.put("dependencies", dependencies)

            blocked_by = normalize_blockers(dependencies["blocked_by"], metadata["parent"], %{})
            Map.merge(issue, %{tracker_metadata: metadata, blocked_by: blocked_by})

          {:error, _reason} ->
            issue
        end

      _ ->
        issue
    end
  end

  defp enrich_issue_relationship_signals(issue, _tracker, _headers), do: issue

  defp fetch_issue_dependency_edges(tracker, headers, issue_number) do
    blocked_by_endpoint =
      "https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/dependencies/blocked_by"

    blocking_endpoint =
      "https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/dependencies/blocking"

    with {:ok, blocked_by} <- fetch_dependency_endpoint(blocked_by_endpoint, "blocked_by", headers),
         {:ok, blocking} <- fetch_dependency_endpoint(blocking_endpoint, "blocking", headers) do
      {:ok,
       %{
         "blocked_by" => normalize_dependency_links(blocked_by),
         "blocking" => normalize_dependency_links(blocking)
       }}
    end
  end

  defp fetch_dependency_endpoint(endpoint, key, headers) do
    case Req.get(endpoint, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, extract_dependency_nodes(body, key)}

      {:ok, %{status: status}} when status in [403, 404] ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp extract_dependency_nodes(body, key) when is_map(body) do
    case Map.get(body, key) do
      nodes when is_list(nodes) ->
        nodes

      _ ->
        case Map.get(body, "nodes") do
          nodes when is_list(nodes) -> nodes
          _ -> []
        end
    end
  end

  defp normalize_dependency_links(nodes) when is_list(nodes) do
    Enum.map(nodes, fn issue ->
      %{
        "id" => issue["id"],
        "number" => issue["number"],
        "identifier" => linked_identifier(issue["number"]),
        "title" => issue["title"],
        "state" => issue["state"],
        "url" => issue["url"]
      }
    end)
  end

  defp normalize_dependency_links(_), do: []

  defp fetch_issue_workflow_states_by_ids([]), do: {:ok, %{}}

  defp fetch_issue_workflow_states_by_ids(ids) when is_list(ids) do
    with {:ok, body} <- graphql(@query_by_ids, %{ids: Enum.uniq(ids)}),
         %{"data" => %{"nodes" => nodes}} when is_list(nodes) <- body do
      states =
        nodes
        |> Enum.reduce(%{}, fn
          %{} = issue_node, acc ->
            case normalize_issue(issue_node) do
              %Issue{id: id} = issue when is_binary(id) -> Map.put(acc, id, effective_issue_state(issue))
              _ -> acc
            end

          _, acc ->
            acc
        end)

      {:ok, states}
    else
      %{"errors" => errors} when is_list(errors) -> {:error, {:github_graphql_errors, errors}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp effective_issue_state(%Issue{} = issue) do
    issue
    |> project_state_values()
    |> List.first()
    |> case do
      state when is_binary(state) and state != "" -> state
      _ -> normalize_state_name(issue.state || "")
    end
  end

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

    cond do
      project_state_values != [] ->
        Enum.any?(project_state_values, &Enum.member?(normalized_active_states, &1))

      true ->
        Enum.member?(normalized_active_states, issue_state)
    end
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
    repo_tracker_config(Config.settings!().tracker)
  end

  defp repo_tracker_config(tracker) do
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

  defp normalize_rest_issue_state(state_name, status_map) do
    normalized_state_name = normalize_state_name(state_name)

    case configured_status_mapping(status_map, normalized_state_name) do
      {:ok, state, state_reason} ->
        {state, state_reason}

      :error ->
        legacy_normalize_rest_issue_state(normalized_state_name)
    end
  end

  defp configured_status_mapping(status_map, normalized_state_name)
       when is_map(status_map) and is_binary(normalized_state_name) do
    case Map.get(status_map, normalized_state_name) do
      %{"state" => "open"} ->
        {:ok, "open", nil}

      %{"state" => "closed"} = mapping ->
        {:ok, "closed", Map.get(mapping, "state_reason")}

      _ ->
        :error
    end
  end

  defp configured_status_mapping(_status_map, _normalized_state_name), do: :error

  defp legacy_normalize_rest_issue_state(normalized_state_name) do
    case normalized_state_name do
      "done" -> {"closed", "completed"}
      "closed" -> {"closed", nil}
      "completed" -> {"closed", "completed"}
      "cancelled" -> {"closed", "not_planned"}
      "canceled" -> {"closed", "not_planned"}
      "not_planned" -> {"closed", "not_planned"}
      "open" -> {"open", nil}
      "reopen" -> {"open", nil}
      "reopened" -> {"open", nil}
      _ -> {"open", nil}
    end
  end

  defp issue_state_payload("closed", state_reason) when is_binary(state_reason) do
    %{"state" => "closed", "state_reason" => state_reason}
  end

  defp issue_state_payload(state, _state_reason), do: %{"state" => state}

  defp resolve_issue_project_item(issue) when is_map(issue) do
    project_item =
      issue
      |> Map.get(:tracker_metadata, %{})
      |> Map.get("project_items", [])
      |> List.first()

    if is_map(project_item), do: {:ok, project_item}, else: {:error, :missing_project_item}
  end

  defp resolve_issue_project_id(issue, tracker) when is_map(issue) do
    project_id =
      issue
      |> Map.get(:tracker_metadata, %{})
      |> Map.get("project_items", [])
      |> List.first()
      |> then(&get_in(&1 || %{}, ["project", "id"]))

    cond do
      is_binary(project_id) and project_id != "" ->
        {:ok, project_id}

      true ->
        with {:ok, project_ctx} <- ensure_project_context(tracker) do
          {:ok, project_ctx.project_id}
        end
    end
  end

  defp project_field_values_by_name(project_item) when is_map(project_item) do
    project_item
    |> Map.get("field_values", [])
    |> Enum.reduce(%{}, fn value, acc ->
      field_name =
        value
        |> Map.get("field", %{})
        |> Map.get("name")
        |> normalize_state_name()

      if field_name == "" do
        acc
      else
        Map.put(acc, field_name, value)
      end
    end)
  end

  defp reconcile_project_field_values(current_by_name, project_id, item_id, desired_fields)
       when is_map(current_by_name) and is_binary(project_id) and is_binary(item_id) and is_map(desired_fields) do
    desired_fields
    |> Enum.reduce_while(:ok, fn {field_name, desired_value}, :ok ->
      case reconcile_single_project_field(current_by_name, project_id, item_id, field_name, desired_value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_single_project_field(current_by_name, project_id, item_id, field_name, desired_value) do
    normalized_field_name = normalize_state_name(field_name)
    current = Map.get(current_by_name, normalized_field_name)
    field_id = get_in(current || %{}, ["field", "id"])

    cond do
      normalized_field_name == "" ->
        :ok

      not is_binary(field_id) or field_id == "" ->
        :ok

      true ->
        apply_project_field_delta(project_id, item_id, field_id, current, desired_value)
    end
  end

  defp apply_project_field_delta(project_id, item_id, field_id, current, desired_value) do
    current_value = normalized_project_field_comparable(current)
    desired_value = normalize_desired_project_field_value(desired_value)

    cond do
      is_nil(desired_value) and is_nil(current_value) ->
        :ok

      is_nil(desired_value) ->
        clear_project_item_field_value(project_id, item_id, field_id)

      desired_value == current_value ->
        :ok

      true ->
        update_project_item_field_value(project_id, item_id, field_id, desired_value)
    end
  end

  defp normalize_desired_project_field_value(nil), do: nil
  defp normalize_desired_project_field_value(value) when is_number(value), do: %{"number" => value}
  defp normalize_desired_project_field_value(value) when is_binary(value), do: %{"text" => value}

  defp normalize_desired_project_field_value(%{} = value) do
    cond do
      is_binary(value["singleSelectOptionId"]) -> %{"singleSelectOptionId" => value["singleSelectOptionId"]}
      is_binary(value["date"]) -> %{"date" => value["date"]}
      is_binary(value["iterationId"]) -> %{"iterationId" => value["iterationId"]}
      is_number(value["number"]) -> %{"number" => value["number"]}
      is_binary(value["text"]) -> %{"text" => value["text"]}
      true -> nil
    end
  end

  defp normalize_desired_project_field_value(_), do: nil

  defp normalized_project_field_comparable(nil), do: nil

  defp normalized_project_field_comparable(%{} = current) do
    type = current["type"]

    cond do
      type == "ProjectV2ItemFieldSingleSelectValue" and is_binary(current["option_id"]) ->
        %{"singleSelectOptionId" => current["option_id"]}

      type == "ProjectV2ItemFieldDateValue" and is_binary(current["date"]) ->
        %{"date" => current["date"]}

      type == "ProjectV2ItemFieldIterationValue" and is_binary(current["iteration_id"]) ->
        %{"iterationId" => current["iteration_id"]}

      type == "ProjectV2ItemFieldNumberValue" and is_number(current["number"]) ->
        %{"number" => current["number"]}

      type == "ProjectV2ItemFieldTextValue" and is_binary(current["text"]) ->
        %{"text" => current["text"]}

      true ->
        nil
    end
  end

  defp graphql_mutation(mutation, variables) when is_binary(mutation) and is_map(variables) do
    with {:ok, body} <- graphql(mutation, variables) do
      case Map.get(body, "errors") do
        nil ->
          {:ok, body}

        errors when is_list(errors) ->
          {:error, {:github_graphql_errors, errors}}
      end
    end
  end

  defp fetch_issue_details(tracker, headers, issue_number) do
    case Req.get("https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}",
           headers: headers
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp patch_issue(tracker, headers, issue_number, payload) do
    Req.patch("https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}",
      headers: headers,
      json: payload
    )
  end

  defp set_issue_labels(tracker, headers, issue_number, labels) do
    Req.put("https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/labels",
      headers: headers,
      json: %{"labels" => labels}
    )
  end

  defp milestone_payload(nil), do: %{"milestone" => nil}
  defp milestone_payload(number), do: %{"milestone" => number}

  defp normalize_string_set(items, extractor \\ & &1) do
    items
    |> Enum.map(extractor)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fetch_blocked_by_numbers(tracker, headers, issue_number) do
    endpoint =
      "https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/dependencies/blocked_by"

    case Req.get(endpoint, headers: headers) do
      {:ok, %{status: 200, body: %{"blocked_by" => blocked_by}}} when is_list(blocked_by) ->
        blocked_numbers =
          blocked_by
          |> Enum.map(& &1["number"])
          |> Enum.filter(&is_integer/1)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, blocked_numbers}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        issues = Map.get(body, "issues", [])

        blocked_numbers =
          issues
          |> Enum.map(& &1["number"])
          |> Enum.filter(&is_integer/1)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, blocked_numbers}

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub fetch blocked_by failed status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_issue_numbers(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case parse_issue_number(id) do
        {:ok, number} -> {:cont, {:ok, [number | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, numbers} ->
        numbers
        |> Enum.uniq()
        |> Enum.sort()
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_blocked_by_deltas(_tracker, _headers, _issue_number, [], []), do: :ok

  defp apply_blocked_by_deltas(tracker, headers, issue_number, adds, removes) do
    with :ok <- Enum.reduce_while(adds, :ok, &add_blocked_by(tracker, headers, issue_number, &1, &2)),
         :ok <- Enum.reduce_while(removes, :ok, &remove_blocked_by(tracker, headers, issue_number, &1, &2)) do
      :ok
    end
  end

  defp add_blocked_by(tracker, headers, issue_number, blocked_by_number, :ok) do
    endpoint =
      "https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/dependencies/blocked_by"

    case Req.post(endpoint, headers: headers, json: %{"blocked_by_issue_number" => blocked_by_number}) do
      {:ok, %{status: status}} when status in [200, 201] ->
        {:cont, :ok}

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub add blocked_by failed status=#{status} body=#{summarize_error_body(body)}")
        {:halt, {:error, {:github_api_status, status}}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp remove_blocked_by(tracker, headers, issue_number, blocked_by_number, :ok) do
    endpoint =
      "https://api.github.com/repos/#{tracker.repo_owner}/#{tracker.repo_name}/issues/#{issue_number}/dependencies/blocked_by/#{blocked_by_number}"

    case Req.delete(endpoint, headers: headers) do
      {:ok, %{status: status}} when status in [200, 204] ->
        {:cont, :ok}

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub remove blocked_by failed status=#{status} body=#{summarize_error_body(body)}")
        {:halt, {:error, {:github_api_status, status}}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp validate_project_field_value(value) when is_map(value) do
    allowed_keys = MapSet.new(["date", "iterationId", "number", "singleSelectOptionId", "text"])
    keys = value |> Map.keys() |> Enum.map(&to_string/1)

    cond do
      keys == [] ->
        {:error, :invalid_project_field_value}

      Enum.all?(keys, &MapSet.member?(allowed_keys, &1)) ->
        :ok

      true ->
        {:error, :unsupported_project_field_value}
    end
  end

  defp ensure_present(value, field_name) when is_binary(value) do
    if String.trim(value) == "", do: {:error, {:missing_required, field_name}}, else: :ok
  end

  defp validate_optional_id(nil, _field_name), do: :ok
  defp validate_optional_id(value, field_name), do: ensure_present(value, field_name)

  defp normalize_owner_type(owner_type) when is_binary(owner_type) do
    case String.downcase(String.trim(owner_type)) do
      "user" -> "user"
      _ -> "organization"
    end
  end

  defp normalize_owner_type(_), do: "organization"

  defp normalized_project_title(title) when is_binary(title) do
    trimmed = String.trim(title)
    if trimmed == "", do: "Polyphony", else: trimmed
  end

  defp normalized_project_title(_), do: "Polyphony"

  defp extract_owner_node(body, "organization") do
    case get_in(body, ["data", "organization"]) do
      %{"id" => _} = org -> {:ok, org}
      _ -> {:error, :github_owner_not_found}
    end
  end

  defp extract_owner_node(body, "user") do
    case get_in(body, ["data", "user"]) do
      %{"id" => _} = user -> {:ok, user}
      _ -> {:error, :github_owner_not_found}
    end
  end

  defp find_or_create_project(owner, project_title) do
    existing =
      owner
      |> get_in(["projectsV2", "nodes"])
      |> List.wrap()
      |> Enum.find(fn project ->
        normalize_state_name(project["title"] || "") == normalize_state_name(project_title)
      end)

    case existing do
      %{"id" => _} = project ->
        {:ok, project}

      _ ->
        with {:ok, body} <- graphql_mutation(@create_project_query, %{ownerId: owner["id"], title: project_title}),
             %{"id" => _} = project <- get_in(body, ["data", "createProjectV2", "projectV2"]) do
          {:ok, project}
        else
          _ -> {:error, :github_project_create_failed}
        end
    end
  end

  defp maybe_create_number_field(project_id, existing_names, field_name) do
    if MapSet.member?(existing_names, normalize_state_name(field_name)) do
      :ok
    else
      case graphql_mutation(@create_project_field_query, %{projectId: project_id, name: field_name, dataType: "NUMBER"}) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp has_project_item_for_project?(%Issue{} = issue, project_id) when is_binary(project_id) do
    issue
    |> Map.get(:tracker_metadata, %{})
    |> Map.get("project_items", [])
    |> Enum.any?(fn item ->
      case get_in(item, ["project", "id"]) do
        ^project_id -> true
        _ -> false
      end
    end)
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

defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.

  Backward compatible tracker behaviour plus GitHub-specific write primitives for:
  - Project v2 field writes/clears
  - parent/sub-issue mutations
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    client_module().update_issue_state(issue_id, state_name)
  end

  @spec update_project_item_field_value(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_project_item_field_value(project_id, item_id, field_id, value)
      when is_binary(project_id) and is_binary(item_id) and is_binary(field_id) and is_map(value) do
    client_module().update_project_item_field_value(project_id, item_id, field_id, value)
  end

  @spec clear_project_item_field_value(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear_project_item_field_value(project_id, item_id, field_id)
      when is_binary(project_id) and is_binary(item_id) and is_binary(field_id) do
    client_module().clear_project_item_field_value(project_id, item_id, field_id)
  end

  @spec add_sub_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def add_sub_issue(issue_id, sub_issue_id) when is_binary(issue_id) and is_binary(sub_issue_id) do
    client_module().add_sub_issue(issue_id, sub_issue_id)
  end

  @spec remove_sub_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_sub_issue(issue_id, sub_issue_id) when is_binary(issue_id) and is_binary(sub_issue_id) do
    client_module().remove_sub_issue(issue_id, sub_issue_id)
  end

  @spec reprioritize_sub_issue(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def reprioritize_sub_issue(issue_id, sub_issue_id, after_id \\ nil)
      when is_binary(issue_id) and is_binary(sub_issue_id) and (is_binary(after_id) or is_nil(after_id)) do
    client_module().reprioritize_sub_issue(issue_id, sub_issue_id, after_id)
  end

  @spec reconcile_issue_milestone(String.t(), integer() | nil) :: :ok | {:error, term()}
  def reconcile_issue_milestone(issue_id, milestone_number)
      when is_binary(issue_id) and (is_integer(milestone_number) or is_nil(milestone_number)) do
    client_module().reconcile_issue_milestone(issue_id, milestone_number)
  end

  @spec reconcile_issue_assignees(String.t(), [String.t()]) :: :ok | {:error, term()}
  def reconcile_issue_assignees(issue_id, assignees)
      when is_binary(issue_id) and is_list(assignees) do
    client_module().reconcile_issue_assignees(issue_id, assignees)
  end

  @spec reconcile_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def reconcile_issue_labels(issue_id, labels)
      when is_binary(issue_id) and is_list(labels) do
    client_module().reconcile_issue_labels(issue_id, labels)
  end

  @spec reconcile_issue_blocked_by(String.t(), [String.t()]) :: :ok | {:error, term()}
  def reconcile_issue_blocked_by(issue_id, blocked_by_issue_ids)
      when is_binary(issue_id) and is_list(blocked_by_issue_ids) do
    client_module().reconcile_issue_blocked_by(issue_id, blocked_by_issue_ids)
  end

  @spec reconcile_issue_hierarchy(map(), map()) :: :ok | {:error, term()}
  def reconcile_issue_hierarchy(issue, desired_hierarchy)
      when is_map(issue) and is_map(desired_hierarchy) do
    client_module().reconcile_issue_hierarchy(issue, desired_hierarchy)
  end

  @spec reconcile_issue_state_from_project_status(map()) :: :ok | {:error, term()}
  def reconcile_issue_state_from_project_status(issue) when is_map(issue) do
    client_module().reconcile_issue_state_from_project_status(issue)
  end

  @spec reconcile_issue_project_custom_fields(map(), map()) :: :ok | {:error, term()}
  def reconcile_issue_project_custom_fields(issue, desired_fields)
      when is_map(issue) and is_map(desired_fields) do
    client_module().reconcile_issue_project_custom_fields(issue, desired_fields)
  end

  @spec apply_orchestrator_tracker_writes(map(), map()) :: :ok | {:error, term()}
  def apply_orchestrator_tracker_writes(issue, writes) when is_map(issue) and is_map(writes) do
    with :ok <- maybe_apply_project_custom_field_reconcile(issue, writes),
         :ok <- maybe_apply_project_item_field_updates(writes),
         :ok <- maybe_apply_state_transition(issue, writes),
         :ok <- maybe_apply_comments(issue, writes) do
      :ok
    end
  end

  defp maybe_apply_project_custom_field_reconcile(issue, writes) when is_map(issue) and is_map(writes) do
    desired_fields =
      Map.get(writes, :project_custom_fields) ||
        Map.get(writes, "project_custom_fields") ||
        Map.get(writes, :project_fields) ||
        Map.get(writes, "project_fields")

    if is_map(desired_fields) and desired_fields != %{} do
      reconcile_issue_project_custom_fields(issue, desired_fields)
    else
      :ok
    end
  end

  defp maybe_apply_project_item_field_updates(writes) when is_map(writes) do
    updates = Map.get(writes, :project_field_updates) || Map.get(writes, "project_field_updates")

    updates
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn update, _acc ->
      case normalize_project_field_update(update) do
        {:ok, {:update, project_id, item_id, field_id, value}} ->
          case update_project_item_field_value(project_id, item_id, field_id, value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, {:clear, project_id, item_id, field_id}} ->
          case clear_project_item_field_value(project_id, item_id, field_id) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :skip ->
          {:cont, :ok}
      end
    end)
  end

  defp maybe_apply_state_transition(issue, writes) when is_map(issue) and is_map(writes) do
    desired_state =
      Map.get(writes, :state_transition) ||
        Map.get(writes, "state_transition") ||
        Map.get(writes, :state) ||
        Map.get(writes, "state")

    issue_id = Map.get(issue, :id) || Map.get(issue, "id")

    if is_binary(issue_id) and is_binary(desired_state) and String.trim(desired_state) != "" do
      update_issue_state(issue_id, desired_state)
    else
      :ok
    end
  end

  defp maybe_apply_comments(issue, writes) when is_map(issue) and is_map(writes) do
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")

    comments =
      [Map.get(writes, :comment), Map.get(writes, "comment")]
      |> Enum.concat(List.wrap(Map.get(writes, :comments)))
      |> Enum.concat(List.wrap(Map.get(writes, "comments")))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if is_binary(issue_id) and issue_id != "" do
      Enum.reduce_while(comments, :ok, fn comment, _acc ->
        case create_comment(issue_id, comment) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  defp normalize_project_field_update(update) when is_map(update) do
    project_id = Map.get(update, :project_id) || Map.get(update, "project_id")
    item_id = Map.get(update, :item_id) || Map.get(update, "item_id")
    field_id = Map.get(update, :field_id) || Map.get(update, "field_id")
    clear? = Map.get(update, :clear) || Map.get(update, "clear")
    value = Map.get(update, :value) || Map.get(update, "value")

    cond do
      not (is_binary(project_id) and is_binary(item_id) and is_binary(field_id)) ->
        :skip

      clear? == true ->
        {:ok, {:clear, project_id, item_id, field_id}}

      is_map(value) ->
        {:ok, {:update, project_id, item_id, field_id, value}}

      true ->
        :skip
    end
  end

  defp normalize_project_field_update(_update), do: :skip

  defp client_module, do: Application.get_env(:symphony_elixir, :github_client, Client)
end

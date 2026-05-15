defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @doc """
  Reconcile tracker-native primitives for an issue.

  GitHub adapters can implement milestone/assignees/labels/dependencies enforcement.
  Other adapters safely no-op.
  """
  @spec reconcile_issue_primitives(map()) :: :ok | {:error, term()}
  def reconcile_issue_primitives(%{id: issue_id} = issue) when is_binary(issue_id) do
    tracker_metadata = Map.get(issue, :tracker_metadata, %{})
    milestone_number = get_in(tracker_metadata, ["milestone", "number"])
    assignees = desired_assignees(issue)
    labels = desired_labels(issue)
    blocked_by_issue_ids = desired_blocked_by_issue_ids(issue)
    tracker_adapter = adapter()

    with :ok <-
           maybe_call_reconcile(
             tracker_adapter,
             :reconcile_issue_state_from_project_status,
             [issue]
           ),
         :ok <-
           maybe_call_reconcile(
             tracker_adapter,
             :reconcile_issue_milestone,
             [issue_id, milestone_number]
           ),
         :ok <-
           maybe_call_reconcile(
             tracker_adapter,
             :reconcile_issue_assignees,
             [issue_id, assignees]
           ),
         :ok <-
           maybe_call_reconcile(
             tracker_adapter,
             :reconcile_issue_labels,
             [issue_id, labels]
           ),
         :ok <-
           maybe_call_reconcile(
             tracker_adapter,
             :reconcile_issue_blocked_by,
             [issue_id, blocked_by_issue_ids]
           ) do
      :ok
    end
  end

  def reconcile_issue_primitives(_issue), do: :ok

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      "linear" -> SymphonyElixir.Linear.Adapter
      _ -> SymphonyElixir.GitHub.Adapter
    end
  end

  defp maybe_call_reconcile(adapter_module, function_name, args)
       when is_atom(adapter_module) and is_atom(function_name) and is_list(args) do
    arity = length(args)

    if function_exported?(adapter_module, function_name, arity) do
      apply(adapter_module, function_name, args)
    else
      :ok
    end
  end

  defp desired_assignees(%{assignee_id: assignee_id}) when is_binary(assignee_id), do: [assignee_id]
  defp desired_assignees(_issue), do: []

  defp desired_labels(%{labels: labels}) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp desired_labels(_issue), do: []

  defp desired_blocked_by_issue_ids(%{blocked_by: blockers}) when is_list(blockers) do
    blockers
    |> Enum.map(fn
      %{id: id} when is_binary(id) -> id
      %{identifier: identifier} when is_binary(identifier) -> identifier
      %{"id" => id} when is_binary(id) -> id
      %{"identifier" => identifier} when is_binary(identifier) -> identifier
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp desired_blocked_by_issue_ids(_issue), do: []
end

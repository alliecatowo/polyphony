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
    desired = %{
      milestone_number: desired_milestone_number(issue),
      assignees: desired_assignees(issue),
      labels: desired_labels(issue),
      blocked_by_issue_ids: desired_blocked_by_issue_ids(issue),
      project_custom_fields: desired_project_custom_fields(issue)
    }

    tracker_adapter = adapter()

    with :ok <- maybe_reconcile_issue_primitives_in_order(tracker_adapter, issue, desired),
         :ok <- maybe_reconcile_structure_dependencies(tracker_adapter, issue_id, desired),
         :ok <- maybe_reconcile_taxonomy(tracker_adapter, issue_id, desired),
         :ok <- maybe_reconcile_project_custom_fields(tracker_adapter, issue, desired.project_custom_fields),
         :ok <- maybe_reconcile_issue_state_projection(tracker_adapter, issue) do
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

  defp maybe_reconcile_issue_primitives_in_order(adapter_module, issue, desired)
       when is_atom(adapter_module) and is_map(issue) and is_map(desired) do
    maybe_call_reconcile(adapter_module, :reconcile_issue_primitives_in_order, [issue, desired])
  end

  defp maybe_reconcile_structure_dependencies(adapter_module, issue_id, desired)
       when is_atom(adapter_module) and is_binary(issue_id) and is_map(desired) do
    maybe_call_reconcile(adapter_module, :reconcile_issue_blocked_by, [issue_id, desired.blocked_by_issue_ids])
  end

  defp maybe_reconcile_taxonomy(adapter_module, issue_id, desired)
       when is_atom(adapter_module) and is_binary(issue_id) and is_map(desired) do
    with :ok <- maybe_call_reconcile(adapter_module, :reconcile_issue_labels, [issue_id, desired.labels]),
         :ok <-
           maybe_call_reconcile(
             adapter_module,
             :reconcile_issue_milestone,
             [issue_id, desired.milestone_number]
           ),
         :ok <-
           maybe_call_reconcile(
             adapter_module,
             :reconcile_issue_assignees,
             [issue_id, desired.assignees]
           ) do
      :ok
    end
  end

  defp maybe_reconcile_issue_state_projection(adapter_module, issue)
       when is_atom(adapter_module) and is_map(issue) do
    maybe_call_reconcile(adapter_module, :reconcile_issue_state_from_project_status, [issue])
  end

  defp desired_milestone_number(%{tracker_metadata: tracker_metadata}) when is_map(tracker_metadata) do
    override =
      Map.get(tracker_metadata, "project_desired_milestone") ||
        Map.get(tracker_metadata, :project_desired_milestone)

    case override do
      milestone_number when is_integer(milestone_number) and milestone_number > 0 -> milestone_number
      milestone_number when is_binary(milestone_number) -> parse_positive_integer(milestone_number)
      %{"number" => milestone_number} -> parse_positive_integer(milestone_number)
      %{number: milestone_number} -> parse_positive_integer(milestone_number)
      _ -> fallback_milestone_number(tracker_metadata)
    end
  end

  defp desired_milestone_number(_issue), do: nil

  defp fallback_milestone_number(tracker_metadata) when is_map(tracker_metadata) do
    get_in(tracker_metadata, ["milestone", "number"]) ||
      get_in(tracker_metadata, [:milestone, :number])
  end

  defp fallback_milestone_number(_tracker_metadata), do: nil

  defp desired_assignees(%{tracker_metadata: tracker_metadata} = issue) when is_map(tracker_metadata) do
    override =
      Map.get(tracker_metadata, "project_desired_assignees") ||
        Map.get(tracker_metadata, :project_desired_assignees)

    case normalize_assignees_override(override) do
      {:ok, assignees} -> assignees
      :none -> fallback_assignees(issue)
    end
  end

  defp desired_assignees(_issue), do: []

  defp fallback_assignees(%{assignee_id: assignee_id}) when is_binary(assignee_id), do: [assignee_id]
  defp fallback_assignees(_issue), do: []

  defp normalize_assignees_override(nil), do: :none

  defp normalize_assignees_override(assignees) when is_binary(assignees) do
    trimmed = String.trim(assignees)

    if trimmed == "" do
      {:ok, []}
    else
      {:ok, [trimmed]}
    end
  end

  defp normalize_assignees_override(assignees) when is_list(assignees) do
    normalized =
      assignees
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, normalized}
  end

  defp normalize_assignees_override(_assignees), do: :none

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp desired_labels(%{labels: labels}) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
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

  defp desired_project_custom_fields(%{tracker_metadata: tracker_metadata}) when is_map(tracker_metadata) do
    tracker_metadata
    |> explicit_project_custom_fields()
    |> Map.merge(policy_project_custom_fields(tracker_metadata))
  end

  defp desired_project_custom_fields(_issue), do: %{}

  defp explicit_project_custom_fields(tracker_metadata) when is_map(tracker_metadata) do
    cond do
      is_map(Map.get(tracker_metadata, "project_custom_fields")) ->
        Map.get(tracker_metadata, "project_custom_fields")

      is_map(Map.get(tracker_metadata, :project_custom_fields)) ->
        Map.get(tracker_metadata, :project_custom_fields)

      is_map(Map.get(tracker_metadata, "project_desired_fields")) ->
        Map.get(tracker_metadata, "project_desired_fields")

      is_map(Map.get(tracker_metadata, :project_desired_fields)) ->
        Map.get(tracker_metadata, :project_desired_fields)

      true ->
        %{}
    end
  end

  defp explicit_project_custom_fields(_tracker_metadata), do: %{}

  # Conservative policy defaults: only derive values when a GitHub project item context
  # exists, and only for fields we can infer safely from existing tracker metadata.
  defp policy_project_custom_fields(tracker_metadata) when is_map(tracker_metadata) do
    if has_project_item_context?(tracker_metadata) do
      %{}
      |> maybe_put_number_field("Points", project_number_value(tracker_metadata, "Points"))
      |> maybe_put_number_field("Progress", progress_value(tracker_metadata))
      |> maybe_put_date_field("Target Date", target_date_value(tracker_metadata))
      |> maybe_put_iteration_field("Iteration", iteration_id_value(tracker_metadata))
      |> maybe_put_text_field("Notes", notes_value(tracker_metadata))
    else
      %{}
    end
  end

  defp policy_project_custom_fields(_tracker_metadata), do: %{}

  defp has_project_item_context?(tracker_metadata) do
    project_items =
      Map.get(tracker_metadata, "project_items") ||
        Map.get(tracker_metadata, :project_items)

    is_list(project_items) and project_items != []
  end

  defp project_number_value(tracker_metadata, field_name) when is_binary(field_name) do
    value =
      project_field_value(tracker_metadata, field_name) ||
        Map.get(tracker_metadata, String.downcase(field_name)) ||
        Map.get(tracker_metadata, String.to_atom(String.downcase(field_name)))

    case value do
      number when is_integer(number) or is_float(number) -> number
      %{"number" => number} when is_integer(number) or is_float(number) -> number
      %{:number => number} when is_integer(number) or is_float(number) -> number
      _ -> nil
    end
  end

  defp progress_value(tracker_metadata) do
    project_number_value(tracker_metadata, "Progress") ||
      derive_progress_from_status(tracker_metadata)
  end

  defp derive_progress_from_status(tracker_metadata) do
    state =
      Map.get(tracker_metadata, "status") ||
        Map.get(tracker_metadata, :status) ||
        get_in(tracker_metadata, ["project_status", "name"]) ||
        get_in(tracker_metadata, [:project_status, :name])

    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> MapSet.new()

    active_states =
      Config.settings!().tracker.active_states
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> MapSet.new()

    normalized_state = if is_binary(state), do: String.downcase(String.trim(state)), else: nil

    cond do
      normalized_state in [nil, ""] ->
        nil

      MapSet.member?(terminal_states, normalized_state) ->
        100

      MapSet.member?(active_states, normalized_state) ->
        0

      true ->
        nil
    end
  end

  defp target_date_value(tracker_metadata) do
    value =
      project_field_value(tracker_metadata, "Target Date") ||
        get_in(tracker_metadata, ["milestone", "due_on"]) ||
        get_in(tracker_metadata, [:milestone, :due_on])

    cond do
      is_binary(value) and String.trim(value) != "" ->
        String.slice(String.trim(value), 0, 10)

      is_map(value) and is_binary(Map.get(value, "date")) and String.trim(Map.get(value, "date")) != "" ->
        value
        |> Map.get("date")
        |> String.trim()
        |> String.slice(0, 10)

      is_map(value) and is_binary(Map.get(value, :date)) and String.trim(Map.get(value, :date)) != "" ->
        value
        |> Map.get(:date)
        |> String.trim()
        |> String.slice(0, 10)

      true ->
        nil
    end
  end

  defp iteration_id_value(tracker_metadata) do
    value = project_field_value(tracker_metadata, "Iteration")

    case value do
      %{"iteration_id" => id} when is_binary(id) and id != "" -> id
      %{"iterationId" => id} when is_binary(id) and id != "" -> id
      %{:iteration_id => id} when is_binary(id) and id != "" -> id
      %{:iterationId => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp notes_value(tracker_metadata) do
    value =
      project_field_value(tracker_metadata, "Notes") ||
        project_field_value(tracker_metadata, "Summary")

    cond do
      is_binary(value) and String.trim(value) != "" ->
        String.trim(value)

      is_map(value) and is_binary(Map.get(value, "text")) and String.trim(Map.get(value, "text")) != "" ->
        value |> Map.get("text") |> String.trim()

      is_map(value) and is_binary(Map.get(value, :text)) and String.trim(Map.get(value, :text)) != "" ->
        value |> Map.get(:text) |> String.trim()

      true ->
        nil
    end
  end

  defp project_field_value(tracker_metadata, field_name) when is_binary(field_name) do
    field_values =
      tracker_metadata
      |> Map.get("project_items", [])
      |> List.wrap()
      |> Enum.find_value(fn
        %{"field_values" => values} when is_map(values) -> values
        _ -> nil
      end)

    cond do
      not is_map(field_values) ->
        nil

      Map.has_key?(field_values, field_name) ->
        Map.get(field_values, field_name)

      true ->
        Enum.find_value(field_values, fn
          {k, value} when is_binary(k) ->
            if String.downcase(String.trim(k)) == String.downcase(field_name), do: value

          _ ->
            nil
        end)
    end
  end

  defp maybe_put_number_field(fields, _name, nil), do: fields

  defp maybe_put_number_field(fields, name, number)
       when is_map(fields) and is_binary(name) and (is_integer(number) or is_float(number)) do
    Map.put(fields, name, %{"number" => number})
  end

  defp maybe_put_date_field(fields, _name, nil), do: fields

  defp maybe_put_date_field(fields, name, date)
       when is_map(fields) and is_binary(name) and is_binary(date) do
    trimmed = String.trim(date)

    if trimmed == "" do
      fields
    else
      Map.put(fields, name, %{"date" => String.slice(trimmed, 0, 10)})
    end
  end

  defp maybe_put_iteration_field(fields, _name, nil), do: fields

  defp maybe_put_iteration_field(fields, name, iteration_id)
       when is_map(fields) and is_binary(name) and is_binary(iteration_id) do
    trimmed = String.trim(iteration_id)

    if trimmed == "" do
      fields
    else
      Map.put(fields, name, %{"iterationId" => trimmed})
    end
  end

  defp maybe_put_text_field(fields, _name, nil), do: fields

  defp maybe_put_text_field(fields, name, text)
       when is_map(fields) and is_binary(name) and is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      fields
    else
      Map.put(fields, name, %{"text" => trimmed})
    end
  end

  defp maybe_reconcile_project_custom_fields(_adapter_module, _issue, desired_fields)
       when desired_fields in [%{}, nil],
       do: :ok

  defp maybe_reconcile_project_custom_fields(adapter_module, issue, desired_fields)
       when is_atom(adapter_module) and is_map(desired_fields) do
    maybe_call_reconcile(
      adapter_module,
      :reconcile_issue_project_custom_fields,
      [issue, desired_fields]
    )
  end
end

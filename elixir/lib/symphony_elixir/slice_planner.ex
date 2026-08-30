defmodule SymphonyElixir.SlicePlanner do
  @moduledoc """
  Builds explicit, conservative issue slices for a polling cycle.

  Slices are only inferred from durable tracker structure: a `slice:<name>` label,
  or a parent/sub-issue relationship. Unrelated issues are singleton slices.
  """

  @spec plan([map()]) :: [map()]
  def plan(issues) when is_list(issues) do
    issues
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(&slice_key/1)
    |> Enum.map(fn {key, members} ->
      ordered = Enum.sort_by(members, &leader_sort_key/1)

      leader =
        Enum.find(ordered, &dispatchable_parent?/1) ||
          Enum.find(ordered, &dispatchable_member?/1) ||
          List.first(ordered)

      %{
        key: key,
        leader: decorate_leader(leader, key, ordered),
        member_ids: Enum.map(ordered, &Map.get(&1, :id)) |> Enum.filter(&is_binary/1),
        members: ordered
      }
    end)
    |> Enum.sort_by(fn %{leader: leader} -> leader_sort_key(leader) end)
  end

  def plan(_issues), do: []

  @spec decorate_leader(map(), String.t(), [map()]) :: map()
  def decorate_leader(%{} = issue, key, members) when is_binary(key) and is_list(members) do
    metadata = Map.get(issue, :tracker_metadata, %{})

    slice_members =
      Enum.map(members, fn member ->
        %{
          "identifier" => Map.get(member, :identifier),
          "title" => Map.get(member, :title),
          "state" => Map.get(member, :state),
          "priority" => Map.get(member, :priority)
        }
      end)

    Map.put(
      issue,
      :tracker_metadata,
      Map.merge(metadata, %{
        "slice_key" => key,
        "slice_member_ids" => Enum.map(members, &Map.get(&1, :id)) |> Enum.filter(&is_binary/1),
        "slice_members" => slice_members
      })
    )
  end

  def decorate_leader(issue, _key, _members), do: issue

  @spec slice_member_ids(map()) :: [String.t()]
  def slice_member_ids(%{tracker_metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "slice_member_ids", []) do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  def slice_member_ids(_issue), do: []

  defp slice_key(issue) do
    labels = Map.get(issue, :labels, []) |> List.wrap() |> Enum.map(&String.downcase(to_string(&1)))
    parent_id = get_in(tracker_metadata(issue), ["parent", "id"])
    issue_id = Map.get(issue, :id, inspect(issue))

    explicit_slice = Enum.find(labels, &String.starts_with?(&1, "slice:"))

    cond do
      is_binary(explicit_slice) and explicit_slice != "slice:" -> explicit_slice
      is_binary(parent_id) -> "parent:" <> parent_id
      parent_issue?(issue) -> "parent:" <> to_string(issue_id)
      true -> "issue:" <> to_string(issue_id)
    end
  end

  defp parent_issue?(issue) do
    case Map.get(tracker_metadata(issue), "sub_issues") do
      sub_issues when is_list(sub_issues) -> sub_issues != []
      _ -> false
    end
  end

  defp dispatchable_parent?(issue) do
    parent_issue?(issue) and
      Map.get(issue, :assigned_to_worker, true) == true and
      Map.get(issue, :state, "")
      |> to_string()
      |> String.downcase()
      |> then(&(&1 not in ["blocked", "done", "closed", "canceled", "cancelled"]))
  end

  defp dispatchable_member?(issue) do
    Map.get(issue, :assigned_to_worker, true) == true and
      Map.get(issue, :state, "")
      |> to_string()
      |> String.downcase()
      |> then(&(&1 not in ["blocked", "done", "closed", "canceled", "cancelled"]))
  end

  defp leader_sort_key(issue) do
    {priority_rank(Map.get(issue, :priority)), created_at_key(Map.get(issue, :created_at)), Map.get(issue, :identifier, "")}
  end

  defp tracker_metadata(issue) when is_map(issue) do
    Map.get(issue, :tracker_metadata) || Map.get(issue, "tracker_metadata") || %{}
  end

  defp tracker_metadata(_issue), do: %{}

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp created_at_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp created_at_key(_value), do: 9_223_372_036_854_775_807
end

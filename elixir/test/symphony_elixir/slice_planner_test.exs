defmodule SymphonyElixir.SlicePlannerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SlicePlanner

  test "groups explicit slice labels and chooses the highest-priority leader" do
    issues = [
      issue("#2", 2, ["slice:messaging"]),
      issue("#1", 1, ["slice:messaging"]),
      issue("#3", 3, [])
    ]

    [slice, singleton] = SlicePlanner.plan(issues)

    assert slice.key == "slice:messaging"
    assert slice.leader.identifier == "#1"
    assert slice.member_ids == ["1", "2"]
    assert singleton.key == "issue:3"
  end

  test "groups children under an explicit parent relationship" do
    parent = issue("#10", 1, [], sub_issues: [%{"id" => "10"}])
    child = issue("#11", 2, [], parent: %{"id" => "10"})

    [slice] = SlicePlanner.plan([child, parent])

    assert slice.key == "parent:10"
    assert slice.leader.identifier == "#10"
    assert Enum.sort(slice.member_ids) == ["10", "11"]
  end

  test "does not select a blocked parent over a ready child" do
    parent = issue("#20", 1, [], state: "Blocked", sub_issues: [%{"id" => "21"}])
    child = issue("#21", 2, [], state: "Todo", parent: %{"id" => "20"})

    [slice] = SlicePlanner.plan([child, parent])

    assert slice.leader.identifier == "#21"
  end

  defp issue(identifier, priority, labels, opts \\ []) do
    id = String.trim_leading(identifier, "#")
    metadata = %{}

    metadata =
      case Keyword.get(opts, :parent) do
        nil -> metadata
        parent -> Map.put(metadata, "parent", parent)
      end

    metadata =
      case Keyword.get(opts, :sub_issues) do
        nil -> metadata
        sub_issues -> Map.put(metadata, "sub_issues", sub_issues)
      end

    %{
      id: id,
      identifier: identifier,
      title: "Issue #{identifier}",
      priority: priority,
      labels: labels,
      state: Keyword.get(opts, :state, "Todo"),
      created_at: DateTime.utc_now(),
      tracker_metadata: metadata
    }
  end
end

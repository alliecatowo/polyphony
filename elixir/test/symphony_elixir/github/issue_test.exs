defmodule SymphonyElixir.GitHub.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Issue

  test "defaults describe an unblocked, worker-assigned issue" do
    issue = %Issue{}

    assert issue.blocked_by == []
    assert issue.labels == []
    assert issue.assigned_to_worker == true
    assert issue.tracker_metadata == %{}
  end

  test "label_names/1 returns the labels as stored" do
    assert Issue.label_names(%Issue{labels: ["bug", "p1"]}) == ["bug", "p1"]
    assert Issue.label_names(%Issue{}) == []
  end
end

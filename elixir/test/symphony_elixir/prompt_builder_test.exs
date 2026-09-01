defmodule SymphonyElixir.PromptBuilderTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Issue, as: GitHubIssue
  alias SymphonyElixir.{PromptBuilder, Workflow}

  setup do
    original_workflow_path = Workflow.workflow_file_path()

    workflow_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-prompt-builder-#{System.unique_integer([:positive])}.md"
      )

    File.write!(workflow_path, "---\n---\nWork on {{ issue.identifier }}\n")
    Workflow.set_workflow_file_path(workflow_path)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm(workflow_path)
    end)

    :ok
  end

  test "includes JSON-safe persisted CI failure evidence in the worker retry prompt" do
    evidence = %{
      "classification" => "ci_failure",
      "check" => "build-and-test",
      "conclusion" => "failure",
      "details" => "expected \"green\" but got failure\\error\nnext line",
      "annotations" => [
        %{"path" => "lib/example.ex", "line" => 42, "message" => "unsafe `value`"}
      ]
    }

    issue =
      github_issue(%{
        "delivery_failure_reason" => evidence
      })

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "## Harness retry context"
    assert prompt =~ "persisted CI/delivery evidence"
    assert prompt =~ "Do not poll GitHub or perform delivery yourself."

    assert [encoded_evidence] =
             Regex.run(~r/## Harness retry context.*?```json\n(.*?)\n```/s, prompt, capture: :all_but_first)

    assert Jason.decode!(encoded_evidence) == evidence
  end

  test "omits harness retry context from a normal first attempt" do
    prompt = PromptBuilder.build_prompt(github_issue(), attempt: 1)

    assert prompt == "Work on GH-123"
    refute prompt =~ "## Harness retry context"
    refute prompt =~ "persisted CI/delivery evidence"
    refute prompt =~ "```json"
  end

  test "renders tuple-shaped retry failures without crashing" do
    issue = github_issue(%{"delivery_failure_reason" => {:orchestrator_restart, "worker interrupted"}})

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "orchestrator_restart"
    assert prompt =~ "worker interrupted"
  end

  defp github_issue(tracker_metadata \\ %{}) do
    %GitHubIssue{
      id: "issue-node-id",
      identifier: "GH-123",
      title: "Repair failing delivery",
      description: "Use the harness-provided CI evidence.",
      state: "In Progress",
      url: "https://github.com/example/repo/issues/123",
      labels: ["bug"],
      tracker_metadata: tracker_metadata
    }
  end
end

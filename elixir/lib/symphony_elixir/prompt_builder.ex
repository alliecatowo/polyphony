defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker issue data.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Issue, as: GitHubIssue
  alias SymphonyElixir.Linear.Issue, as: LinearIssue
  alias SymphonyElixir.Workflow

  @render_opts [strict_variables: true, strict_filters: true]
  @type tracker_issue :: GitHubIssue.t() | LinearIssue.t()

  @spec build_prompt(tracker_issue(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    rendered
    |> append_board_context(Keyword.get(opts, :board_context))
    |> append_slice_context(issue)
    |> append_retry_context(issue)
    |> append_worker_role(issue)
  end

  defp append_board_context(prompt, context) when is_binary(context) and context != "" do
    prompt <> "\n\n## Board context (read-only planning signal)\n" <> context
  end

  defp append_board_context(prompt, _context), do: prompt

  defp append_slice_context(prompt, issue) do
    issue_map = if is_struct(issue), do: Map.from_struct(issue), else: issue
    members = Map.get(Map.get(issue_map, :tracker_metadata, %{}), "slice_members")

    if is_list(members) and length(members) > 1 do
      summary =
        Enum.map_join(members, "\n", fn member ->
          "- #{member["identifier"]}: [#{member["state"]}] #{member["title"]}"
        end)

      prompt <> "\n\n## Explicit slice\nTreat this as one coherent slice and coordinate these related issues in one workspace/PR or stack when appropriate:\n" <> summary
    else
      prompt
    end
  end

  defp append_retry_context(prompt, issue) do
    issue_map = if is_struct(issue), do: Map.from_struct(issue), else: issue
    metadata = Map.get(issue_map, :tracker_metadata, %{})

    case Map.get(metadata, "delivery_failure_reason") do
      nil ->
        prompt

      reason ->
        encoded = Jason.encode!(reason)

        prompt <>
          "\n\n## Harness retry context\nThe previous delivery failed after the local handoff. Diagnose and fix the following persisted CI/delivery evidence, then rerun the relevant local validation. Do not poll GitHub or perform delivery yourself.\n\n```json\n#{encoded}\n```"
    end
  end

  defp append_worker_role(prompt, issue) do
    issue_map = if is_struct(issue), do: Map.from_struct(issue), else: issue
    metadata = Map.get(issue_map, :tracker_metadata, %{})
    lifecycle = Map.get(metadata, "pull_request_lifecycle", %{})
    labels = Map.get(issue_map, :labels, [])

    stack_role? =
      Map.get(lifecycle, "ready_for_review", false) == true or
        Enum.any?(labels, fn label ->
          is_binary(label) and
            String.downcase(label) in ["stack", "stacked-pr", "stack-reconcile", "stack/reconcile"]
        end)

    if stack_role? do
      prompt <>
        "\n\n## Worker role: stack reconciler\nReview the complete linked PR stack, not only this issue. Use the repository's gh-stack skill and merge atomically only after every required check is green and no human hold exists."
    else
      prompt
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end

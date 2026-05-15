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

  defp client_module, do: Application.get_env(:symphony_elixir, :github_client, Client)
end

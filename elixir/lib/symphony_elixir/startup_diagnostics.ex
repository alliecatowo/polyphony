defmodule SymphonyElixir.StartupDiagnostics do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.OAuthTokenStore

  @spec log_preflight() :: :ok
  def log_preflight do
    settings = Config.settings!()
    tracker = settings.tracker

    Logger.info("Polyphony startup preflight:")
    Logger.info("  tracker.kind=#{tracker.kind}")
    Logger.info("  repo=#{safe(tracker.repo_owner)}/#{safe(tracker.repo_name)}")
    Logger.info("  project_owner=#{safe(tracker.project_owner_type)}:#{safe(tracker.project_owner_login)}")
    Logger.info("  project_number=#{safe(tracker.project_slug)}")
    Logger.info("  webhook_port=#{safe(Config.server_port())}")
    Logger.info("  github_app_configured=#{bool(app_credentials_present?())}")
    Logger.info("  oauth_token_present=#{bool(oauth_token_present?())}")
    Logger.info("  projects_pat_present=#{bool(projects_pat_present?())}")
    Logger.info("  github_token_present=#{bool(github_token_present?())}")
    :ok
  rescue
    error ->
      Logger.warning("Startup preflight failed: #{Exception.message(error)}")
      :ok
  end

  defp app_credentials_present? do
    present_env?("GITHUB_APP_ID") and present_env?("GITHUB_PRIVATE_KEY")
  end

  defp oauth_token_present? do
    token =
      Application.get_env(:symphony_elixir, :github_oauth_token) ||
        System.get_env("GITHUB_OAUTH_TOKEN") ||
        OAuthTokenStore.load()

    is_binary(token) and String.trim(token) != ""
  end
  defp projects_pat_present?, do: present_env?("GITHUB_PROJECTS_PAT")
  defp github_token_present?, do: present_env?("GITHUB_TOKEN")

  defp present_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp bool(true), do: "yes"
  defp bool(false), do: "no"

  defp safe(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: "unset", else: trimmed
  end

  defp safe(nil), do: "unset"
  defp safe(value), do: to_string(value)
end

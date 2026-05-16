defmodule SymphonyElixir.GitHub.OAuthBootstrap do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Config

  @spec maybe_open_browser() :: :ok
  def maybe_open_browser do
    if should_prompt_oauth?() do
      url = oauth_start_url()

      case open_url(url) do
        :ok ->
          Logger.info("Opened GitHub OAuth browser flow url=#{url}")

        {:error, reason} ->
          Logger.warning("Failed to auto-open browser for GitHub OAuth: #{inspect(reason)} url=#{url}")
      end
    end

    :ok
  end

  defp should_prompt_oauth? do
    tracker = Config.settings!().tracker

    tracker.kind == "github" and
      String.downcase(to_string(tracker.project_owner_type)) == "user" and
      missing_oauth_token?() and
      oauth_bootstrap_enabled?()
  end

  defp missing_oauth_token? do
    token =
      Application.get_env(:symphony_elixir, :github_oauth_token) ||
        System.get_env("GITHUB_OAUTH_TOKEN")

    not (is_binary(token) and String.trim(token) != "")
  end

  defp oauth_bootstrap_enabled? do
    case System.get_env("GITHUB_OAUTH_AUTO_OPEN") do
      nil -> true
      value -> String.downcase(String.trim(value)) not in ["0", "false", "no", "off"]
    end
  end

  defp oauth_start_url do
    case System.get_env("GITHUB_OAUTH_START_URL") do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        host = Config.settings!().server.host || "127.0.0.1"
        port = Config.server_port() || 4000
        "http://#{host}:#{port}/auth/github/start"
    end
  end

  defp open_url(url) do
    cond do
      executable?("xdg-open") ->
        run_open("xdg-open", [url])

      executable?("open") ->
        run_open("open", [url])

      true ->
        {:error, :no_browser_open_command}
    end
  end

  defp run_open(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp executable?(cmd), do: not is_nil(System.find_executable(cmd))
end

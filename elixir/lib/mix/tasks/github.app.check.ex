defmodule Mix.Tasks.Github.App.Check do
  use Mix.Task

  @shortdoc "Verify GitHub App auth and installation for configured repo"

  @moduledoc """
  Validates GitHub App credentials and installation access for the configured repository.

  Checks:
    1. App JWT is valid (`GET /app`)
    2. App has at least one installation (`GET /app/installations`)
    3. App is installed on configured repo (`GET /repos/{owner}/{repo}/installation`)

  Usage:
      mix github.app.check
  """

  @impl Mix.Task
  def run(_args) do
    tracker = SymphonyElixir.Config.settings!().tracker

    with {:ok, owner, repo} <- repo_tuple(tracker),
         {:ok, app_id, private_key} <- app_credentials(),
         {:ok, jwt} <- mint_app_jwt(app_id, private_key),
         headers <- github_headers(jwt),
         {:ok, app_info} <- fetch_app_info(headers),
         :ok <- ensure_has_installations(headers, app_info),
         :ok <- ensure_repo_installation(headers, owner, repo, app_info) do
      Mix.shell().info("GitHub App preflight OK for #{owner}/#{repo}")
    else
      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp repo_tuple(%{repo_owner: owner, repo_name: repo})
       when is_binary(owner) and owner != "" and is_binary(repo) and repo != "" do
    {:ok, owner, repo}
  end

  defp repo_tuple(_), do: {:error, "Missing tracker.repo_owner or tracker.repo_name in WORKFLOW.md"}

  defp app_credentials do
    app_id = System.get_env("GITHUB_APP_ID")
    private_key = System.get_env("GITHUB_PRIVATE_KEY")

    if is_binary(app_id) and app_id != "" and is_binary(private_key) and private_key != "" do
      {:ok, app_id, private_key}
    else
      {:error, "Missing GITHUB_APP_ID or GITHUB_PRIVATE_KEY in environment"}
    end
  end

  defp mint_app_jwt(app_id, private_key_pem) do
    now = System.system_time(:second)
    claims = %{"iat" => now - 60, "exp" => now + 540, "iss" => app_id}

    with entries when is_list(entries) <- :public_key.pem_decode(private_key_pem),
         [entry | _] <- entries,
         key <- :public_key.pem_entry_decode(entry),
         {:ok, payload} <- Jason.encode(claims) do
      header = %{"alg" => "RS256", "typ" => "JWT"}
      signing_input = base64url_json(header) <> "." <> base64url(payload)
      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> base64url(signature)}
    else
      _ -> {:error, "Invalid GITHUB_PRIVATE_KEY PEM format"}
    end
  end

  defp fetch_app_info(headers) do
    case Req.get("https://api.github.com/app", headers: headers) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "GitHub App auth failed (GET /app status=#{status}) #{error_message(body)}"}
      {:error, reason} -> {:error, "GitHub App auth request failed: #{inspect(reason)}"}
    end
  end

  defp ensure_has_installations(headers, app_info) do
    case Req.get("https://api.github.com/app/installations", headers: headers) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        if body == [] do
          slug = app_info["slug"] || "your-app"
          {:error, "App has no installations. Install it first: https://github.com/apps/#{slug}/installations/new"}
        else
          :ok
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to list app installations (status=#{status}) #{error_message(body)}"}

      {:error, reason} ->
        {:error, "Failed to list app installations: #{inspect(reason)}"}
    end
  end

  defp ensure_repo_installation(headers, owner, repo, app_info) do
    url = "https://api.github.com/repos/#{owner}/#{repo}/installation"

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        slug = app_info["slug"] || "your-app"

        {:error,
         "App is not installed on #{owner}/#{repo}. Install and grant access to this repository: " <>
           "https://github.com/apps/#{slug}/installations/new"}

      {:ok, %{status: status, body: body}} ->
        {:error, "Repo installation lookup failed for #{owner}/#{repo} (status=#{status}) #{error_message(body)}"}

      {:error, reason} ->
        {:error, "Repo installation lookup failed for #{owner}/#{repo}: #{inspect(reason)}"}
    end
  end

  defp github_headers(jwt) do
    [
      {"Authorization", "Bearer #{jwt}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  defp error_message(body) when is_map(body) do
    case body["message"] do
      message when is_binary(message) -> "message=#{message}"
      _ -> ""
    end
  end

  defp error_message(_), do: ""

  defp base64url_json(map) when is_map(map) do
    map |> Jason.encode!() |> base64url()
  end

  defp base64url(data) when is_binary(data), do: Base.url_encode64(data, padding: false)
end

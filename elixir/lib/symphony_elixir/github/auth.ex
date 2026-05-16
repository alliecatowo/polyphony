defmodule SymphonyElixir.GitHub.Auth do
  @moduledoc false

  @cache_table :symphony_github_app_auth_cache
  @token_expiry_buffer_seconds 60
  @jwt_backdate_seconds 60
  @jwt_ttl_seconds 540

  @spec authorization_token(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_token(tracker, opts \\ []) when is_map(tracker) do
    case tracker_api_key(tracker) do
      {:ok, token} ->
        {:ok, token}

      :missing ->
        with {:ok, app_id, private_key} <- app_credentials(),
             {:ok, owner, repo} <- tracker_repo(tracker),
             now <- now_seconds(opts) do
          cache_key = {app_id, owner, repo}

          case cached_token(cache_key, now) do
            {:hit, token} ->
              {:ok, token}

            _ ->
              with {:ok, token, expires_at} <- fetch_installation_token(app_id, private_key, owner, repo, opts) do
                put_cached_token(cache_key, token, expires_at)
                {:ok, token}
              end
          end
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :missing_github_api_token}
        end
    end
  end

  @spec project_authorization_token(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def project_authorization_token(tracker, opts \\ []) when is_map(tracker) do
    case oauth_token() do
      {:ok, token} ->
        {:ok, token}

      :missing ->
        if String.downcase(to_string(Map.get(tracker, :project_owner_type, ""))) == "user" do
          {:error, :missing_github_oauth_token}
        else
          authorization_token(tracker, opts)
        end
    end
  end

  @spec github_auth_available?(map()) :: boolean()
  def github_auth_available?(tracker) when is_map(tracker) do
    match?({:ok, _token}, tracker_api_key(tracker)) or match?({:ok, _, _}, app_credentials())
  end

  def github_auth_available?(_tracker), do: false

  @spec clear_cache() :: true
  def clear_cache do
    if cache_table_exists?(), do: :ets.delete_all_objects(@cache_table)
    true
  end

  defp fetch_installation_token(app_id, private_key_pem, owner, repo, opts) do
    with {:ok, app_jwt} <- mint_app_jwt(app_id, private_key_pem, opts),
         {:ok, installation_id} <- discover_installation_id(app_jwt, owner, repo, opts),
         {:ok, token, expires_at} <- create_installation_token(app_jwt, installation_id, opts) do
      {:ok, token, expires_at}
    end
  end

  defp discover_installation_id(app_jwt, owner, repo, opts) do
    headers = github_headers(app_jwt)

    with {:error, {:github_api_status, 404}} <- discover_repo_installation_id(owner, repo, headers, opts),
         {:error, user_reason} <- discover_owner_installation_id(owner, "users", headers, opts),
         {:error, org_reason} <- discover_owner_installation_id(owner, "orgs", headers, opts) do
      reason = first_non_not_found_reason(user_reason, org_reason)

      case reason do
        :not_found -> {:error, :github_app_installation_not_found}
        other -> {:error, other}
      end
    end
  end

  defp discover_repo_installation_id(owner, repo, headers, opts) do
    discover_installation_id_from_url(
      "https://api.github.com/repos/#{owner}/#{repo}/installation",
      headers,
      opts
    )
  end

  defp discover_owner_installation_id(owner, owner_kind, headers, opts)
       when owner_kind in ["users", "orgs"] do
    discover_installation_id_from_url(
      "https://api.github.com/#{owner_kind}/#{owner}/installation",
      headers,
      opts
    )
  end

  defp discover_installation_id_from_url(url, headers, opts) do
    case request(:get, url, nil, headers, opts) do
      {:ok, %{status: 200, body: %{"id" => id}}} when is_integer(id) ->
        {:ok, id}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  defp first_non_not_found_reason({:github_api_status, 404}, {:github_api_status, 404}), do: :not_found
  defp first_non_not_found_reason(reason, {:github_api_status, 404}), do: reason
  defp first_non_not_found_reason({:github_api_status, 404}, reason), do: reason
  defp first_non_not_found_reason(reason, _other), do: reason

  defp github_headers(app_jwt) do
    [
      {"Authorization", "Bearer #{app_jwt}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  defp create_installation_token(app_jwt, installation_id, opts) do
    headers = github_headers(app_jwt)

    case request(:post, "https://api.github.com/app/installations/#{installation_id}/access_tokens", %{}, headers, opts) do
      {:ok, %{status: status, body: %{"token" => token, "expires_at" => expires_at}}}
      when status in [200, 201] and is_binary(token) and is_binary(expires_at) ->
        {:ok, token, parse_expiry(expires_at)}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  defp mint_app_jwt(app_id, private_key_pem, opts) do
    now = now_seconds(opts)

    claims = %{"iat" => now - @jwt_backdate_seconds, "exp" => now + @jwt_ttl_seconds, "iss" => app_id}

    with {:ok, key} <- decode_private_key(private_key_pem),
         {:ok, payload} <- Jason.encode(claims) do
      header = %{"alg" => "RS256", "typ" => "JWT"}
      signing_input = base64url_json(header) <> "." <> base64url(payload)
      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> base64url(signature)}
    else
      _ -> {:error, :invalid_github_app_private_key}
    end
  end

  defp decode_private_key(pem) do
    with entries when is_list(entries) <- :public_key.pem_decode(pem),
         [entry | _] <- entries,
         key <- :public_key.pem_entry_decode(entry) do
      {:ok, key}
    else
      _ -> {:error, :invalid_github_app_private_key}
    end
  end

  defp base64url_json(map) when is_map(map) do
    map |> Jason.encode!() |> base64url()
  end

  defp base64url(data) when is_binary(data) do
    Base.url_encode64(data, padding: false)
  end

  defp tracker_api_key(%{api_key: token}) when is_binary(token) do
    if String.trim(token) == "", do: :missing, else: {:ok, token}
  end

  defp tracker_api_key(_), do: :missing

  defp app_credentials do
    app_id = Application.get_env(:symphony_elixir, :github_app_id) || System.get_env("GITHUB_APP_ID")

    private_key =
      Application.get_env(:symphony_elixir, :github_private_key) || System.get_env("GITHUB_PRIVATE_KEY")

    if is_binary(app_id) and app_id != "" and is_binary(private_key) and private_key != "" do
      {:ok, app_id, private_key}
    else
      {:error, :missing_github_api_token}
    end
  end

  defp tracker_repo(%{repo_owner: owner, repo_name: repo})
       when is_binary(owner) and owner != "" and is_binary(repo) and repo != "" do
    {:ok, owner, repo}
  end

  defp tracker_repo(_), do: {:error, :missing_github_repo}

  defp oauth_token do
    token =
      Application.get_env(:symphony_elixir, :github_oauth_token) ||
        System.get_env("GITHUB_OAUTH_TOKEN")

    if is_binary(token) and String.trim(token) != "", do: {:ok, token}, else: :missing
  end

  defp request(method, url, body, headers, opts) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)
    request_fun.(method, url, body, headers)
  end

  defp default_request(:get, url, _body, headers), do: Req.get(url, headers: headers)

  defp default_request(:post, url, body, headers),
    do: Req.post(url, headers: headers, json: body, connect_options: [timeout: 30_000])

  defp cached_token(cache_key, now) do
    if cache_table_exists?() do
      case :ets.lookup(@cache_table, cache_key) do
        [{^cache_key, token, expires_at}] when is_binary(token) and is_integer(expires_at) ->
          if expires_at - @token_expiry_buffer_seconds > now, do: {:hit, token}, else: :stale

        _ ->
          :stale
      end
    else
      :stale
    end
  end

  defp put_cached_token(cache_key, token, expires_at) when is_binary(token) and is_integer(expires_at) do
    ensure_cache_table!()
    true = :ets.insert(@cache_table, {cache_key, token, expires_at})
    :ok
  end

  defp ensure_cache_table! do
    case :ets.whereis(@cache_table) do
      :undefined ->
        _ = :ets.new(@cache_table, [:set, :named_table, :public, read_concurrency: true, write_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  defp cache_table_exists?, do: :ets.whereis(@cache_table) != :undefined

  defp parse_expiry(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp now_seconds(opts) do
    case Keyword.get(opts, :now_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.system_time(:second)
    end
  end
end

defmodule SymphonyElixirWeb.GitHubAuthController do
  use Phoenix.Controller, formats: [:json]

  @state_table :symphony_github_oauth_state
  @state_ttl_seconds 600

  def start(conn, _params) do
    with {:ok, client_id} <- env("GITHUB_CLIENT_ID"),
         {:ok, callback_url} <- callback_url(conn),
         state <- random_state(),
         :ok <- put_state(state) do
      authorize_url =
        URI.to_string(%URI{
          scheme: "https",
          host: "github.com",
          path: "/login/oauth/authorize",
          query: URI.encode_query(%{
            "client_id" => client_id,
            "redirect_uri" => callback_url,
            "state" => state
          })
        })

      redirect(conn, external: authorize_url)
    else
      {:error, reason} ->
        conn |> put_status(500) |> json(%{"error" => reason})
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with :ok <- pop_state(state),
         {:ok, client_id} <- env("GITHUB_CLIENT_ID"),
         {:ok, client_secret} <- env("GITHUB_CLIENT_SECRET"),
         {:ok, callback_url} <- callback_url(conn),
         {:ok, token} <- exchange_code(client_id, client_secret, code, callback_url),
         {:ok, login} <- fetch_user_login(token) do
      Application.put_env(:symphony_elixir, :github_oauth_token, token)

      json(conn, %{
        "ok" => true,
        "message" => "GitHub OAuth token stored for project operations",
        "login" => login
      })
    else
      {:error, reason} ->
        conn |> put_status(400) |> json(%{"error" => reason})
    end
  end

  def callback(conn, _params) do
    conn |> put_status(400) |> json(%{"error" => "Missing code/state"})
  end

  defp exchange_code(client_id, client_secret, code, callback_url) do
    body = %{
      "client_id" => client_id,
      "client_secret" => client_secret,
      "code" => code,
      "redirect_uri" => callback_url
    }

    headers = [{"Accept", "application/json"}]

    case Req.post("https://github.com/login/oauth/access_token", headers: headers, form: body) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: 200, body: body}} ->
        {:error, "OAuth exchange did not return access_token: #{inspect(body)}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "OAuth exchange failed status=#{status} body=#{inspect(body)}"}

      {:error, reason} ->
        {:error, "OAuth exchange request failed: #{inspect(reason)}"}
    end
  end

  defp fetch_user_login(token) do
    headers = [{"Authorization", "Bearer #{token}"}, {"Accept", "application/vnd.github+json"}]

    case Req.get("https://api.github.com/user", headers: headers) do
      {:ok, %{status: 200, body: %{"login" => login}}} when is_binary(login) -> {:ok, login}
      {:ok, %{status: status, body: body}} -> {:error, "OAuth token user lookup failed status=#{status} body=#{inspect(body)}"}
      {:error, reason} -> {:error, "OAuth token user lookup failed: #{inspect(reason)}"}
    end
  end

  defp callback_url(conn) do
    case System.get_env("GITHUB_OAUTH_CALLBACK_URL") do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        {:ok,
         URI.to_string(%URI{
           scheme: to_string(conn.scheme),
           host: conn.host,
           port: conn.port,
           path: "/auth/github/callback"
         })}
    end
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing #{name} in environment"}
    end
  end

  defp random_state do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp put_state(state) do
    ensure_state_table!()
    now = System.system_time(:second)
    true = :ets.insert(@state_table, {state, now + @state_ttl_seconds})
    :ok
  end

  defp pop_state(state) when is_binary(state) and state != "" do
    ensure_state_table!()
    now = System.system_time(:second)

    case :ets.take(@state_table, state) do
      [{^state, expires_at}] when is_integer(expires_at) and expires_at > now -> :ok
      _ -> {:error, "Invalid or expired OAuth state"}
    end
  end

  defp pop_state(_), do: {:error, "Invalid OAuth state"}

  defp ensure_state_table! do
    case :ets.whereis(@state_table) do
      :undefined ->
        :ets.new(@state_table, [:set, :named_table, :public, read_concurrency: true, write_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end

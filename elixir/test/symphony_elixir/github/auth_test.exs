defmodule SymphonyElixir.GitHub.AuthTest do
  # Mutates application env and a global ETS cache, so it cannot run async.
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Auth

  @env_keys [:github_app_id, :github_private_key, :github_oauth_token]

  setup do
    previous = for key <- @env_keys, do: {key, Application.get_env(:symphony_elixir, key)}
    for key <- @env_keys, do: Application.delete_env(:symphony_elixir, key)

    env_vars = ~w(GITHUB_APP_ID GITHUB_PRIVATE_KEY GITHUB_OAUTH_TOKEN)
    saved_vars = for name <- env_vars, do: {name, System.get_env(name)}
    for name <- env_vars, do: System.delete_env(name)

    Auth.clear_cache()

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:symphony_elixir, key),
          else: Application.put_env(:symphony_elixir, key, value)
      end

      for {name, value} <- saved_vars do
        if value == nil, do: System.delete_env(name), else: System.put_env(name, value)
      end

      Auth.clear_cache()
    end)

    :ok
  end

  defp private_key_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([entry])
  end

  defp configure_app! do
    Application.put_env(:symphony_elixir, :github_app_id, "12345")
    Application.put_env(:symphony_elixir, :github_private_key, private_key_pem())
  end

  defp tracker(overrides \\ %{}) do
    Map.merge(%{repo_owner: "octo", repo_name: "hello", api_key: nil, project_owner_type: "organization"}, overrides)
  end

  describe "authorization_token/2" do
    test "prefers the tracker api key" do
      assert {:ok, "pat-123"} = Auth.authorization_token(tracker(%{api_key: "pat-123"}))
    end

    test "ignores a blank api key and reports missing app credentials" do
      assert {:error, :missing_github_api_token} = Auth.authorization_token(tracker(%{api_key: "   "}))
    end

    test "requires a repo when falling back to the app" do
      configure_app!()
      assert {:error, :missing_github_repo} = Auth.authorization_token(%{api_key: nil})
    end

    test "rejects an unparseable private key" do
      Application.put_env(:symphony_elixir, :github_app_id, "12345")
      Application.put_env(:symphony_elixir, :github_private_key, "not a pem")

      assert {:error, :invalid_github_app_private_key} =
               Auth.authorization_token(tracker(), request_fun: fn _, _, _, _ -> flunk("no request expected") end)
    end

    test "mints an installation token via the repo installation and caches it" do
      configure_app!()
      test_pid = self()

      request_fun = fn method, url, _body, headers ->
        send(test_pid, {:request, method, url, headers})

        case {method, url} do
          {:get, "https://api.github.com/repos/octo/hello/installation"} ->
            {:ok, %{status: 200, body: %{"id" => 77}}}

          {:post, "https://api.github.com/app/installations/77/access_tokens"} ->
            {:ok, %{status: 201, body: %{"token" => "ghs_installation", "expires_at" => "2026-10-03T12:00:00Z"}}}
        end
      end

      now = DateTime.to_unix(~U[2026-10-03 10:00:00Z])
      opts = [request_fun: request_fun, now_fun: fn -> now end]

      assert {:ok, "ghs_installation"} = Auth.authorization_token(tracker(), opts)

      assert_received {:request, :get, _, [{"Authorization", "Bearer " <> jwt} | _]}
      assert [_header, claims, _signature] = String.split(jwt, ".")
      assert %{"iss" => "12345", "iat" => iat, "exp" => exp} = claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert iat == now - 60 and exp == now + 540

      assert_received {:request, :post, _, _}

      # Second call is served from the cache: no further requests.
      assert {:ok, "ghs_installation"} = Auth.authorization_token(tracker(), opts)
      refute_received {:request, _, _, _}

      # Once within the expiry buffer the token is refreshed.
      later = DateTime.to_unix(~U[2026-10-03 11:59:30Z])
      assert {:ok, "ghs_installation"} = Auth.authorization_token(tracker(), request_fun: request_fun, now_fun: fn -> later end)
      assert_received {:request, :get, _, _}
    end

    test "falls back to the owner installation when the repo one is 404" do
      configure_app!()

      request_fun = fn method, url, _body, _headers ->
        case {method, url} do
          {:get, "https://api.github.com/repos/octo/hello/installation"} -> {:ok, %{status: 404, body: %{}}}
          {:get, "https://api.github.com/users/octo/installation"} -> {:ok, %{status: 404, body: %{}}}
          {:get, "https://api.github.com/orgs/octo/installation"} -> {:ok, %{status: 200, body: %{"id" => 9}}}
          {:post, "https://api.github.com/app/installations/9/access_tokens"} -> {:ok, %{status: 200, body: %{"token" => "t", "expires_at" => "2999-01-01T00:00:00Z"}}}
        end
      end

      assert {:ok, "t"} = Auth.authorization_token(tracker(), request_fun: request_fun)
    end

    test "reports a missing installation when every lookup is 404" do
      configure_app!()
      request_fun = fn _method, _url, _body, _headers -> {:ok, %{status: 404, body: %{}}} end

      assert {:error, :github_app_installation_not_found} = Auth.authorization_token(tracker(), request_fun: request_fun)
    end

    test "surfaces transport errors and non-404 statuses" do
      configure_app!()

      assert {:error, {:github_api_request, :econnrefused}} =
               Auth.authorization_token(tracker(), request_fun: fn _, _, _, _ -> {:error, :econnrefused} end)

      Auth.clear_cache()

      assert {:error, {:github_api_status, 500}} =
               Auth.authorization_token(tracker(), request_fun: fn _, _, _, _ -> {:ok, %{status: 500, body: %{}}} end)
    end

    test "reports an unexpected token payload" do
      configure_app!()

      request_fun = fn
        :get, _url, _body, _headers -> {:ok, %{status: 200, body: %{"id" => 1}}}
        :post, _url, _body, _headers -> {:ok, %{status: 201, body: %{"nope" => true}}}
      end

      assert {:error, {:github_api_status, 201}} = Auth.authorization_token(tracker(), request_fun: request_fun)
    end
  end

  describe "project_authorization_token/2" do
    test "uses the OAuth token when configured" do
      Application.put_env(:symphony_elixir, :github_oauth_token, "gho_abc")
      assert {:ok, "gho_abc"} = Auth.project_authorization_token(tracker(%{project_owner_type: "user"}))
    end

    test "user-owned projects require an OAuth token" do
      assert {:error, :missing_github_oauth_token} =
               Auth.project_authorization_token(tracker(%{project_owner_type: "User", api_key: "pat"}))
    end

    test "organization projects fall back to the regular token" do
      assert {:ok, "pat"} = Auth.project_authorization_token(tracker(%{api_key: "pat"}))
    end
  end

  describe "github_auth_available?/1" do
    test "is true with an api key or app credentials, false otherwise" do
      refute Auth.github_auth_available?(tracker())
      assert Auth.github_auth_available?(tracker(%{api_key: "pat"}))

      configure_app!()
      assert Auth.github_auth_available?(tracker())

      refute Auth.github_auth_available?(:not_a_map)
    end
  end

  test "clear_cache/0 is safe before the cache table exists" do
    assert Auth.clear_cache()
  end
end

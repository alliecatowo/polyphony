defmodule SymphonyElixir.GitHub.OAuthTest do
  # Reads/writes process env and application env, so it cannot run async.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.GitHub.OAuthBootstrap
  alias SymphonyElixirWeb.GitHubAuthController

  @env_vars ~w(GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET GITHUB_OAUTH_CALLBACK_URL GITHUB_OAUTH_SCOPES GITHUB_OAUTH_TOKEN GITHUB_OAUTH_AUTO_OPEN GITHUB_OAUTH_START_URL)

  setup do
    saved = for name <- @env_vars, do: {name, System.get_env(name)}
    for name <- @env_vars, do: System.delete_env(name)
    previous_token = Application.get_env(:symphony_elixir, :github_oauth_token)
    Application.delete_env(:symphony_elixir, :github_oauth_token)

    on_exit(fn ->
      for {name, value} <- saved do
        if value == nil, do: System.delete_env(name), else: System.put_env(name, value)
      end

      if previous_token == nil,
        do: Application.delete_env(:symphony_elixir, :github_oauth_token),
        else: Application.put_env(:symphony_elixir, :github_oauth_token, previous_token)
    end)

    :ok
  end

  defp call(action, path, params \\ %{}) do
    :get
    |> conn(path)
    |> Phoenix.Controller.put_format("json")
    |> then(&apply(GitHubAuthController, action, [&1, params]))
  end

  describe "start/2" do
    test "fails with a JSON error when GITHUB_CLIENT_ID is missing" do
      conn = call(:start, "/auth/github/start")
      assert conn.status == 500
      assert Jason.decode!(conn.resp_body) == %{"error" => "Missing GITHUB_CLIENT_ID in environment"}
    end

    test "redirects to GitHub with client id, callback, scopes and a fresh state" do
      System.put_env("GITHUB_CLIENT_ID", "client-abc")
      System.put_env("GITHUB_OAUTH_CALLBACK_URL", "https://example.test/auth/github/callback")
      System.put_env("GITHUB_OAUTH_SCOPES", "read:project")

      conn = call(:start, "/auth/github/start")
      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      uri = URI.parse(location)
      query = URI.decode_query(uri.query)

      assert {uri.host, uri.path} == {"github.com", "/login/oauth/authorize"}
      assert query["client_id"] == "client-abc"
      assert query["redirect_uri"] == "https://example.test/auth/github/callback"
      assert query["scope"] == "read:project"
      assert byte_size(query["state"]) >= 24

      other = call(:start, "/auth/github/start")
      [other_location] = get_resp_header(other, "location")
      refute URI.decode_query(URI.parse(other_location).query)["state"] == query["state"]
    end

    test "derives the callback url from the request and defaults the scopes" do
      System.put_env("GITHUB_CLIENT_ID", "client-abc")
      conn = call(:start, "http://127.0.0.1:4000/auth/github/start")
      [location] = get_resp_header(conn, "location")
      query = URI.decode_query(URI.parse(location).query)

      assert query["redirect_uri"] =~ ~r{^http://[^/]+/auth/github/callback$}
      assert query["scope"] == "project,read:project,repo"
    end
  end

  describe "callback/2" do
    test "rejects a request without code and state" do
      conn = call(:callback, "/auth/github/callback")
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "Missing code/state"}
    end

    test "redirects with an error for an unknown state and stores no token" do
      conn = call(:callback, "/auth/github/callback", %{"code" => "c", "state" => "never-issued"})
      assert conn.status == 302
      assert [location] = get_resp_header(conn, "location")
      assert location =~ "oauth=error"
      assert location =~ URI.encode("Invalid or expired OAuth state")
      assert Application.get_env(:symphony_elixir, :github_oauth_token) == nil
    end

    test "a state can only be used once" do
      System.put_env("GITHUB_CLIENT_ID", "client-abc")
      conn = call(:start, "/auth/github/start")
      [location] = get_resp_header(conn, "location")
      state = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

      # No client secret configured: the state is consumed, then the exchange is refused.
      first = call(:callback, "/auth/github/callback", %{"code" => "c", "state" => state})
      assert [first_location] = get_resp_header(first, "location")
      assert first_location =~ "GITHUB_CLIENT_SECRET"

      second = call(:callback, "/auth/github/callback", %{"code" => "c", "state" => state})
      assert [second_location] = get_resp_header(second, "location")
      assert second_location =~ URI.encode("Invalid or expired OAuth state")
    end
  end

  describe "status/2" do
    test "reports unauthorized when no token is configured" do
      conn = call(:status, "/auth/github/status")
      assert Jason.decode!(conn.resp_body) == %{"authorized" => false, "reason" => "missing_oauth_token"}
    end
  end

  describe "OAuthBootstrap.maybe_open_browser/0" do
    test "does nothing (and returns :ok) unless a user-owned GitHub tracker lacks a token" do
      # The default test workflow uses a non-GitHub tracker, so no browser is opened.
      assert :ok = OAuthBootstrap.maybe_open_browser()
    end
  end
end

defmodule SymphonyElixirWeb.GitHubWebhookController do
  @moduledoc """
  Minimal GitHub App webhook receiver for local/private deployments.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.Endpoint

  @refresh_events MapSet.new([
                    "issues",
                    "issue_comment",
                    "pull_request",
                    "pull_request_review",
                    "pull_request_review_comment",
                    "projects_v2",
                    "projects_v2_item"
                  ])

  def receive(conn, _params) do
    with :ok <- ensure_secret_configured(),
         :ok <- verify_signature(conn),
         {:ok, event} <- fetch_event(conn) do
      case event do
        "ping" ->
          json(conn, %{"ok" => true, "event" => "ping"})

        event_name ->
          maybe_request_refresh(event_name)
          json(conn, %{"ok" => true, "event" => event_name})
      end
    else
      {:error, :missing_webhook_secret} ->
        conn
        |> put_status(500)
        |> json(%{"error" => %{"code" => "missing_webhook_secret", "message" => "GITHUB_WEBHOOK_SECRET is not configured"}})

      {:error, :invalid_signature} ->
        conn
        |> put_status(401)
        |> json(%{"error" => %{"code" => "invalid_signature", "message" => "Invalid webhook signature"}})

      {:error, :missing_signature} ->
        conn
        |> put_status(401)
        |> json(%{"error" => %{"code" => "missing_signature", "message" => "Missing X-Hub-Signature-256 header"}})

      {:error, :missing_event} ->
        conn
        |> put_status(400)
        |> json(%{"error" => %{"code" => "missing_event", "message" => "Missing X-GitHub-Event header"}})
    end
  end

  defp maybe_request_refresh(event) do
    if MapSet.member?(@refresh_events, event) do
      orchestrator = Endpoint.config(:orchestrator) || Orchestrator
      _ = Orchestrator.request_refresh(orchestrator)
      :ok
    else
      :ok
    end
  end

  defp fetch_event(conn) do
    case get_req_header(conn, "x-github-event") do
      [event | _] when is_binary(event) and event != "" -> {:ok, event}
      _ -> {:error, :missing_event}
    end
  end

  defp ensure_secret_configured do
    if webhook_secret() == "" do
      {:error, :missing_webhook_secret}
    else
      :ok
    end
  end

  defp verify_signature(conn) do
    with [provided | _] <- get_req_header(conn, "x-hub-signature-256"),
         true <- is_binary(provided) and String.starts_with?(provided, "sha256="),
         raw_body when is_binary(raw_body) <- conn.assigns[:raw_body],
         expected <- "sha256=" <> signature(raw_body),
         true <- Plug.Crypto.secure_compare(provided, expected) do
      :ok
    else
      [] ->
        {:error, :missing_signature}

      nil ->
        {:error, :invalid_signature}

      false ->
        {:error, :invalid_signature}

      _ ->
        {:error, :invalid_signature}
    end
  end

  defp signature(raw_body) do
    :hmac
    |> :crypto.mac(:sha256, webhook_secret(), raw_body)
    |> Base.encode16(case: :lower)
  end

  defp webhook_secret do
    System.get_env("GITHUB_WEBHOOK_SECRET", "")
  end
end

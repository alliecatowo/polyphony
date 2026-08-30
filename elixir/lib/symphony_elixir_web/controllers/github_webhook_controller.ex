defmodule SymphonyElixirWeb.GitHubWebhookController do
  @moduledoc """
  Minimal GitHub App webhook receiver for local/private deployments.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias SymphonyElixir.GitHub.WebhookStore
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.Endpoint

  @spec receive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive(conn, params) when is_map(params) do
    with :ok <- ensure_secret_configured(),
         :ok <- verify_signature(conn),
         {:ok, event} <- fetch_event(conn),
         {:ok, delivery_id} <- fetch_delivery(conn),
         {:ok, result} <- WebhookStore.ingest(webhook_headers(conn), params, store: webhook_store()),
         :ok <- enqueue_targeted_refresh(result.targeted_refresh) do
      acknowledge(conn, event, delivery_id, result)
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

      {:error, :missing_delivery} ->
        conn
        |> put_status(400)
        |> json(%{"error" => %{"code" => "missing_delivery", "message" => "Missing X-GitHub-Delivery header"}})

      {:error, {:persist_failed, reason}} ->
        Logger.error("Unable to persist GitHub webhook delivery: #{inspect(reason)}")

        conn
        |> put_status(503)
        |> json(%{"error" => %{"code" => "webhook_store_unavailable", "message" => "Webhook could not be durably recorded"}})

      {:error, :orchestrator_unavailable} ->
        conn
        |> put_status(503)
        |> json(%{
          "error" => %{
            "code" => "orchestrator_unavailable",
            "message" => "Webhook was recorded but could not be queued yet"
          }
        })

      {:error, {:missing_header, "x-github-delivery"}} ->
        conn
        |> put_status(400)
        |> json(%{"error" => %{"code" => "missing_delivery", "message" => "Missing X-GitHub-Delivery header"}})

      {:error, {:missing_header, "x-github-event"}} ->
        conn
        |> put_status(400)
        |> json(%{"error" => %{"code" => "missing_event", "message" => "Missing X-GitHub-Event header"}})
    end
  end

  def receive(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"error" => %{"code" => "invalid_payload", "message" => "Webhook payload must be a JSON object"}})
  end

  defp acknowledge(conn, event, delivery_id, result) do
    json(conn, %{
      "ok" => true,
      "event" => event,
      "action" => result.action,
      "delivery_id" => delivery_id,
      "duplicate" => result.status == :duplicate,
      "targeted_refresh" => result.targeted_refresh
    })
  end

  defp fetch_event(conn) do
    case get_req_header(conn, "x-github-event") do
      [event | _] when is_binary(event) and event != "" -> {:ok, event}
      _ -> {:error, :missing_event}
    end
  end

  defp fetch_delivery(conn) do
    case get_req_header(conn, "x-github-delivery") do
      [delivery | _] when is_binary(delivery) and delivery != "" -> {:ok, delivery}
      _ -> {:error, :missing_delivery}
    end
  end

  defp webhook_headers(conn) do
    %{
      "x-github-delivery" => List.first(get_req_header(conn, "x-github-delivery")),
      "x-github-event" => List.first(get_req_header(conn, "x-github-event")),
      "x-github-hook-id" => List.first(get_req_header(conn, "x-github-hook-id"))
    }
  end

  defp webhook_store do
    Endpoint.config(:webhook_store) || WebhookStore
  end

  defp enqueue_targeted_refresh(targets) when is_map(targets) do
    if targeted_work?(targets) do
      case Orchestrator.request_targeted_refresh(orchestrator(), targets) do
        :unavailable -> {:error, :orchestrator_unavailable}
        %{} -> :ok
      end
    else
      :ok
    end
  end

  defp enqueue_targeted_refresh(_targets), do: :ok

  defp targeted_work?(targets) do
    Enum.any?(["issues", "pull_requests", "checks", "workflows", "refs"], fn key ->
      case Map.get(targets, key) do
        values when is_list(values) -> values != []
        _ -> false
      end
    end)
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Orchestrator
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

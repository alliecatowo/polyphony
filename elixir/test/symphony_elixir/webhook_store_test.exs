defmodule SymphonyElixir.WebhookStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.WebhookStore

  test "normalizes issue, pull request, check, workflow, and repository identifiers" do
    payload = %{
      "action" => "completed",
      "repository" => %{
        "id" => 42,
        "node_id" => "R_kgDO42",
        "full_name" => "alliecatowo/patches",
        "name" => "patches",
        "owner" => %{"login" => "alliecatowo"}
      },
      "issue" => %{"number" => 17, "id" => 1700},
      "pull_request" => %{"number" => 23, "node_id" => "PR_23"},
      "check_run" => %{"id" => 9001, "node_id" => "CR_9001"},
      "check_suite" => %{"id" => 9002},
      "workflow_run" => %{"id" => 9100, "workflow_id" => 91, "run_number" => 3},
      "workflow_job" => %{"id" => 9200, "run_id" => 9100},
      "ref" => "refs/heads/main"
    }

    targets = WebhookStore.normalize_targets("workflow_run", "completed", payload)

    assert targets["scope"] == "targeted"
    assert targets["repository"]["full_name"] == "alliecatowo/patches"
    assert [%{"number" => 17, "kind" => "issue"}] = targets["issues"]
    assert [%{"number" => 23, "kind" => "pull_request"}] = targets["pull_requests"]
    assert Enum.any?(targets["checks"], &(&1["id"] == 9001 and &1["kind"] == "check_run"))
    assert Enum.any?(targets["checks"], &(&1["id"] == 9002 and &1["kind"] == "check_suite"))
    assert Enum.any?(targets["workflows"], &(&1["workflow_id"] == 91))
    assert Enum.any?(targets["workflows"], &(&1["run_id"] == 9100 and &1["kind"] == "workflow_job"))
    assert [%{"ref" => "refs/heads/main"}] = targets["refs"]
  end

  test "persists accepted deliveries and makes duplicate ingestion idempotent" do
    path = temporary_store_path()
    name = unique_store_name()
    {:ok, pid} = WebhookStore.start_link(path: path, name: name)
    on_exit(fn -> stop_store(pid, name, path) end)

    headers = %{"x-github-delivery" => "delivery-1", "x-github-event" => "issues"}
    payload = %{"action" => "opened", "issue" => %{"number" => 7}}

    assert {:ok, first} = WebhookStore.ingest(headers, payload, store: name)
    assert first.status == :accepted
    assert first.delivery_id == "delivery-1"
    assert first.targeted_refresh["issues"] == [%{"kind" => "issue", "number" => 7, "repository" => nil}]

    assert {:ok, duplicate} = WebhookStore.ingest(headers, %{"action" => "closed"}, store: name)
    assert duplicate.status == :duplicate
    assert duplicate.action == "opened"
    assert duplicate.targeted_refresh == first.targeted_refresh

    assert File.exists?(path)
    assert {:ok, persisted} = File.read(path)
    assert %{version: 1, deliveries: %{"delivery-1" => _record}} = :erlang.binary_to_term(persisted, [:safe])
  end

  test "reloads delivery identities from disk after the store process restarts" do
    path = temporary_store_path()
    name = unique_store_name()
    {:ok, pid} = WebhookStore.start_link(path: path, name: name)

    assert {:ok, %{status: :accepted}} =
             WebhookStore.ingest(
               %{"x-github-delivery" => "delivery-restart", "x-github-event" => "ping"},
               %{},
               store: name
             )

    assert :ok = GenServer.stop(pid)
    {:ok, restarted_pid} = WebhookStore.start_link(path: path, name: name)
    on_exit(fn -> stop_store(restarted_pid, name, path) end)

    assert {:ok, %{status: :duplicate, delivery_id: "delivery-restart"}} =
             WebhookStore.ingest(
               %{"x-github-delivery" => "delivery-restart", "x-github-event" => "ping"},
               %{"action" => "different"},
               store: name
             )
  end

  test "accepts case-insensitive delivery headers supplied as a list" do
    path = temporary_store_path()
    name = unique_store_name()
    {:ok, pid} = WebhookStore.start_link(path: path, name: name)
    on_exit(fn -> stop_store(pid, name, path) end)

    assert {:ok, %{status: :accepted}} =
             WebhookStore.ingest(
               [{"X-GitHub-Delivery", "delivery-case"}, {"X-GitHub-Event", "ping"}],
               %{},
               store: name
             )
  end

  defp temporary_store_path do
    root = Path.join(System.tmp_dir!(), "symphony-webhook-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, "webhooks.term")
  end

  defp unique_store_name do
    Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
  end

  defp stop_store(pid, name, _path) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    if Process.whereis(name), do: Process.unregister(name)
  end
end

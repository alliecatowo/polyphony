defmodule SymphonyElixir.GitHubProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Projection

  test "ingests and coalesces issue, pull request, check, workflow, and ref targets" do
    state = Projection.new(max_queue: 8, max_history: 8, max_entities: 8)

    refresh = %{
      "event" => "issues",
      "action" => "opened",
      "repository" => %{"full_name" => "alliecatowo/patches"},
      "issues" => [%{"node_id" => "I_1", "number" => 1, "title" => "old"}],
      "pull_requests" => [%{"node_id" => "PR_1", "number" => 10}],
      "checks" => [%{"id" => 20, "name" => "ci"}],
      "workflows" => [%{"run_id" => 30, "run_number" => 2}],
      "refs" => [%{"repository" => "alliecatowo/patches", "ref" => "main"}]
    }

    state = Projection.ingest(state, refresh)

    state =
      Projection.ingest(state, %{
        "issues" => [%{"node_id" => "I_1", "number" => 1, "title" => "new"}],
        "pull_requests" => [%{"node_id" => "PR_1", "number" => 10, "draft" => false}],
        "checks" => [%{"id" => 20, "conclusion" => "success"}]
      })

    assert Projection.ready_ids(state) == ["I_1"]
    assert length(state.queue) == 1
    assert Projection.entities(state, :issues)["I_1"]["title"] == "new"
    assert Projection.entities(state, :pull_requests)["PR_1"]["draft"] == false
    assert Projection.entities(state, :checks)[20]["conclusion"] == "success"
    assert map_size(Projection.entities(state, :workflows)) == 1
    assert map_size(Projection.entities(state, :refs)) == 1
  end

  test "takes bounded work, leases it, and acknowledges it" do
    state =
      Projection.new(max_queue: 4)
      |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1"}, %{"node_id" => "I_2"}, %{"node_id" => "I_3"}]})

    {items, state} = Projection.take(state, 2)
    assert Enum.map(items, & &1.issue_id) == ["I_1", "I_2"]
    assert Projection.ready_ids(state) == ["I_3"]
    assert Enum.all?(items, &(&1.attempts == 0))

    state = Projection.acknowledge(state, hd(items), %{reason: :delivered})
    refute Map.has_key?(state.pending, {:issues, "I_1"})
    assert state.pending[{:issues, "I_2"}].status == :leased
    assert state.pending[{:issues, "I_3"}].status == :queued
    assert Enum.any?(state.history, &(&1.event == :acknowledged and &1.issue_id == "I_1"))
  end

  test "exposes bounded ID-only take and pop operations" do
    state = Projection.new() |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1"}, %{"node_id" => "I_2"}]})
    {ids, state} = Projection.take_ids(state, 1)
    assert ids == ["I_1"]
    assert Projection.ready_ids(state) == ["I_2"]

    {id, state} = Projection.pop_id(state)
    assert id == "I_2"
    assert Projection.pop_id(state) == {nil, state}
  end

  test "provider requeue preserves attempts and metadata" do
    state =
      Projection.new()
      |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1"}]})

    {[item], state} = Projection.take(state)
    state = Projection.requeue_provider_wait(state, item, %{reason: :rate_limited, retry_at: 42})

    {[requeued], state} = Projection.take(state)
    assert requeued.issue_id == "I_1"
    assert requeued.attempts == 0
    assert requeued.provider_wait == %{reason: :rate_limited, retry_at: 42}
    assert Enum.any?(state.history, &(&1.event == :requeued and &1.attempts == 0))
  end

  test "explicit retry metadata can increment attempts while provider waits do not" do
    state =
      Projection.new()
      |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1"}]})

    {[item], state} = Projection.take(state)
    state = Projection.requeue(state, item, %{reason: :test_failure, increment_attempt: true})
    {[item], state} = Projection.take(state)
    assert item.attempts == 1

    state = Projection.requeue(state, item, %{provider_wait: %{retry_after: 10}, increment_attempt: true})
    {[item], _state} = Projection.take(state)
    assert item.attempts == 2
    assert item.provider_wait == %{retry_after: 10}
  end

  test "duplicate webhook targets never create duplicate queue entries" do
    state = Projection.new(max_queue: 2)
    refresh = %{"issues" => [%{"id" => 17, "node_id" => "I_17"}]}

    state = Projection.ingest(state, refresh)
    {[item], state} = Projection.take(state)

    assert item.issue_id == "I_17"
    assert Projection.ready_ids(state) == []
  end

  test "queue and entity caps are deterministic and bounded" do
    state =
      Projection.new(max_queue: 2, max_history: 3, max_entities: 2)
      |> Projection.ingest(%{
        "issues" => [%{"node_id" => "I_1"}, %{"node_id" => "I_2"}, %{"node_id" => "I_3"}],
        "pull_requests" => [%{"node_id" => "PR_1"}, %{"node_id" => "PR_2"}, %{"node_id" => "PR_3"}]
      })

    assert Projection.ready_ids(state) == ["I_2", "I_3"]
    assert map_size(Projection.entities(state, :issues)) == 2
    assert map_size(Projection.entities(state, :pull_requests)) == 2
    assert length(state.history) <= 3
    assert length(state.queue) <= 2
    assert map_size(state.pending) <= 2
  end

  test "leased issues coalesce updates without being dispatched twice" do
    state = Projection.new() |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1", "title" => "one"}]})
    {[item], state} = Projection.take(state)

    state = Projection.ingest(state, %{"issues" => [%{"node_id" => "I_1", "title" => "two"}]})
    assert Projection.ready_ids(state) == []
    assert state.pending[{:issues, "I_1"}].target["title"] == "two"

    state = Projection.requeue(state, item)
    {[item], _state} = Projection.take(state)
    assert item.target["title"] == "two"
  end

  test "persists atomically and preserves pending work across restart" do
    path = temporary_path()

    state =
      Projection.new(path: path, max_queue: 2)
      |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1"}, %{"node_id" => "I_2"}]})

    assert :ok = Projection.persist(state)
    assert File.exists?(path)
    assert {:ok, loaded} = Projection.load(path: path)
    assert Projection.ready_ids(loaded) == ["I_1", "I_2"]
    assert loaded.version == 1
  end

  test "persists leased work across restart" do
    path = temporary_path()
    state = Projection.new(path: path) |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1"}]})
    {[item], state} = Projection.take(state)
    assert item.issue_id == "I_1"
    assert :ok = Projection.persist(state)

    assert {:ok, loaded} = Projection.load(path: path)
    assert loaded.pending[{:issues, "I_1"}].status == :leased
    assert Projection.ready_ids(loaded) == []
  end

  test "does not make a network call or broaden a targeted refresh" do
    state = Projection.new() |> Projection.ingest(%{"issues" => [%{"node_id" => "I_1"}]})
    assert Projection.ready_ids(state) == ["I_1"]
    assert Projection.entities(state, :issues) |> Map.keys() == ["I_1"]
    refute Map.has_key?(state, :all_issues)
  end

  test "corrupt and unsupported state fail safely" do
    path = temporary_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not a term")
    assert {:error, {:invalid_state, :malformed_term}} = Projection.load(path: path)

    File.write!(path, :erlang.term_to_binary(%{version: 999}))
    assert {:error, {:unsupported_version, 999}} = Projection.load(path: path)
  end

  defp temporary_path do
    root = Path.join(System.tmp_dir!(), "symphony-projection-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, "projection.term")
  end
end

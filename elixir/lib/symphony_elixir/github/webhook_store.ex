defmodule SymphonyElixir.GitHub.WebhookStore do
  @moduledoc """
  Durable, idempotent storage for GitHub webhook deliveries.

  The store deliberately persists a compact projection rather than the complete
  webhook body.  This keeps the acknowledgement path bounded while retaining
  enough information for a later targeted refresh or delivery reconciliation.
  """

  use GenServer

  require Logger

  @schema_version 1
  @max_deliveries 10_000
  @default_filename "github-webhooks.term"

  @type target :: %{String.t() => term()}
  @type targeted_refresh :: %{
          required(String.t()) => term()
        }

  @type result :: %{
          status: :accepted | :duplicate,
          delivery_id: String.t(),
          event: String.t(),
          action: String.t() | nil,
          targets: targeted_refresh(),
          targeted_refresh: targeted_refresh()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Stores a delivery, returning `:duplicate` without applying it twice."
  @spec ingest(map() | keyword(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def ingest(headers, payload, opts \\ []) when is_map(payload) do
    store = Keyword.get(opts, :store, __MODULE__)

    with {:ok, store} <- ensure_store(store, opts),
         {:ok, delivery_id} <- required_header(headers, "x-github-delivery"),
         {:ok, event} <- required_header(headers, "x-github-event") do
      GenServer.call(store, {:ingest, delivery_id, event, header(headers, "x-github-hook-id"), payload}, 5_000)
    end
  end

  @doc "Returns the stable, targeted refresh projection for a webhook payload."
  @spec normalize_targets(String.t(), String.t() | nil, map()) :: targeted_refresh()
  def normalize_targets(event, action, payload) when is_binary(event) and is_map(payload) do
    repository = repository_target(payload)
    issue = value(payload, "issue")
    pull_request = value(payload, "pull_request")
    check_run = value(payload, "check_run")
    check_suite = value(payload, "check_suite")
    workflow_run = value(payload, "workflow_run")
    workflow_job = value(payload, "workflow_job")
    workflow = value(payload, "workflow")

    issues = compact([issue_target(issue, repository)])

    pull_requests =
      compact([
        pull_request_target(pull_request, repository)
      ]) ++
        associated_pull_request_targets(check_run, repository) ++
        associated_pull_request_targets(workflow_run, repository)

    checks =
      compact([
        check_target(check_run, repository, "check_run"),
        check_target(check_suite, repository, "check_suite"),
        check_target(value(check_run, "check_suite"), repository, "check_suite")
      ])

    workflows =
      compact([
        workflow_target(workflow_run, repository, "workflow_run"),
        workflow_target(workflow_job, repository, "workflow_job"),
        workflow_target(workflow, repository, "workflow")
      ])

    refs =
      payload
      |> value("ref")
      |> non_empty()
      |> case do
        nil -> []
        ref -> [%{"repository" => repository_name(repository), "ref" => ref}]
      end

    %{
      "event" => event,
      "action" => action,
      "repository" => repository,
      "issues" => issues,
      "pull_requests" => pull_requests,
      "checks" => checks,
      "workflows" => workflows,
      "refs" => refs,
      "scope" => "targeted"
    }
  end

  @doc "Returns the configured on-disk path used by the default store."
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    Keyword.get(opts, :path) ||
      Application.get_env(:symphony_elixir, :webhook_store_path) ||
      case Application.get_env(:symphony_elixir, :runtime_state_dir) ||
             System.get_env("POLYPHONY_RUNTIME_STATE_DIR") do
        directory when is_binary(directory) and directory != "" ->
          Path.join(directory, @default_filename)

        _ ->
          Path.join([File.cwd!(), ".polyphony", "runtime", @default_filename])
      end
  end

  @impl true
  def init(opts) do
    store_path = path(opts)

    case File.mkdir_p(Path.dirname(store_path)) do
      :ok ->
        {:ok, %{path: store_path, deliveries: load_deliveries(store_path), order: load_order(store_path)}}

      {:error, reason} ->
        {:stop, {:state_directory_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:ingest, delivery_id, event, hook_id, payload}, _from, state) do
    case Map.get(state.deliveries, delivery_id) do
      nil ->
        action = payload |> value("action") |> non_empty()
        targets = normalize_targets(event, action, payload)

        record = %{
          "delivery_id" => delivery_id,
          "hook_id" => non_empty(hook_id),
          "event" => event,
          "action" => action,
          "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "targets" => targets,
          "targeted_refresh" => targets
        }

        order = [delivery_id | state.order] |> Enum.uniq() |> Enum.take(@max_deliveries)
        deliveries = Map.put(state.deliveries, delivery_id, record) |> prune_deliveries(order)
        next_state = %{state | deliveries: deliveries, order: order}

        case persist(next_state) do
          :ok ->
            {:reply, {:ok, result(:accepted, record)}, next_state}

          {:error, reason} ->
            {:reply, {:error, {:persist_failed, reason}}, state}
        end

      record ->
        {:reply, {:ok, result(:duplicate, record)}, state}
    end
  end

  defp result(status, record) do
    %{
      status: status,
      delivery_id: record["delivery_id"],
      event: record["event"],
      action: record["action"],
      targets: record["targets"],
      targeted_refresh: record["targeted_refresh"]
    }
  end

  defp ensure_store(store, _opts) when is_pid(store), do: {:ok, store}

  defp ensure_store(store, opts) do
    case Process.whereis(store) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_opts = Keyword.put(opts, :name, store)

        case GenServer.start(__MODULE__, start_opts, name: store) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:store_unavailable, reason}}
        end
    end
  end

  defp persist(state) do
    persisted = %{version: @schema_version, deliveries: state.deliveries, order: state.order}
    path = state.path
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, :erlang.term_to_binary(persisted, [:compressed]), [:binary]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error = {:error, _reason} ->
        _ = File.rm(temporary)
        error
    end
  end

  defp load_deliveries(path) do
    case load_file(path) do
      %{version: @schema_version, deliveries: deliveries} when is_map(deliveries) -> deliveries
      %{deliveries: deliveries} when is_map(deliveries) -> deliveries
      _ -> %{}
    end
  end

  defp load_order(path) do
    case load_file(path) do
      %{version: @schema_version, order: order} when is_list(order) -> order
      %{order: order} when is_list(order) -> order
      %{deliveries: deliveries} when is_map(deliveries) -> Map.keys(deliveries)
      _ -> []
    end
  end

  defp load_file(path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          :erlang.binary_to_term(binary, [:safe])
        rescue
          ArgumentError ->
            Logger.warning("Ignoring invalid webhook store file: #{path}")
            %{}
        catch
          :error, reason ->
            Logger.warning("Ignoring invalid webhook store file #{path}: #{inspect(reason)}")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("Unable to read webhook store #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp prune_deliveries(deliveries, order) do
    Enum.reduce(Map.keys(deliveries), deliveries, fn delivery_id, acc ->
      if delivery_id in order, do: acc, else: Map.delete(acc, delivery_id)
    end)
  end

  defp required_header(headers, name) do
    case header(headers, name) |> non_empty() do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_header, name}}
    end
  end

  defp header(headers, name) when is_map(headers) do
    Map.get(headers, name) || Map.get(headers, String.replace(name, "-", "_"))
  end

  defp header(headers, name) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: value
      _ -> nil
    end)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case key do
          "action" -> Map.get(map, :action)
          "number" -> Map.get(map, :number)
          "id" -> Map.get(map, :id)
          "node_id" -> Map.get(map, :node_id)
          "check_suite_id" -> Map.get(map, :check_suite_id)
          "run_id" -> Map.get(map, :run_id)
          "run_number" -> Map.get(map, :run_number)
          "repository" -> Map.get(map, :repository)
          "issue" -> Map.get(map, :issue)
          "pull_request" -> Map.get(map, :pull_request)
          "pull_requests" -> Map.get(map, :pull_requests)
          "check_run" -> Map.get(map, :check_run)
          "check_suite" -> Map.get(map, :check_suite)
          "workflow_run" -> Map.get(map, :workflow_run)
          "workflow_job" -> Map.get(map, :workflow_job)
          "workflow" -> Map.get(map, :workflow)
          "ref" -> Map.get(map, :ref)
          "full_name" -> Map.get(map, :full_name)
          "owner" -> Map.get(map, :owner)
          "name" -> Map.get(map, :name)
          _ -> nil
        end
    end
  end

  defp value(_, _), do: nil

  defp repository_target(payload) do
    repository = value(payload, "repository") || %{}
    owner = value(repository, "owner") || %{}
    owner_login = value(owner, "login") || value(owner, "name")
    name = value(repository, "name")
    full_name = value(repository, "full_name") || join_repository(owner_login, name)

    %{
      "id" => value(repository, "id"),
      "node_id" => value(repository, "node_id"),
      "full_name" => full_name,
      "owner" => owner_login,
      "name" => name
    }
    |> compact_map()
  end

  defp issue_target(issue, repository) when is_map(issue) do
    identifier("issue", issue, repository, ["number", "id", "node_id"])
  end

  defp issue_target(_, _), do: nil

  defp pull_request_target(pull_request, repository) when is_map(pull_request) do
    identifier("pull_request", pull_request, repository, ["number", "id", "node_id"])
  end

  defp pull_request_target(_, _), do: nil

  defp associated_pull_request_targets(object, repository) when is_map(object) do
    object
    |> value("pull_requests")
    |> case do
      pull_requests when is_list(pull_requests) ->
        pull_requests
        |> Enum.map(&pull_request_target(&1, repository))
        |> compact()

      _ ->
        []
    end
  end

  defp associated_pull_request_targets(_, _), do: []

  defp check_target(check, repository, kind) when is_map(check) do
    identifier(kind, check, repository, ["id", "node_id", "check_suite_id", "run_id"])
  end

  defp check_target(_, _, _), do: nil

  defp workflow_target(workflow, repository, kind) when is_map(workflow) do
    identifier(kind, workflow, repository, ["id", "node_id", "workflow_id", "run_id", "run_number"])
  end

  defp workflow_target(_, _, _), do: nil

  defp identifier(kind, object, repository, fields) do
    values =
      Enum.reduce(fields, %{}, fn field, acc ->
        case non_empty(value(object, field)) do
          nil -> acc
          value -> Map.put(acc, field, value)
        end
      end)

    if map_size(values) == 0 do
      nil
    else
      values
      |> Map.put("kind", kind)
      |> Map.put("repository", repository_name(repository))
    end
  end

  defp repository_name(%{"full_name" => name}) when is_binary(name) and name != "", do: name
  defp repository_name(_), do: nil

  defp join_repository(owner, name) when is_binary(owner) and is_binary(name) and owner != "" and name != "" do
    owner <> "/" <> name
  end

  defp join_repository(_, _), do: nil

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty(value) when is_integer(value), do: value
  defp non_empty(value) when is_float(value), do: value
  defp non_empty(value) when not is_nil(value), do: value
  defp non_empty(_), do: nil

  defp compact(values), do: Enum.reject(values, &is_nil/1)

  defp compact_map(map), do: Enum.reject(map, fn {_key, value} -> is_nil(value) end) |> Map.new()
end

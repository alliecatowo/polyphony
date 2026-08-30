defmodule SymphonyElixir.GitHub.Projection do
  @moduledoc """
  A bounded, durable projection of targeted GitHub webhook refreshes.

  This module intentionally has no process, tracker, HTTP, or polling
  dependency.  `ingest/2`, `take/2`, `acknowledge/3`, and `requeue/3` are pure
  state transitions.  `load/1` and `persist/2` are the only functions that
  touch the filesystem, and persistence is explicit so a caller can put the
  state transition and its durability policy in a supervisor of its choice.

  The issue ready queue is a coalescing queue: a repeated webhook updates the
  issue projection but cannot add a second queue entry.  Pull requests,
  checks, workflows, and refs are similarly coalesced by their stable
  identifiers.  All collections have deterministic caps.
  """

  @schema_version 1
  @default_max_queue 256
  @default_max_history 512
  @default_max_entities 512
  @hard_max_queue 10_000
  @hard_max_history 10_000
  @hard_max_entities 10_000
  @categories [:issues, :pull_requests, :checks, :workflows, :refs]
  @entity_fields %{
    issues: "issues",
    pull_requests: "pull_requests",
    checks: "checks",
    workflows: "workflows",
    refs: "refs"
  }

  @typedoc "A normalized targeted refresh map emitted by WebhookStore."
  @type targeted_refresh :: %{optional(String.t() | atom()) => term()}

  @type issue_id :: term()
  @type item :: %{
          required(:issue_id) => issue_id(),
          required(:target) => map(),
          required(:attempts) => non_neg_integer(),
          required(:provider_wait) => term() | nil,
          required(:lease_sequence) => pos_integer()
        }

  @type state :: %{
          required(:version) => pos_integer(),
          required(:path) => Path.t() | nil,
          required(:max_queue) => non_neg_integer(),
          required(:max_history) => non_neg_integer(),
          required(:max_entities) => non_neg_integer(),
          required(:queue) => [term()],
          required(:pending) => %{optional(term()) => map()},
          required(:entities) => %{optional(atom()) => map()},
          required(:entity_order) => %{optional(atom()) => [term()]},
          required(:history) => [map()],
          required(:sequence) => non_neg_integer()
        }

  @doc "Creates an empty projection with bounded collection sizes."
  @spec new(keyword()) :: state()
  def new(opts \\ []) when is_list(opts) do
    %{
      version: @schema_version,
      path: Keyword.get(opts, :path),
      max_queue: non_negative_option(opts, :max_queue, @default_max_queue),
      max_history: non_negative_option(opts, :max_history, @default_max_history),
      max_entities: non_negative_option(opts, :max_entities, @default_max_entities),
      queue: [],
      pending: %{},
      entities: empty_entity_maps(),
      entity_order: empty_entity_orders(),
      history: [],
      sequence: 0
    }
  end

  @doc "Loads a projection from an injectable path, or returns an empty one."
  @spec load(keyword()) :: {:ok, state()} | {:error, term()}
  def load(opts \\ []) when is_list(opts) do
    state = new(opts)
    path = Keyword.get(opts, :path) || state.path

    case path do
      nil -> {:ok, state}
      path -> load_file(path, state)
    end
  end

  @doc "Atomically persists a projection to `opts[:path]` or its configured path."
  @spec persist(state(), keyword()) :: :ok | {:error, term()}
  def persist(state, opts \\ []) when is_map(state) and is_list(opts) do
    path = Keyword.get(opts, :path) || Map.get(state, :path)

    case path do
      nil -> {:error, :path_required}
      path -> persist_file(path, state)
    end
  end

  @doc "Ingests one normalized targeted-refresh map without performing a refresh."
  @spec ingest(state(), targeted_refresh()) :: state()
  def ingest(state, refresh) when is_map(state) and is_map(refresh) do
    sequence = state.sequence + 1
    state = put_entities(state, refresh, sequence)
    issue_targets = targets(refresh, :issues)

    {pending, queue, history} =
      Enum.reduce(issue_targets, {state.pending, state.queue, state.history}, fn target, {pending, queue, history} ->
        case identifier(:issues, target) do
          nil ->
            {pending, queue, history}

          issue_id ->
            key = identifier_key(:issues, issue_id)
            existing = Map.get(pending, key)

            item =
              coalesce_issue(existing, issue_id, target, sequence)
              |> Map.put(:provider_wait, nil)

            pending = Map.put(pending, key, item)

            if existing && existing.status == :leased do
              {pending, queue, history}
            else
              enqueue_issue(pending, queue, history, key, sequence, state.max_queue)
            end
        end
      end)

    history_entry = %{
      sequence: sequence,
      event: :ingested,
      issue_ids: Enum.map(issue_targets, &identifier(:issues, &1)) |> Enum.reject(&is_nil/1),
      target_counts: Enum.into(@categories, %{}, &{&1, length(targets(refresh, &1))})
    }

    %{
      state
      | pending: pending,
        queue: queue,
        history: cap_history([history_entry | history], state.max_history),
        sequence: sequence
    }
  end

  @doc "Takes at most `count` issue refreshes and leases them to the caller."
  @spec take(state(), non_neg_integer()) :: {[item()], state()}
  def take(state, count \\ 1)

  @spec take(state(), non_neg_integer()) :: {[item()], state()}
  def take(state, count) when is_map(state) and is_integer(count) and count >= 0 do
    {keys, remaining_queue} = Enum.split(state.queue, count)
    sequence = state.sequence + if(keys == [], do: 0, else: 1)

    {items, pending} =
      Enum.reduce(keys, {[], state.pending}, fn key, {items, pending} ->
        case Map.get(pending, key) do
          %{status: :queued} = record ->
            item =
              record
              |> Map.put(:status, :leased)
              |> Map.put(:lease_sequence, sequence)

            {[public_item(item) | items], Map.put(pending, key, item)}

          _ ->
            {items, pending}
        end
      end)

    {%{state | queue: remaining_queue, pending: pending, sequence: sequence}, items}
    |> reverse_take_result()
  end

  @doc "Pops one issue refresh, returning `nil` when the queue is empty."
  @spec pop(state()) :: {item() | nil, state()}
  def pop(state) when is_map(state) do
    {items, state} = take(state, 1)
    {List.first(items), state}
  end

  @doc "Takes bounded issue IDs and leases their corresponding refresh records."
  @spec take_ids(state(), non_neg_integer()) :: {[issue_id()], state()}
  def take_ids(state, count \\ 1) when is_map(state) do
    {items, state} = take(state, count)
    {Enum.map(items, & &1.issue_id), state}
  end

  @doc "Pops one issue ID and leases its corresponding refresh record."
  @spec pop_id(state()) :: {issue_id() | nil, state()}
  def pop_id(state) when is_map(state) do
    {item, state} = pop(state)
    {if(item, do: item.issue_id), state}
  end

  @doc "Acknowledges a leased or queued issue and records a bounded history entry."
  @spec acknowledge(state(), issue_id() | item(), map() | keyword()) :: state()
  def acknowledge(state, issue, metadata \\ %{}) when is_map(state) do
    key = issue_key(issue)

    case Map.pop(state.pending, key) do
      {nil, _pending} ->
        state

      {record, pending} ->
        history_entry =
          history_entry(state.sequence + 1, :acknowledged, record, metadata)

        %{
          state
          | pending: pending,
            queue: List.delete(state.queue, key),
            history: cap_history([history_entry | state.history], state.max_history),
            sequence: state.sequence + 1
        }
    end
  end

  @doc "Requeues an issue. Provider waits preserve attempts unless explicitly overridden."
  @spec requeue(state(), issue_id() | item(), map() | keyword()) :: state()
  def requeue(state, issue, metadata \\ %{}) when is_map(state) do
    key = issue_key(issue)

    case Map.get(state.pending, key) do
      nil ->
        state

      record ->
        provider_wait = metadata_value(metadata, :provider_wait)
        increment? = metadata_value(metadata, :increment_attempt, false) == true
        attempts = record.attempts + if(increment?, do: 1, else: 0)

        record =
          record
          |> Map.put(:status, :queued)
          |> Map.put(:attempts, attempts)
          |> Map.put(:provider_wait, provider_wait)

        pending = Map.put(state.pending, key, record)
        {pending, queue, history} = enqueue_issue(pending, state.queue, state.history, key, state.sequence + 1, state.max_queue)

        entry = history_entry(state.sequence + 1, :requeued, record, metadata)

        %{
          state
          | pending: pending,
            queue: queue,
            history: cap_history([entry | history], state.max_history),
            sequence: state.sequence + 1
        }
    end
  end

  @doc "Requeues an issue with provider metadata without incrementing its attempt."
  @spec requeue_provider_wait(state(), issue_id() | item(), term()) :: state()
  def requeue_provider_wait(state, issue, provider_wait) do
    requeue(state, issue, %{provider_wait: provider_wait})
  end

  @doc "Returns the currently queued issue IDs in deterministic order."
  @spec ready_ids(state()) :: [issue_id()]
  def ready_ids(state) when is_map(state) do
    Enum.flat_map(state.queue, fn key ->
      case Map.get(state.pending, key) do
        %{status: :queued, issue_id: issue_id} -> [issue_id]
        _ -> []
      end
    end)
  end

  @doc "Returns a bounded snapshot suitable for a dashboard or test."
  @spec snapshot(state()) :: map()
  def snapshot(state) when is_map(state) do
    %{
      version: state.version,
      queue_size: length(ready_ids(state)),
      pending_size: map_size(state.pending),
      history_size: length(state.history),
      ready_ids: ready_ids(state),
      entities: state.entities
    }
  end

  @doc "Returns a coalesced entity projection for a category."
  @spec entities(state(), atom()) :: map()
  def entities(state, category) when is_map(state) and category in @categories do
    Map.get(state.entities, category, %{})
  end

  defp load_file(path, state) do
    case File.read(path) do
      {:ok, binary} ->
        with {:ok, persisted} <- decode(binary),
             {:ok, loaded} <- validate_and_restore(persisted, state) do
          {:ok, %{loaded | path: path}}
        end

      {:error, :enoent} ->
        {:ok, %{state | path: path}}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp persist_file(path, state) do
    persisted = persisted_state(state)
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, :erlang.term_to_binary(persisted, [:compressed]), [:binary]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:persist_failed, reason}}
    end
  end

  defp persisted_state(state) do
    state
    |> Map.take([:version, :max_queue, :max_history, :max_entities, :queue, :pending, :entities, :entity_order, :history, :sequence])
    |> Map.put(:version, @schema_version)
  end

  defp decode(binary) do
    try do
      case :erlang.binary_to_term(binary, [:safe]) do
        persisted when is_map(persisted) -> {:ok, persisted}
        _ -> {:error, {:invalid_state, :not_a_map}}
      end
    rescue
      ArgumentError -> {:error, {:invalid_state, :malformed_term}}
    catch
      :error, reason -> {:error, {:invalid_state, reason}}
    end
  end

  defp validate_and_restore(%{version: @schema_version} = persisted, fresh) do
    with {:ok, queue} <- valid_list(persisted, :queue),
         {:ok, pending} <- valid_map(persisted, :pending),
         {:ok, entities} <- valid_map(persisted, :entities),
         {:ok, entity_order} <- valid_map(persisted, :entity_order),
         {:ok, history} <- valid_list(persisted, :history),
         {:ok, sequence} <- valid_non_negative_integer(persisted, :sequence) do
      restored = %{
        fresh
        | max_queue: persisted_value(persisted, :max_queue, fresh.max_queue),
          max_history: persisted_value(persisted, :max_history, fresh.max_history),
          max_entities: persisted_value(persisted, :max_entities, fresh.max_entities),
          queue: queue,
          pending: pending,
          entities: normalize_entities(entities),
          entity_order: normalize_entity_order(entity_order),
          history: history,
          sequence: sequence
      }

      {:ok, bound_state(restored)}
    end
  end

  defp validate_and_restore(%{version: version}, _fresh), do: {:error, {:unsupported_version, version}}
  defp validate_and_restore(_, _fresh), do: {:error, {:invalid_state, :missing_version}}

  defp valid_list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_state, {:expected_list, key}}}
    end
  end

  defp valid_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_state, {:expected_map, key}}}
    end
  end

  defp valid_non_negative_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_state, {:expected_non_negative_integer, key}}}
    end
  end

  defp persisted_value(map, key, fallback) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> fallback
    end
  end

  defp put_entities(state, refresh, sequence) do
    Enum.reduce(@categories, state, fn category, state ->
      Enum.reduce(targets(refresh, category), state, fn target, state ->
        case identifier(category, target) do
          nil -> state
          identifier -> put_entity(state, category, identifier, target, sequence)
        end
      end)
    end)
  end

  defp put_entity(state, category, identifier, target, sequence) do
    key = identifier
    category_entities = Map.get(state.entities, category, %{})
    category_entities = Map.update(category_entities, key, target, &Map.merge(&1, target))
    order = [key | Map.get(state.entity_order, category, [])] |> Enum.uniq()
    {category_entities, order} = bound_entities(category_entities, order, state.max_entities)

    %{
      state
      | entities: Map.put(state.entities, category, category_entities),
        entity_order: Map.put(state.entity_order, category, order),
        history: state.history
    }
    |> maybe_record_entity_sequence(category, key, sequence)
  end

  defp maybe_record_entity_sequence(state, _category, _key, _sequence), do: state

  defp bound_entities(entities, order, max_entities) do
    kept = Enum.take(order, max_entities)
    {Enum.reduce(Map.keys(entities), entities, fn key, acc -> if key in kept, do: acc, else: Map.delete(acc, key) end), kept}
  end

  defp coalesce_issue(nil, issue_id, target, sequence) do
    %{
      issue_id: issue_id,
      target: target,
      attempts: 0,
      provider_wait: nil,
      status: :queued,
      lease_sequence: sequence
    }
  end

  defp coalesce_issue(existing, issue_id, target, _sequence) do
    %{existing | issue_id: issue_id, target: Map.merge(existing.target, target)}
  end

  defp enqueue_issue(pending, queue, history, key, sequence, max_queue) do
    if key in queue do
      {pending, queue, history}
    else
      queue = queue ++ [key]

      if length(queue) <= max_queue do
        {pending, queue, history}
      else
        {evicted, queue} = evict_oldest(queue)

        pending =
          case Map.get(pending, evicted) do
            %{status: :queued} -> Map.delete(pending, evicted)
            _ -> pending
          end

        entry = %{sequence: sequence, event: :queue_overflow, issue_key: evicted}
        {pending, queue, [entry | history]}
      end
    end
  end

  defp evict_oldest([key | rest]), do: {key, rest}
  defp evict_oldest([]), do: {nil, []}

  defp history_entry(sequence, event, record, metadata) do
    %{
      sequence: sequence,
      event: event,
      issue_id: record.issue_id,
      attempts: record.attempts,
      provider_wait: metadata_value(metadata, :provider_wait)
    }
  end

  defp public_item(record) do
    Map.take(record, [:issue_id, :target, :attempts, :provider_wait, :lease_sequence])
  end

  defp reverse_take_result({state, items}), do: {Enum.reverse(items), state}

  defp issue_key(%{issue_id: issue_id}), do: identifier_key(:issues, issue_id)
  defp issue_key(%{"issue_id" => issue_id}), do: identifier_key(:issues, issue_id)
  defp issue_key(issue_id), do: identifier_key(:issues, issue_id)

  defp identifier(category, target) when is_map(target) do
    fields =
      case category do
        :issues -> ["node_id", :node_id, "id", :id, "number", :number]
        :pull_requests -> ["node_id", :node_id, "id", :id, "number", :number]
        :checks -> ["node_id", :node_id, "id", :id, "check_suite_id", :check_suite_id, "run_id", :run_id]
        :workflows -> ["node_id", :node_id, "id", :id, "run_id", :run_id, "workflow_id", :workflow_id, "run_number", :run_number]
        :refs -> [{:composite, ["repository", :repository, "ref", :ref]}]
      end

    Enum.find_value(fields, fn
      {:composite, keys} ->
        repository = value(target, Enum.at(keys, 0)) || value(target, Enum.at(keys, 1))
        ref = value(target, Enum.at(keys, 2)) || value(target, Enum.at(keys, 3))
        if present?(repository) and present?(ref), do: {repository, ref}

      field ->
        case value(target, field) do
          value when not is_nil(value) and value != "" -> value
          _ -> nil
        end
    end)
  end

  defp identifier(_, _), do: nil

  defp identifier_key(category, identifier), do: {category, identifier}

  defp targets(refresh, category) do
    key = Map.fetch!(@entity_fields, category)

    case value(refresh, key) do
      values when is_list(values) -> Enum.filter(values, &is_map/1)
      _ -> []
    end
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error when is_binary(key) ->
        Enum.find_value(map, fn
          {existing_key, value} when is_atom(existing_key) ->
            if Atom.to_string(existing_key) == key, do: value

          _ ->
            nil
        end)

      :error when is_atom(key) ->
        Enum.find_value(map, fn
          {existing_key, value} when is_binary(existing_key) ->
            if existing_key == Atom.to_string(key), do: value

          _ ->
            nil
        end)
    end
  end

  defp value(_, _), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp metadata_value(metadata, key, default \\ nil)
  defp metadata_value(metadata, key, default) when is_map(metadata), do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  defp metadata_value(metadata, key, default) when is_list(metadata), do: Keyword.get(metadata, key, default)
  defp metadata_value(_, _, default), do: default

  defp cap_history(history, max_history), do: Enum.take(history, max_history)

  defp bound_state(state) do
    queue = Enum.take(state.queue, state.max_queue)
    queued_keys = MapSet.new(queue)

    pending =
      state.pending
      |> Enum.sort_by(fn {key, _record} -> :erlang.term_to_binary(key) end)
      |> Enum.reduce(%{}, fn {key, record}, acc ->
        if is_map(record) and (MapSet.member?(queued_keys, key) or Map.get(record, :status) == :leased) do
          Map.put(acc, key, record)
        else
          acc
        end
      end)

    {entities, entity_order} =
      Enum.reduce(@categories, {empty_entity_maps(), empty_entity_orders()}, fn category, {entities, orders} ->
        category_entities = Map.get(state.entities, category, %{})
        category_order = Map.get(state.entity_order, category, [])
        category_order = if category_order == [], do: Map.keys(category_entities) |> Enum.sort_by(&:erlang.term_to_binary/1), else: category_order
        {category_entities, category_order} = bound_entities(category_entities, category_order, state.max_entities)
        {Map.put(entities, category, category_entities), Map.put(orders, category, category_order)}
      end)

    %{state | queue: queue, pending: pending, entities: entities, entity_order: entity_order, history: cap_history(state.history, state.max_history)}
  end

  defp normalize_entities(entities) do
    Enum.reduce(@categories, empty_entity_maps(), fn category, acc ->
      value = Map.get(entities, category) || Map.get(entities, Atom.to_string(category))
      Map.put(acc, category, if(is_map(value), do: value, else: %{}))
    end)
  end

  defp normalize_entity_order(order) do
    Enum.reduce(@categories, empty_entity_orders(), fn category, acc ->
      value = Map.get(order, category) || Map.get(order, Atom.to_string(category))
      Map.put(acc, category, if(is_list(value), do: value, else: []))
    end)
  end

  defp empty_entity_maps, do: Map.new(@categories, &{&1, %{}})
  defp empty_entity_orders, do: Map.new(@categories, &{&1, []})

  defp non_negative_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> min(value, hard_cap(key))
      _ -> default
    end
  end

  defp hard_cap(:max_queue), do: @hard_max_queue
  defp hard_cap(:max_history), do: @hard_max_history
  defp hard_cap(:max_entities), do: @hard_max_entities
end

defmodule SymphonyElixir.GitHub.Gateway do
  @moduledoc """
  Single serialized boundary for every GitHub request.

  Serialization intentionally trades a little throughput for a hard safety
  property: once one response opens the provider circuit, no concurrent caller
  can slip another request through before the circuit state is visible.
  """

  use GenServer
  require Logger

  @fallback_backoff_ms 300_000
  @max_backoff_ms 3_600_000
  @request_timeout_ms 35_000

  defstruct circuit_until_ms: nil,
            circuit_kind: nil,
            reset_at: nil,
            backoff_ms: @fallback_backoff_ms,
            last_error: nil,
            request_count: 0,
            in_flight: nil,
            queue: :queue.new()

  @type resource :: :graphql | :rest

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec request(resource(), (-> term()), keyword()) :: term()
  def request(resource, fun, opts \\ []) when resource in [:graphql, :rest] and is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout_ms = Keyword.get(opts, :timeout_ms, @request_timeout_ms)
    queue_timeout_ms = Keyword.get(opts, :queue_timeout_ms, timeout_ms + 5_000)
    request_id = make_ref()

    with :ok <- ensure_started(server) do
      case acquire(server, resource, request_id, queue_timeout_ms) do
        {:ok, ^request_id} ->
          result = invoke(fun, timeout_ms)
          GenServer.call(server, {:complete, self(), request_id, result}, timeout_ms + 5_000)

        result ->
          result
      end
    end
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    case Process.whereis(server) do
      nil -> %{available?: false, circuit: :unavailable}
      _pid -> GenServer.call(server, :snapshot)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:snapshot, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    {:reply,
     %{
       available?: true,
       circuit: if(circuit_open?(state, now_ms), do: :open, else: :closed),
       circuit_kind: state.circuit_kind,
       retry_in_ms: retry_in_ms(state, now_ms),
       reset_at: state.reset_at,
       last_error: state.last_error,
       request_count: state.request_count
     }, state}
  end

  def handle_call({:acquire, pid, resource, request_id}, from, state) do
    now_ms = System.monotonic_time(:millisecond)

    if circuit_open?(state, now_ms) do
      {:reply, circuit_error(state, now_ms), state}
    else
      request = %{
        from: from,
        monitor_ref: Process.monitor(pid),
        pid: pid,
        request_id: request_id,
        resource: resource
      }

      if state.in_flight do
        {:noreply, %{state | queue: :queue.in(request, state.queue)}}
      else
        {:reply, {:ok, request_id}, %{state | in_flight: request}}
      end
    end
  end

  def handle_call({:complete, pid, request_id, result}, _from, %{in_flight: in_flight} = state)
      when is_map(in_flight) and in_flight.pid == pid and in_flight.request_id == request_id do
    Process.demonitor(in_flight.monitor_ref, [:flush])
    state = %{state | request_count: state.request_count + 1, in_flight: nil}

    {reply, state} =
      case classify(result) do
        {:rate_limited, metadata} ->
          state = open_circuit(state, in_flight.resource, metadata)
          {{:error, {:github_rate_limited, state.reset_at, retry_in_ms(state, System.monotonic_time(:millisecond))}}, state}

        {:provider_unavailable, metadata} ->
          state = open_provider_circuit(state, in_flight.resource, metadata)
          {circuit_error(state, System.monotonic_time(:millisecond)), state}

        :success ->
          {result, close_circuit(state)}

        :other ->
          {result, state}
      end

    {:reply, reply, grant_next(state)}
  end

  def handle_call({:complete, _pid, _request_id, _result}, _from, state) do
    {:reply, {:error, :github_gateway_request_not_owned}, state}
  end

  @impl true
  def handle_cast({:cancel, pid, request_id}, state) do
    cond do
      match?(%{pid: ^pid, request_id: ^request_id}, state.in_flight) ->
        Process.demonitor(state.in_flight.monitor_ref, [:flush])
        {:noreply, grant_next(%{state | in_flight: nil})}

      true ->
        {:noreply, cancel_queued(state, pid, request_id)}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    cond do
      match?(%{monitor_ref: ^monitor_ref}, state.in_flight) ->
        {:noreply, grant_next(%{state | in_flight: nil})}

      true ->
        {:noreply, drop_queued_monitor(state, monitor_ref)}
    end
  end

  defp acquire(server, resource, request_id, timeout_ms) do
    try do
      GenServer.call(server, {:acquire, self(), resource, request_id}, timeout_ms)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(server, {:cancel, self(), request_id})
        {:error, {:github_provider_unavailable, %{kind: :queue_timeout, timeout_ms: timeout_ms}}}
    end
  end

  defp grant_next(%{in_flight: nil, queue: queue} = state) do
    if circuit_open?(state, System.monotonic_time(:millisecond)) do
      reject_queued(state)
    else
      case :queue.out(queue) do
        {:empty, _queue} ->
          state

        {{:value, request}, queue} ->
          if Process.alive?(request.pid) do
            GenServer.reply(request.from, {:ok, request.request_id})
            %{state | in_flight: request, queue: queue}
          else
            Process.demonitor(request.monitor_ref, [:flush])
            grant_next(%{state | queue: queue})
          end
      end
    end
  end

  defp reject_queued(%{queue: queue} = state) do
    reply = circuit_error(state, System.monotonic_time(:millisecond))

    queue
    |> :queue.to_list()
    |> Enum.each(fn request ->
      Process.demonitor(request.monitor_ref, [:flush])
      if Process.alive?(request.pid), do: GenServer.reply(request.from, reply)
    end)

    %{state | queue: :queue.new()}
  end

  defp cancel_queued(%{queue: queue} = state, pid, request_id) do
    {kept, cancelled} =
      queue
      |> :queue.to_list()
      |> Enum.split_with(fn request -> request.pid != pid or request.request_id != request_id end)

    Enum.each(cancelled, &Process.demonitor(&1.monitor_ref, [:flush]))
    %{state | queue: :queue.from_list(kept)}
  end

  defp drop_queued_monitor(%{queue: queue} = state, monitor_ref) do
    {kept, dropped} =
      queue
      |> :queue.to_list()
      |> Enum.split_with(fn request -> request.monitor_ref != monitor_ref end)

    Enum.each(dropped, &Process.demonitor(&1.monitor_ref, [:flush]))
    %{state | queue: :queue.from_list(kept)}
  end

  defp ensure_started(server) when is_atom(server) do
    case Process.whereis(server) do
      nil ->
        case start_link(name: server) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:github_gateway_unavailable, reason}}
        end

      _pid ->
        :ok
    end
  end

  defp ensure_started(_server), do: :ok

  # The request must run outside the caller so a hung transport can be killed
  # without losing the caller before it reports completion to the gateway.
  defp invoke(fun, timeout_ms) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {result_ref, invoke_request(fun)})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:github_request_exit, :exit, inspect_reason(reason)}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, {:github_gateway_execution_timeout, timeout_ms}}
    end
  end

  defp invoke_request(fun) do
    fun.()
  rescue
    exception -> {:error, {:github_request_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:github_request_exit, kind, reason}}
  end

  defp classify({:ok, %{status: status} = response}) do
    remaining = response_header(response, "x-ratelimit-remaining")
    body_message = response_body_message(Map.get(response, :body))

    rate_limited? =
      status == 429 or
        (status == 403 and (remaining == "0" or contains_rate_limit?(body_message))) or
        graphql_rate_limit_body?(Map.get(response, :body))

    if rate_limited? do
      {:rate_limited,
       %{
         retry_after: response_header(response, "retry-after"),
         reset: response_header(response, "x-ratelimit-reset"),
         remaining: remaining,
         message: "rate limited"
       }}
    else
      if status == 408 or status in 500..599 do
        {:provider_unavailable, %{status: status, message: "provider unavailable"}}
      else
        :success
      end
    end
  end

  defp classify({:error, {:github_gateway_execution_timeout, timeout_ms}}) do
    {:provider_unavailable, %{kind: :execution_timeout, timeout_ms: timeout_ms}}
  end

  defp classify({:error, reason}) do
    {:provider_unavailable, %{kind: :transport, reason: inspect_reason(reason)}}
  end

  defp classify(_result), do: :other

  defp inspect_reason(reason) when is_atom(reason), do: reason
  defp inspect_reason(%{__struct__: module}) when is_atom(module), do: module
  defp inspect_reason(_reason), do: :request_failed

  defp open_provider_circuit(state, resource, _metadata) do
    now_ms = System.monotonic_time(:millisecond)
    backoff_ms = provider_backoff_ms(state.backoff_ms)
    reset_at = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

    Logger.error("GitHub provider circuit opened resource=#{resource} kind=unavailable backoff_ms=#{backoff_ms} reset_at=#{DateTime.to_iso8601(reset_at)}")

    %{
      state
      | circuit_until_ms: now_ms + backoff_ms,
        circuit_kind: :provider_unavailable,
        reset_at: DateTime.to_iso8601(reset_at),
        backoff_ms: min(max(backoff_ms * 2, @fallback_backoff_ms), @max_backoff_ms),
        last_error: "provider unavailable"
    }
  end

  defp provider_backoff_ms(previous_backoff_ms), do: min(previous_backoff_ms, @max_backoff_ms)

  defp circuit_error(%{circuit_kind: :provider_unavailable, reset_at: reset_at} = state, now_ms) do
    {:error, {:github_provider_unavailable, %{kind: :circuit_open, reset_at: reset_at, retry_in_ms: retry_in_ms(state, now_ms)}}}
  end

  defp circuit_error(state, now_ms),
    do: {:error, {:github_rate_limited, state.reset_at, retry_in_ms(state, now_ms)}}

  defp open_circuit(state, resource, metadata) do
    now_ms = System.monotonic_time(:millisecond)
    backoff_ms = reset_backoff_ms(metadata, state.backoff_ms)
    reset_at = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

    Logger.error("GitHub provider circuit opened resource=#{resource} backoff_ms=#{backoff_ms} reset_at=#{DateTime.to_iso8601(reset_at)}")

    %{
      state
      | circuit_until_ms: now_ms + backoff_ms,
        circuit_kind: :rate_limited,
        reset_at: DateTime.to_iso8601(reset_at),
        backoff_ms: min(max(backoff_ms * 2, @fallback_backoff_ms), @max_backoff_ms),
        last_error: metadata[:message] || "rate limited"
    }
  end

  defp close_circuit(state) do
    %{
      state
      | circuit_until_ms: nil,
        circuit_kind: nil,
        reset_at: nil,
        backoff_ms: @fallback_backoff_ms,
        last_error: nil
    }
  end

  defp reset_backoff_ms(metadata, previous_backoff_ms) do
    retry_after_ms = parse_positive_integer(metadata[:retry_after], 1_000)
    reset_ms = reset_epoch_delay_ms(metadata[:reset])

    [retry_after_ms, reset_ms, previous_backoff_ms, @fallback_backoff_ms]
    |> Enum.filter(&is_integer/1)
    |> Enum.max()
    |> min(@max_backoff_ms)
  end

  defp reset_epoch_delay_ms(value) do
    case Integer.parse(to_string(value || "")) do
      {epoch_seconds, ""} -> max(0, (epoch_seconds - System.system_time(:second)) * 1_000)
      _ -> nil
    end
  end

  defp parse_positive_integer(value, multiplier) do
    case Integer.parse(to_string(value || "")) do
      {number, ""} when number > 0 -> number * multiplier
      _ -> nil
    end
  end

  defp circuit_open?(%{circuit_until_ms: until_ms}, now_ms) when is_integer(until_ms), do: until_ms > now_ms
  defp circuit_open?(_state, _now_ms), do: false

  defp retry_in_ms(%{circuit_until_ms: until_ms}, now_ms) when is_integer(until_ms), do: max(0, until_ms - now_ms)
  defp retry_in_ms(_state, _now_ms), do: nil

  defp response_header(%{headers: headers}, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.downcase(name)) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp response_header(%{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == String.downcase(name), do: List.first(List.wrap(value))

      _ ->
        nil
    end)
  end

  defp response_header(_response, _name), do: nil

  defp graphql_rate_limit_body?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn error ->
      code = error["type"] || error["code"] || error[:type] || error[:code]
      code in ["RATE_LIMIT", "graphql_rate_limit", :rate_limit] or contains_rate_limit?(error["message"] || error[:message])
    end)
  end

  defp graphql_rate_limit_body?(_body), do: false

  defp response_body_message(%{"message" => message}), do: to_string(message)
  defp response_body_message(%{"errors" => [error | _]}), do: to_string(error["message"] || "")
  defp response_body_message(body) when is_binary(body), do: body
  defp response_body_message(_body), do: ""

  defp contains_rate_limit?(message) when is_binary(message),
    do: String.contains?(String.downcase(message), "rate limit")

  defp contains_rate_limit?(_message), do: false
end

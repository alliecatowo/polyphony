defmodule SymphonyElixir.GitHub.GatewayTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Gateway

  test "executes the request closure in the requesting process" do
    name = Module.concat(__MODULE__, "Caller#{System.unique_integer([:positive])}")
    start_supervised!({Gateway, name: name})
    caller = self()

    assert {:ok, %{status: 200}} =
             Gateway.request(
               :rest,
               fn ->
                 send(caller, {:closure_process, self()})
                 {:ok, %{status: 200, headers: %{}, body: %{}}}
               end,
               server: name
             )

    assert_receive {:closure_process, ^caller}
  end

  test "one rate-limit response prevents every queued caller from reaching GitHub" do
    name = Module.concat(__MODULE__, "Gate#{System.unique_integer([:positive])}")
    start_supervised!({Gateway, name: name})
    counter = :counters.new(1, [])
    test_pid = self()

    limited = fn ->
      send(test_pid, {:limited_request_started, self()})

      receive do
        :release_limited_request -> :ok
      end

      :counters.add(counter, 1, 1)

      {:ok,
       %{
         status: 200,
         headers: %{"x-ratelimit-remaining" => ["0"]},
         body: %{
           "errors" => [
             %{"type" => "RATE_LIMIT", "code" => "graphql_rate_limit", "message" => "API rate limit exceeded"}
           ]
         }
       }}
    end

    first = Task.async(fn -> Gateway.request(:graphql, limited, server: name) end)
    assert_receive {:limited_request_started, limited_pid}

    second =
      Task.async(fn ->
        send(test_pid, :queued_request_started)

        Gateway.request(
          :graphql,
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, %{status: 200, headers: %{}, body: %{}}}
          end,
          server: name
        )
      end)

    assert_receive :queued_request_started
    Process.sleep(10)
    send(limited_pid, :release_limited_request)

    assert {:error, {:github_rate_limited, _reset_at, retry_in_ms}} = Task.await(first)
    assert retry_in_ms > 0

    assert {:error, {:github_rate_limited, _reset_at, retry_in_ms}} = Task.await(second)
    assert retry_in_ms > 0

    assert :counters.get(counter, 1) == 1
    assert Gateway.snapshot(name).circuit == :open
  end

  test "a permission failure does not masquerade as rate limiting" do
    name = Module.concat(__MODULE__, "Permission#{System.unique_integer([:positive])}")
    start_supervised!({Gateway, name: name})

    response = {:ok, %{status: 403, headers: %{}, body: %{"message" => "Resource not accessible"}}}

    assert ^response = Gateway.request(:rest, fn -> response end, server: name)
    assert Gateway.snapshot(name).circuit == :closed
  end

  test "a provider outage parks queued callers without retrying the provider" do
    name = Module.concat(__MODULE__, "Unavailable#{System.unique_integer([:positive])}")
    start_supervised!({Gateway, name: name})
    counter = :counters.new(1, [])
    test_pid = self()

    first =
      Task.async(fn ->
        Gateway.request(
          :rest,
          fn ->
            send(test_pid, :provider_request_started)
            :counters.add(counter, 1, 1)
            {:error, :econnrefused}
          end,
          server: name
        )
      end)

    assert_receive :provider_request_started

    second =
      Task.async(fn ->
        Gateway.request(
          :rest,
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, %{status: 200, headers: %{}, body: %{}}}
          end,
          server: name
        )
      end)

    assert {:error, {:github_provider_unavailable, %{kind: :circuit_open, retry_in_ms: retry_in_ms}}} =
             Task.await(first)

    assert retry_in_ms > 0

    assert {:error, {:github_provider_unavailable, %{kind: :circuit_open, retry_in_ms: retry_in_ms}}} =
             Task.await(second)

    assert retry_in_ms > 0
    assert :counters.get(counter, 1) == 1
    assert Gateway.snapshot(name).circuit == :open
    assert Gateway.snapshot(name).circuit_kind == :provider_unavailable
  end

  test "requests are serialized so concurrent callers cannot race the circuit" do
    name = Module.concat(__MODULE__, "Serialized#{System.unique_integer([:positive])}")
    start_supervised!({Gateway, name: name})
    active = :counters.new(2, [])

    request = fn ->
      :counters.add(active, 1, 1)
      current = :counters.get(active, 1)
      maximum = :counters.get(active, 2)
      if current > maximum, do: :counters.put(active, 2, current)
      Process.sleep(5)
      :counters.sub(active, 1, 1)
      {:ok, %{status: 200, headers: %{}, body: %{}}}
    end

    1..20
    |> Task.async_stream(fn _ -> Gateway.request(:rest, request, server: name) end,
      max_concurrency: 20,
      ordered: false
    )
    |> Stream.run()

    assert :counters.get(active, 2) == 1
    assert Gateway.snapshot(name).request_count == 20
  end
end

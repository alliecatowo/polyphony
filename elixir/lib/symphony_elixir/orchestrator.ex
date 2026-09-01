defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls tracker issues and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, ControlState, Delivery, DeliveryController, SlicePlanner, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.GitHub.DeliveryAdapter
  alias SymphonyElixir.GitHub.Issue, as: GitHubIssue
  alias SymphonyElixir.GitHub.Gateway, as: GitHubGateway

  @snapshot_cache_key {__MODULE__, :last_snapshot}
  alias SymphonyElixir.GitHub.Projection, as: GitHubProjection
  alias SymphonyElixir.Linear.Issue, as: LinearIssue
  @type tracker_issue :: GitHubIssue.t() | LinearIssue.t()

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @github_rate_limit_fallback_ms 60_000
  @github_rate_limit_max_backoff_ms 900_000
  # Webhooks and targeted refreshes reconcile delivery immediately. This is
  # only the safety sweep for parked PRs, so keep it aligned with the normal
  # tracker poll cadence instead of repeatedly spending GitHub API calls while
  # the queue is idle.
  @delivery_reconcile_interval_ms 900_000
  @delivery_reconcile_timeout_ms 45_000
  @targeted_refresh_timeout_ms 45_000
  @retry_lookup_timeout_ms 45_000
  # DeliveryController may need to invoke git or the provider while resuming a
  # parked delivery. Keep that work out of this GenServer and kill it if the
  # lower layer fails to return so scheduler control messages remain live.
  @provider_recovery_timeout_ms 45_000
  @stall_check_interval_ms 30_000
  # A poll may perform several bounded provider calls, but it must never be
  # able to wedge admission forever if a provider/client task disappears.
  @poll_cycle_timeout_ms 180_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @github_rate_limit_fallback_ms 60_000

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :poll_task_pid,
      :poll_task_ref,
      :poll_timeout_timer_ref,
      :stall_check_timer_ref,
      :tick_timer_ref,
      :tick_token,
      :control,
      :github_projection,
      :target_refresh_in_progress,
      :target_refresh_timer_ref,
      :target_refresh_task_pid,
      :target_refresh_task_ref,
      :target_refresh_timeout_timer_ref,
      :target_refresh_item,
      :delivery_reconcile_in_progress,
      :delivery_reconcile_timer_ref,
      :delivery_reconcile_task_pid,
      :delivery_reconcile_task_ref,
      :delivery_reconcile_cursor,
      :delivery_runtime_dir,
      provider_recovery_tasks: %{},
      delivery_reconcile_cycle_count: 0,
      running: %{},
      deliveries: %{},
      reservations: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      github_rate_limited_until_ms: nil,
      github_rate_limit_backoff_ms: @github_rate_limit_fallback_ms
    ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    deliveries =
      opts
      |> load_deliveries()
      |> recover_interrupted_deliveries(opts)

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      poll_task_pid: nil,
      poll_task_ref: nil,
      poll_timeout_timer_ref: nil,
      stall_check_timer_ref: nil,
      tick_timer_ref: nil,
      tick_token: nil,
      control: load_control_state(opts),
      github_projection: load_github_projection(opts),
      target_refresh_in_progress: false,
      target_refresh_timer_ref: nil,
      target_refresh_task_pid: nil,
      target_refresh_task_ref: nil,
      target_refresh_timeout_timer_ref: nil,
      target_refresh_item: nil,
      delivery_reconcile_in_progress: false,
      delivery_reconcile_timer_ref: nil,
      delivery_reconcile_task_pid: nil,
      delivery_reconcile_task_ref: nil,
      delivery_reconcile_cursor: nil,
      delivery_runtime_dir: delivery_runtime_dir(opts),
      provider_recovery_tasks: %{},
      delivery_reconcile_cycle_count: 0,
      deliveries: deliveries,
      claimed: pending_delivery_ids(deliveries),
      completed: completed_delivery_ids(deliveries),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      github_rate_limited_until_ms: nil,
      github_rate_limit_backoff_ms: @github_rate_limit_fallback_ms
    }

    start_terminal_workspace_cleanup(deliveries)

    state =
      state
      |> schedule_loaded_delivery_retries()
      |> refresh_control_obligations()
      |> schedule_tick(0)
      |> schedule_stall_check()
      |> schedule_delivery_reconcile(2_000)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    Logger.info("Starting orchestrator poll cycle")
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    orchestrator = self()
    base_running_entries = state.running

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           polled_state =
             try do
               maybe_dispatch(state, orchestrator)
             rescue
               exception ->
                 Logger.error("Poll cycle crashed: #{Exception.format(:error, exception, __STACKTRACE__)}")
                 state
             catch
               kind, reason ->
                 Logger.error("Poll cycle exited: #{inspect({kind, reason})}")
                 state
             end

           send(orchestrator, {:poll_cycle_complete, polled_state, base_running_entries})
         end) do
      {:ok, pid} ->
        poll_task_ref = Process.monitor(pid)
        poll_timeout_timer_ref = Process.send_after(self(), {:poll_cycle_timeout, poll_task_ref}, @poll_cycle_timeout_ms)

        {:noreply, %{state | poll_task_pid: pid, poll_task_ref: poll_task_ref, poll_timeout_timer_ref: poll_timeout_timer_ref}}

      {:error, reason} ->
        Logger.warning("Failed to start asynchronous poll cycle: #{inspect(reason)}")
        state = state |> schedule_tick(state.poll_interval_ms) |> Map.put(:poll_check_in_progress, false)
        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:poll_cycle_complete, %State{} = polled_state, base_running_ids}, state)
      when is_map(state) do
    Logger.info("Completed orchestrator poll cycle")

    state =
      state
      |> clear_poll_cycle_tracking()
      |> merge_poll_cycle_state(polled_state, base_running_ids)
      |> schedule_tick(poll_delay(polled_state))
      |> Map.put(:poll_check_in_progress, false)

    notify_dashboard()
    {:noreply, state}
  end

  # Compatibility for a poll task from an older code version during a
  # rolling restart. Current poll tasks include the base running set.
  def handle_info({:poll_cycle_complete, %State{} = polled_state}, state) do
    handle_info({:poll_cycle_complete, polled_state, %{}}, state)
  end

  def handle_info({:poll_cycle_timeout, poll_task_ref}, %State{poll_task_ref: poll_task_ref} = state)
      when is_reference(poll_task_ref) do
    Logger.error("Orchestrator poll cycle exceeded #{@poll_cycle_timeout_ms}ms; terminating it and scheduling recovery")

    if is_pid(state.poll_task_pid) and Process.alive?(state.poll_task_pid) do
      Process.exit(state.poll_task_pid, :kill)
    end

    state =
      state
      |> clear_poll_cycle_tracking()
      |> Map.put(:poll_check_in_progress, false)
      |> schedule_tick(state.poll_interval_ms)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:poll_cycle_timeout, _poll_task_ref}, state), do: {:noreply, state}

  def handle_info(:stall_check, %State{} = state) do
    state = %{state | stall_check_timer_ref: nil}

    state =
      state
      |> reconcile_dead_running_workers()
      |> reconcile_stalled_running_issues(self())
      |> refresh_control_obligations()
      |> schedule_stall_check()

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, poll_task_ref, :process, _pid, reason}, %State{poll_task_ref: poll_task_ref} = state)
      when is_reference(poll_task_ref) do
    Logger.error("Orchestrator poll cycle process exited before completion: #{inspect(reason)}")

    state =
      state
      |> clear_poll_cycle_tracking()
      |> Map.put(:poll_check_in_progress, false)
      |> schedule_tick(state.poll_interval_ms)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, %State{target_refresh_task_ref: task_ref} = state)
      when is_reference(task_ref) do
    # A supervised task can die without sending its result message. Release
    # the in-flight lease so one bad provider/client task cannot wedge the
    # targeted queue forever.
    item = state.target_refresh_item
    state = clear_target_refresh_tracking(state)
    provider_wait? = provider_wait_error?(reason) or github_gateway_open?()

    state =
      state
      |> requeue_targeted_item(item, {:target_refresh_task_exit, reason}, not provider_wait?)
      |> schedule_targeted_refresh(if(provider_wait?, do: provider_retry_delay(), else: targeted_failure_delay(item)))

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:targeted_refresh_timeout, task_ref}, %State{target_refresh_task_ref: task_ref} = state)
      when is_reference(task_ref) do
    Logger.warning("Targeted refresh task exceeded #{@targeted_refresh_timeout_ms}ms; terminating and requeueing")

    if is_pid(state.target_refresh_task_pid) and Process.alive?(state.target_refresh_task_pid) do
      Process.exit(state.target_refresh_task_pid, :kill)
    end

    item = state.target_refresh_item
    provider_wait? = github_gateway_open?()

    state =
      state
      |> clear_target_refresh_tracking()
      |> requeue_targeted_item(item, :targeted_refresh_timeout, not provider_wait?)
      |> schedule_targeted_refresh(if(provider_wait?, do: provider_retry_delay(), else: targeted_failure_delay(item)))

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:targeted_refresh_timeout, _task_ref}, state), do: {:noreply, state}

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, %State{delivery_reconcile_task_ref: task_ref} = state)
      when is_reference(task_ref) do
    Logger.warning("Delivery reconciliation task exited: #{inspect(reason)}")
    state = clear_delivery_reconcile_tracking(state)
    {:noreply, schedule_delivery_reconcile(state, if(github_gateway_open?(), do: provider_retry_delay(), else: @delivery_reconcile_interval_ms))}
  end

  def handle_info({task_ref, result}, %State{} = state) when is_reference(task_ref) do
    case find_provider_recovery_task(state.provider_recovery_tasks, task_ref) do
      {issue_id, _task} ->
        state = clear_provider_recovery_task(state, issue_id, task_ref)
        state = apply_provider_recovery_result(state, issue_id, result)
        notify_dashboard()
        {:noreply, schedule_delivery_reconcile(state, 0)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:provider_recovery_timeout, issue_id, task_ref}, %State{} = state)
      when is_binary(issue_id) and is_reference(task_ref) do
    case Map.get(state.provider_recovery_tasks, issue_id) do
      %{task_ref: ^task_ref} = task ->
        Logger.warning("Provider recovery exceeded #{@provider_recovery_timeout_ms}ms; terminating issue_id=#{issue_id}")

        if is_pid(task.pid) and Process.alive?(task.pid) do
          Process.exit(task.pid, :kill)
        end

        state =
          state
          |> clear_provider_recovery_task(issue_id, task_ref)
          |> schedule_provider_recovery_retry()

        notify_dashboard()
        {:noreply, schedule_delivery_reconcile(state, provider_retry_delay())}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, %State{} = state)
      when is_reference(task_ref) do
    case find_issue_id_for_ref(state.running, task_ref) do
      issue_id when is_binary(issue_id) ->
        handle_worker_down(state, task_ref, reason)

      nil ->
        handle_unmatched_down(state, task_ref, reason)
    end
  end

  defp handle_unmatched_down(%State{} = state, task_ref, reason) do
    case find_provider_recovery_task(state.provider_recovery_tasks, task_ref) do
      {issue_id, _task} ->
        Logger.warning("Provider recovery task exited before completion issue_id=#{issue_id}: #{inspect(reason)}")

        state =
          state
          |> clear_provider_recovery_task(issue_id, task_ref)
          |> schedule_provider_recovery_retry()

        notify_dashboard()
        {:noreply, schedule_delivery_reconcile(state, provider_retry_delay())}

      nil ->
        case find_retry_lookup(state.retry_attempts, task_ref) do
          {issue_id, retry_entry} ->
            provider_wait? = github_gateway_open?() or provider_wait_error?(reason)
            state = clear_retry_lookup_state(state, issue_id, retry_entry.attempt)
            metadata = retry_metadata(retry_entry)

            next_state =
              schedule_issue_retry(
                state,
                issue_id,
                if(provider_wait?, do: retry_entry.attempt, else: retry_entry.attempt + 1),
                Map.merge(metadata, %{
                  error: if(provider_wait?, do: metadata[:error], else: "retry lookup task exited: #{inspect(reason)}"),
                  delay_type: if(provider_wait?, do: :provider, else: :failure)
                })
              )

            notify_dashboard()
            {:noreply, next_state}

          nil ->
            {:noreply, state}
        end
    end
  end

  def handle_info(
        {:worker_started, issue_id, pid, issue, worker_host, slice_member_ids},
        %State{} = state
      )
      when is_binary(issue_id) and is_pid(pid) and is_map(issue) and is_list(slice_member_ids) do
    case Map.get(state.running, issue_id) do
      %{pid: ^pid} = running_entry ->
        # The asynchronous poll may have installed the entry before this
        # announcement reached the GenServer. Attach the monitor here; the
        # poll task must never own worker monitors.
        {ref, running_entry} = ensure_worker_monitor(running_entry, pid)
        running_entry = Map.merge(running_entry, %{ref: ref, worker_host: worker_host, issue: issue})

        next_state =
          clear_retry_schedule(state, issue_id)
          |> Map.put(:running, Map.put(state.running, issue_id, running_entry))
          |> refresh_control_obligations()

        notify_dashboard()
        {:noreply, next_state}

      nil ->
        case take_worker_reservation(state, issue_id) do
          {:ok, reservation, reservations} ->
            ref = Process.monitor(pid)
            reserved_slice_member_ids = Map.get(reservation, :slice_member_ids, slice_member_ids)

            entry =
              new_running_entry(
                pid,
                ref,
                issue,
                Map.get(reservation, :worker_host, worker_host),
                reserved_slice_member_ids,
                Map.get(reservation, :attempt)
              )

            next_state = clear_retry_schedule(state, issue_id)

            next_state = %{
              next_state
              | running: Map.put(next_state.running, issue_id, entry),
                reservations: reservations,
                claimed: Enum.reduce(reserved_slice_member_ids, next_state.claimed, &MapSet.put(&2, &1))
            }

            next_state = refresh_control_obligations(next_state)
            notify_dashboard()
            {:noreply, next_state}

          :none ->
            ref = Process.monitor(pid)
            entry = new_running_entry(pid, ref, issue, worker_host, slice_member_ids, nil)

            next_state = clear_retry_schedule(state, issue_id)

            next_state = %{
              next_state
              | running: Map.put(next_state.running, issue_id, entry),
                claimed: Enum.reduce(slice_member_ids, next_state.claimed, &MapSet.put(&2, &1))
            }

            next_state = refresh_control_obligations(next_state)
            notify_dashboard()
            {:noreply, next_state}
        end

      _other ->
        Logger.warning("Ignoring worker-start announcement for already-running issue_id=#{issue_id} pid=#{inspect(pid)}")
        {:noreply, state}
    end
  end

  def handle_info(
        {:worker_delivery_state, issue_id, %Delivery{} = delivery, _worker_host},
        %State{} = state
      )
      when is_binary(issue_id) do
    next_state =
      state
      |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, delivery))
      |> refresh_control_obligations()

    Logger.info("Delivery state updated for issue_id=#{issue_id} state=#{delivery.state} pr_number=#{inspect(delivery.pr_number)}")

    notify_dashboard()
    {:noreply, next_state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        handle_worker_down(state, ref, reason, issue_id)
    end
  end

  defp handle_worker_down(%State{} = state, ref, reason) do
    case find_issue_id_for_ref(state.running, ref) do
      issue_id when is_binary(issue_id) -> handle_worker_down(state, ref, reason, issue_id)
      nil -> {:noreply, state}
    end
  end

  defp handle_worker_down(%State{} = state, _ref, reason, issue_id) do
    {running_entry, state} = pop_running_entry(state, issue_id)
    state = release_running_claims(state, running_entry)
    state = record_session_completion_totals(state, running_entry)
    session_id = running_entry_session_id(running_entry)
    delivery = Map.get(state.deliveries, issue_id)
    state = if nonterminal_delivery?(delivery), do: claim_issue(state, issue_id), else: state

    state =
      case {reason, delivery} do
        {:normal, %Delivery{state: delivery_state}}
        when delivery_state in [:waiting_ci, :waiting_merge, :waiting_provider, :complete] ->
          Logger.info(
            "Agent task parked with harness-owned delivery for issue_id=#{issue_id} " <>
              "session_id=#{session_id} delivery_state=#{delivery_state}"
          )

          complete_issue(state, issue_id)

        {_reason, %Delivery{state: :retry_ready} = retry_delivery} ->
          schedule_delivery_retry(state, issue_id, running_entry, retry_delivery)

        {_reason, %Delivery{state: :failed}} ->
          Logger.error(
            "Delivery permanently failed; refusing automatic retry for issue_id=#{issue_id} " <>
              "issue_identifier=#{running_entry.identifier}"
          )

          complete_issue(state, issue_id)

        {:normal, _delivery} ->
          Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

          state
          |> complete_issue(issue_id)
          |> schedule_issue_retry(issue_id, 1, %{
            identifier: running_entry.identifier,
            delay_type: :continuation,
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            resume_thread_id: Map.get(running_entry, :resume_thread_id),
            slice_metadata: slice_metadata_from_running(running_entry)
          })

        {_reason, _delivery} ->
          if Map.get(running_entry, :token_budget_exceeded, false) do
            token_retry_attempt =
              max(
                Map.get(running_entry, :retry_attempt, 0),
                delivery_retry_attempt(delivery)
              )

            if token_retry_attempt >= 1 do
              Logger.error(
                "Token budget exhausted twice; refusing another retry for " <>
                  "issue_id=#{issue_id} issue_identifier=#{running_entry.identifier}"
              )

              permanently_fail_token_exhausted_delivery(state, issue_id, delivery)
            else
              Logger.warning(
                "Token budget exhausted; scheduling one bounded model escalation " <>
                  "for issue_id=#{issue_id}"
              )

              schedule_issue_retry(state, issue_id, 1, %{
                identifier: running_entry.identifier,
                error: "worker exceeded #{Config.settings!().codex.max_total_tokens} tokens",
                failure_class: :code,
                failure_attempt: 2,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                resume_thread_id: Map.get(running_entry, :resume_thread_id),
                slice_metadata: slice_metadata_from_running(running_entry)
              })
            end
          else
            Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

            next_attempt = next_retry_attempt_from_running(running_entry)

            schedule_issue_retry(state, issue_id, next_attempt, %{
              identifier: running_entry.identifier,
              error: "agent exited: #{inspect(reason)}",
              worker_host: Map.get(running_entry, :worker_host),
              workspace_path: Map.get(running_entry, :workspace_path),
              resume_thread_id: Map.get(running_entry, :resume_thread_id),
              slice_metadata: slice_metadata_from_running(running_entry)
            })
          end
      end

    state = state |> refresh_control_obligations() |> schedule_targeted_refresh(0)

    Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:resume_thread_id, runtime_info[:resume_thread_id])

        next_state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
        notify_dashboard()
        {:noreply, next_state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        updated_running_entry = maybe_stop_token_exhausted_worker(updated_running_entry, issue_id)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  defp maybe_stop_token_exhausted_worker(%{} = running_entry, issue_id) do
    limit = Config.settings!().codex.max_total_tokens
    total_tokens = Map.get(running_entry, :codex_total_tokens, 0)

    if is_integer(limit) and limit > 0 and total_tokens >= limit and
         not Map.get(running_entry, :token_budget_exceeded, false) do
      Logger.warning(
        "Stopping worker at token budget issue_id=#{issue_id} " <>
          "total_tokens=#{total_tokens} limit=#{limit}"
      )

      running_entry = Map.put(running_entry, :token_budget_exceeded, true)

      case Map.get(running_entry, :pid) do
        pid when is_pid(pid) -> terminate_task(pid)
        _ -> :ok
      end

      running_entry
    else
      running_entry
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    case Map.get(state.deliveries, issue_id) do
      %Delivery{} = delivery when delivery.state in [:complete, :cancelled] ->
        Logger.info("Dropping stale retry for delivered issue_id=#{issue_id} state=#{delivery.state}")
        {:noreply, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        if control_admits?(state, :retry) do
          handle_retry_timer(issue_id, retry_token, state)
        else
          {:noreply, defer_retry_for_control(state, issue_id, retry_token)}
        end
    end
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(:complete_control_recovery, %State{} = state) do
    case ControlState.complete_recovery(state.control, reconciled?: true) do
      {:ok, next_control} ->
        state = state |> Map.put(:control, next_control) |> persist_control_state()

        state =
          if ControlState.admit?(next_control, :worker) do
            Enum.each(state.retry_attempts, fn
              {issue_id, %{retry_token: retry_token}} when is_reference(retry_token) ->
                send(self(), {:retry_issue, issue_id, retry_token})

              _ ->
                :ok
            end)

            state |> schedule_tick(0) |> schedule_targeted_refresh(0) |> schedule_delivery_reconcile(0)
          else
            state
          end

        notify_dashboard()
        {:noreply, state}

      {:error, :not_recovering} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Control recovery could not complete: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:retry_issue_lookup, issue_id, attempt, metadata, {:ok, issues}}, state) do
    state = clear_retry_lookup_state(state, issue_id, attempt)

    next_state =
      issues
      |> find_issue_by_id(issue_id)
      |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

    notify_dashboard()
    next_state
  end

  def handle_info({:retry_issue_lookup, issue_id, attempt, metadata, {:error, reason}}, state) do
    provider_wait? = provider_wait_error?(reason)

    if provider_wait? do
      Logger.debug("Retry poll parked for provider wait issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}")
    else
      Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")
    end

    next_state =
      state
      |> clear_retry_lookup_state(issue_id, attempt)
      |> schedule_issue_retry(
        issue_id,
        if(provider_wait?, do: attempt, else: attempt + 1),
        Map.merge(metadata, %{
          error: "retry poll failed: #{inspect(reason)}",
          delay_type: if(provider_wait?, do: :provider, else: :failure)
        })
      )

    notify_dashboard()
    {:noreply, next_state}
  end

  def handle_info({:retry_lookup_timeout, issue_id, attempt, task_ref}, %State{} = state)
      when is_binary(issue_id) and is_integer(attempt) and is_reference(task_ref) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: ^attempt, lookup_task_ref: ^task_ref} = retry_entry ->
        Logger.warning("Retry lookup exceeded #{@retry_lookup_timeout_ms}ms; terminating issue_id=#{issue_id}")

        if is_pid(retry_entry.lookup_task_pid) and Process.alive?(retry_entry.lookup_task_pid) do
          Process.exit(retry_entry.lookup_task_pid, :kill)
        end

        provider_wait? = github_gateway_open?()
        metadata = retry_metadata(retry_entry)

        next_state =
          state
          |> clear_retry_lookup_state(issue_id, attempt)
          |> schedule_issue_retry(
            issue_id,
            if(provider_wait?, do: attempt, else: attempt + 1),
            Map.merge(metadata, %{
              error: if(provider_wait?, do: metadata[:error], else: "retry lookup timed out"),
              delay_type: if(provider_wait?, do: :provider, else: :failure)
            })
          )

        notify_dashboard()
        {:noreply, next_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:process_targeted_refresh, %State{} = state) do
    state = %{state | target_refresh_timer_ref: nil}

    cond do
      state.target_refresh_in_progress == true ->
        {:noreply, state}

      not control_admits?(state, :worker) or available_slots(state) == 0 ->
        {:noreply, state}

      GitHubGateway.snapshot().circuit == :open ->
        {:noreply, schedule_targeted_refresh(state, provider_retry_delay())}

      true ->
        {item, projection} = GitHubProjection.pop(state.github_projection)
        state = %{state | github_projection: projection} |> persist_github_projection()

        case targeted_issue_node_id(item) do
          nil ->
            state = acknowledge_targeted_item(state, item, %{reason: :missing_node_id})
            {:noreply, schedule_targeted_refresh(state, 0)}

          issue_id ->
            owner = self()

            case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
                   result =
                     try do
                       Tracker.fetch_issue_states_by_ids([issue_id])
                     rescue
                       exception -> {:error, {:exception, exception, __STACKTRACE__}}
                     catch
                       kind, reason -> {:error, {kind, reason}}
                     end

                   send(owner, {:targeted_refresh_result, item, result})
                 end) do
              {:ok, pid} ->
                task_ref = Process.monitor(pid)
                timeout_timer_ref = Process.send_after(self(), {:targeted_refresh_timeout, task_ref}, @targeted_refresh_timeout_ms)

                {:noreply,
                 %{
                   state
                   | target_refresh_in_progress: true,
                     target_refresh_task_pid: pid,
                     target_refresh_task_ref: task_ref,
                     target_refresh_timeout_timer_ref: timeout_timer_ref,
                     target_refresh_item: item
                 }}

              {:error, reason} ->
                state = requeue_targeted_item(state, item, reason, true)
                {:noreply, schedule_targeted_refresh(state, targeted_failure_delay(item))}
            end
        end
    end
  end

  def handle_info({:targeted_refresh_result, item, {:ok, issues}}, %State{} = state) do
    state = clear_target_refresh_tracking(state)

    case targeted_dispatch_issue(issues, state) do
      nil ->
        state =
          state
          |> acknowledge_targeted_item(item, %{reason: :not_dispatchable})
          |> Map.put(:target_refresh_in_progress, false)
          |> schedule_targeted_refresh(0)

        notify_dashboard()
        {:noreply, state}

      issue ->
        start_targeted_dispatch(state, item, issue)
    end
  end

  def handle_info({:targeted_refresh_result, item, {:error, reason}}, %State{} = state) do
    provider_wait? = provider_wait_error?(reason)

    state =
      state
      |> clear_target_refresh_tracking()
      |> requeue_targeted_item(item, reason, not provider_wait?)
      |> schedule_targeted_refresh(if(provider_wait?, do: provider_retry_delay(), else: targeted_failure_delay(item)))

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:targeted_dispatch_complete, item, %State{} = dispatched_state, base_running},
        %State{} = state
      ) do
    state =
      state
      |> merge_poll_cycle_state(dispatched_state, base_running)
      |> acknowledge_targeted_item(item, %{reason: :dispatch_evaluated})
      |> clear_target_refresh_tracking()
      |> schedule_targeted_refresh(0)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:targeted_dispatch_failed, item, reason}, %State{} = state) do
    state =
      state
      |> requeue_targeted_item(item, reason, true)
      |> clear_target_refresh_tracking()
      |> schedule_targeted_refresh(targeted_failure_delay(item))

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(:reconcile_deliveries, %State{} = state) do
    Logger.debug("Reconciling parked deliveries count=#{map_size(state.deliveries)}")
    state = %{state | delivery_reconcile_timer_ref: nil}

    cond do
      state.delivery_reconcile_in_progress == true ->
        {:noreply, state}

      GitHubGateway.snapshot().circuit == :open ->
        {:noreply, schedule_delivery_reconcile(state, provider_retry_delay())}

      true ->
        state = resume_provider_waits(state)

        case next_reconcilable_delivery(state.deliveries, state.delivery_reconcile_cursor) do
          nil ->
            {:noreply, schedule_delivery_reconcile(state, @delivery_reconcile_interval_ms)}

          {issue_id, delivery} ->
            owner = self()
            Logger.debug("Starting delivery reconciliation issue_id=#{issue_id} pr=#{delivery.pr_number}")

            case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
                   Logger.debug("Delivery reconciliation worker started issue_id=#{issue_id}")

                   result_task =
                     Task.async(fn ->
                       try do
                         result =
                           DeliveryAdapter.inspect_pull_request(%{
                             pr_number: delivery.pr_number,
                             commit_sha: delivery.commit_sha
                           })

                         result
                       rescue
                         exception -> {:error, {:delivery_reconcile_exception, exception, __STACKTRACE__}}
                       catch
                         kind, reason -> {:error, {:delivery_reconcile_throw, kind, reason}}
                       end
                     end)

                   result =
                     case Task.yield(result_task, @delivery_reconcile_timeout_ms) ||
                            Task.shutdown(result_task, :brutal_kill) do
                       {:ok, value} -> value
                       nil -> {:error, :delivery_reconcile_timeout}
                       {:exit, reason} -> {:error, {:delivery_reconcile_exit, reason}}
                     end

                   send(owner, {:delivery_reconcile_result, issue_id, result})
                 end) do
              {:ok, pid} ->
                task_ref = Process.monitor(pid)
                timeout_ref = Process.send_after(self(), {:delivery_reconcile_timeout, task_ref}, @delivery_reconcile_timeout_ms)

                {:noreply,
                 %{
                   state
                   | delivery_reconcile_in_progress: true,
                     delivery_reconcile_task_pid: pid,
                     delivery_reconcile_task_ref: task_ref,
                     delivery_reconcile_timer_ref: timeout_ref
                 }}

              {:error, reason} ->
                Logger.warning("Unable to start delivery reconciliation for issue_id=#{issue_id}: #{inspect(reason)}")
                {:noreply, schedule_delivery_reconcile(state, @delivery_reconcile_interval_ms)}
            end
        end
    end
  end

  def handle_info({:delivery_reconcile_timeout, task_ref}, %State{delivery_reconcile_task_ref: task_ref} = state)
      when is_reference(task_ref) do
    Logger.warning("Delivery reconciliation exceeded #{@delivery_reconcile_timeout_ms}ms; terminating task")

    if is_pid(state.delivery_reconcile_task_pid) and Process.alive?(state.delivery_reconcile_task_pid) do
      Process.exit(state.delivery_reconcile_task_pid, :kill)
    end

    state = clear_delivery_reconcile_tracking(state)
    {:noreply, schedule_delivery_reconcile(state, provider_retry_delay())}
  end

  def handle_info({:delivery_reconcile_timeout, _task_ref}, state), do: {:noreply, state}

  # A delivery parked for provider recovery has no pull request to reconcile.
  # Once the gateway's circuit is closed, apply the durable provider-available
  # event locally. The delivery's transition is idempotent because this filter
  # only selects the waiting state, and the transition itself preserves its
  # attempt counter and all orchestrator claims.
  def handle_info(:provider_available, %State{} = state) do
    state = resume_provider_waits(state, true)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(:provider_recovered, %State{} = state) do
    handle_info(:provider_available, state)
  end

  def handle_info({:delivery_reconcile_result, issue_id, {:ok, summary}}, %State{} = state) do
    state = clear_delivery_reconcile_tracking(state)

    state =
      case Map.get(state.deliveries, issue_id) do
        %Delivery{} = delivery -> apply_delivery_reconcile(state, issue_id, delivery, summary)
        _ -> state
      end

    notify_dashboard()
    {:noreply, advance_delivery_reconcile(state, issue_id)}
  end

  def handle_info({:delivery_reconcile_result, issue_id, {:error, reason}}, %State{} = state) do
    Logger.warning("Delivery reconciliation failed for issue_id=#{issue_id}: #{inspect(reason)}")
    state = clear_delivery_reconcile_tracking(state)

    if provider_wait_error?(reason) do
      {:noreply, schedule_delivery_reconcile(state, provider_retry_delay())}
    else
      {:noreply, advance_delivery_reconcile(state, issue_id)}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state, orchestrator) when is_pid(orchestrator) do
    cond do
      not control_admits?(state, :worker) ->
        Logger.debug("Control state #{state.control && state.control.state} blocks new worker admission")
        state

      github_gateway_open?() ->
        Logger.debug("GitHub provider circuit open; parking tracker poll")
        state

      github_rate_limited?(state) ->
        Logger.warning("GitHub API circuit open; skipping tracker poll until #{state.github_rate_limited_until_ms}")
        state

      true ->
        state = reconcile_running_issues(state, orchestrator)

        with :ok <- Config.validate!(),
             {:ok, issues} <- Tracker.fetch_candidate_issues(),
             :ok <- log_candidate_count(issues),
             true <- available_slots(state) > 0 do
          choose_issues(issues, clear_github_rate_limit(state), orchestrator)
        else
          {:error, :missing_linear_api_token} ->
            Logger.error("Linear API token missing in WORKFLOW.md")
            state

          {:error, :missing_linear_project_slug} ->
            Logger.error("Linear project slug missing in WORKFLOW.md")
            state

          {:error, :missing_github_api_token} ->
            Logger.error("GitHub API token missing in WORKFLOW.md")
            state

          {:error, :missing_github_repo_owner} ->
            Logger.error("GitHub repo owner missing in WORKFLOW.md")
            state

          {:error, :missing_github_repo_name} ->
            Logger.error("GitHub repo name missing in WORKFLOW.md")
            state

          {:error, :missing_tracker_kind} ->
            Logger.error("Tracker kind missing in WORKFLOW.md")

            state

          {:error, {:unsupported_tracker_kind, kind}} ->
            Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

            state

          {:error, {:invalid_workflow_config, message}} ->
            Logger.error("Invalid WORKFLOW.md config: #{message}")
            state

          {:error, {:missing_workflow_file, path, reason}} ->
            Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
            state

          {:error, :workflow_front_matter_not_a_map} ->
            Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
            state

          {:error, {:workflow_parse_error, reason}} ->
            Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
            state

          {:error, reason} ->
            if github_rate_limit_error?(reason) do
              mark_github_rate_limited(state, reason)
            else
              Logger.error("Failed to fetch tracker candidates: #{inspect(reason)}")
              state
            end

          false ->
            state
        end
    end
  end

  defp log_candidate_count(issues) when is_list(issues) do
    Logger.info("Tracker candidate fetch returned #{length(issues)} dispatchable issues")
    :ok
  end

  defp log_candidate_count(_issues), do: :ok

  defp reconcile_running_issues(%State{} = state, owner) when is_pid(owner) do
    state = reconcile_stalled_running_issues(state, owner)
    running_ids = Map.keys(state.running)

    if running_ids == [] or github_gateway_open?() do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([tracker_issue()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    running_ids = Map.keys(state.running)

    state = reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
    reconcile_missing_running_issue_ids(state, running_ids, issues)
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(tracker_issue(), term()) :: boolean()
  def should_dispatch_issue_for_test(%{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(tracker_issue(), ([String.t()] -> term())) ::
          {:ok, tracker_issue()} | {:skip, tracker_issue() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([tracker_issue()]) :: [tracker_issue()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec worker_hosts_for_issue_for_test(map(), integer() | nil) :: [String.t()]
  def worker_hosts_for_issue_for_test(issue, attempt), do: Config.worker_hosts_for_issue(issue, attempt)

  @doc false
  @spec reconcile_issue_primitives_for_test(map()) :: :ok | {:error, term()}
  def reconcile_issue_primitives_for_test(%{} = issue) do
    reconcile_issue_primitives(issue)
  end

  @doc false
  @spec merge_poll_cycle_state_for_test(State.t(), State.t(), MapSet.t()) :: State.t()
  def merge_poll_cycle_state_for_test(%State{} = current, %State{} = polled, base_running_ids) do
    merge_poll_cycle_state(current, polled, base_running_ids)
  end

  @doc false
  @spec apply_orchestrator_tracker_writes_for_test(map(), map()) :: :ok | {:error, term()}
  def apply_orchestrator_tracker_writes_for_test(%{} = issue, %{} = writes) do
    issue
    |> put_in([:tracker_metadata, "orchestrator_tracker_writes"], writes)
    |> apply_orchestrator_tracker_writes()
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      dispatch_active_issue_state?(issue, issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = release_running_claims(state, running_entry)
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state, owner) when is_pid(owner) do
    timeout_ms =
      case Config.settings() do
        {:ok, config} ->
          config.codex.stall_timeout_ms

        {:error, reason} ->
          Logger.error("Ignoring invalid runtime configuration during stall check: #{inspect(reason)}")
          0
      end

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms, owner)
        end)
    end
  end

  # A worker can exit before its monitor is installed (the worker-start
  # announcement and the process exit are delivered independently).  In that
  # race the normal DOWN handler never receives a matching monitor event and
  # the dashboard can retain a phantom running entry indefinitely.  Re-emit a
  # synthetic DOWN for dead pids so the single normal cleanup path releases
  # claims, records delivery state, and schedules any required retry.
  defp reconcile_dead_running_workers(%State{} = state) do
    Enum.each(state.running, fn
      {issue_id, %{pid: pid, ref: ref}} when is_pid(pid) and is_reference(ref) ->
        unless Process.alive?(pid) do
          Logger.warning(
            "Detected dead worker without cleanup issue_id=#{issue_id} " <>
              "pid=#{inspect(pid)}; scheduling DOWN reconciliation"
          )

          send(self(), {:DOWN, ref, :process, pid, :noproc})
        end

      _ ->
        :ok
    end)

    state
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms, owner) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(
        issue_id,
        next_attempt,
        %{
          identifier: identifier,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        },
        owner
      )
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state, orchestrator) when is_pid(orchestrator) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    planned_slices = SlicePlanner.plan(issues)

    Logger.info("Dispatch evaluation: issues=#{length(issues)} slices=#{length(planned_slices)} candidates=#{Enum.count(issues, &candidate_issue?(&1, active_states, terminal_states))}")

    planned_slices
    |> Enum.reduce(state, fn %{leader: issue}, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue, nil, nil, board_context(issues), orchestrator)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    delivery = Map.get(state.deliveries, issue.id)

    # A terminal delivery is authoritative: a merged/failed issue must not
    # be redispatched merely because its tracker status is still active.
    control_admits?(state, :worker) and
      candidate_issue?(issue, active_states, terminal_states) and
      !active_issue_blocked_by_non_terminal?(issue, active_states, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Delivery.terminal?(delivery && delivery.state) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      dispatch_active_issue_state?(issue, state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp dispatch_active_issue_state?(_issue, state_name, active_states) do
    active_issue_state?(state_name, active_states)
  end

  defp active_issue_blocked_by_non_terminal?(
         %{state: issue_state, blocked_by: blockers},
         active_states,
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    active_issue_state?(issue_state, active_states) and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp active_issue_blocked_by_non_terminal?(_issue, _active_states, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp board_context(issues) when is_list(issues) do
    issues
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(fn issue -> {priority_rank(Map.get(issue, :priority)), issue_created_at_sort_key(issue)} end)
    |> Enum.take(24)
    |> Enum.map_join("\n", fn issue ->
      fields =
        issue
        |> Map.get(:tracker_metadata, %{})
        |> Map.get("project_fields", %{})

      area = get_in(fields, ["area", "name"]) || "unclassified"
      kind = get_in(fields, ["kind", "name"]) || "unclassified"
      priority = priority_label(Map.get(issue, :priority))
      blockers = issue |> Map.get(:blocked_by, []) |> Enum.map(&Map.get(&1, :identifier, "?")) |> Enum.join(",")

      "- #{issue.identifier || issue.id}: [#{priority}] [#{area}/#{kind}] #{issue.title}#{if blockers != "", do: " (blocked by #{blockers})", else: ""}"
    end)
  end

  defp board_context(_issues), do: ""

  defp priority_label(1), do: "P0"
  defp priority_label(2), do: "P1"
  defp priority_label(3), do: "P2"
  defp priority_label(4), do: "P3"
  defp priority_label(_), do: "unprioritized"

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host),
    do: dispatch_issue(state, issue, attempt, preferred_worker_host, nil)

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, board_context) do
    dispatch_issue(state, issue, attempt, preferred_worker_host, board_context, self())
  end

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, board_context, orchestrator)
       when is_pid(orchestrator) do
    if github_gateway_open?() do
      Logger.debug("GitHub provider circuit open; parking dispatch revalidation for #{issue_context(issue)}")
      state
    else
      case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
        {:ok, %{} = refreshed_issue} ->
          refreshed_issue = preserve_slice_metadata(issue, refreshed_issue)

          refreshed_issue
          |> reconcile_tracker_primitives_for_dispatch()
          |> then(fn reconciled_issue ->
            do_dispatch_issue(state, reconciled_issue, attempt, preferred_worker_host, board_context, orchestrator)
          end)

        {:skip, :missing} ->
          Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
          state

        {:skip, %{} = refreshed_issue} ->
          Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

          state

        {:error, reason} ->
          Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
          state
      end
    end
  end

  # A persisted delivery retry has already crossed the new-work admission
  # boundary and was refreshed immediately before this call. It must still
  # stop for a terminal issue, but a missing project Status cannot strand an
  # existing PR in CI forever.
  defp dispatch_delivery_retry(%State{} = state, issue, attempt, preferred_worker_host) do
    issue
    |> reconcile_tracker_primitives_for_dispatch()
    |> then(fn reconciled_issue ->
      do_dispatch_issue(state, reconciled_issue, attempt, preferred_worker_host, nil, self())
    end)
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, board_context, orchestrator)
       when is_pid(orchestrator) do
    issue =
      issue
      |> issue_with_desired_project_custom_fields()
      |> issue_with_desired_primitive_overrides()

    with :ok <- apply_orchestrator_tracker_writes(issue),
         :ok <- reconcile_issue_primitives(issue) do
      dispatch_on_selected_worker_host(state, issue, attempt, orchestrator, preferred_worker_host, board_context)
    else
      {:error, reason} ->
        Logger.warning("Tracker write/reconciliation failed for #{issue_context(issue)}: #{inspect(reason)}; continuing dispatch")
        dispatch_on_selected_worker_host(state, issue, attempt, orchestrator, preferred_worker_host, board_context)
    end
  end

  defp issue_with_desired_project_custom_fields(%{tracker_metadata: tracker_metadata} = issue)
       when is_map(tracker_metadata) do
    has_explicit_desired_fields? =
      is_map(Map.get(tracker_metadata, "project_desired_fields")) or
        is_map(Map.get(tracker_metadata, :project_desired_fields))

    if has_explicit_desired_fields? do
      issue
    else
      desired_fields = build_policy_desired_project_custom_fields(issue)

      if desired_fields == %{} do
        issue
      else
        updated_metadata = Map.put(tracker_metadata, "project_desired_fields", desired_fields)
        Map.put(issue, :tracker_metadata, updated_metadata)
      end
    end
  end

  defp issue_with_desired_project_custom_fields(issue), do: issue

  defp issue_with_desired_primitive_overrides(%{tracker_metadata: tracker_metadata} = issue)
       when is_map(tracker_metadata) do
    tracker_metadata
    |> put_default_desired_milestone_override()
    |> put_default_desired_assignees_override(issue)
    |> then(&Map.put(issue, :tracker_metadata, &1))
  end

  defp issue_with_desired_primitive_overrides(issue), do: issue

  defp put_default_desired_milestone_override(tracker_metadata) when is_map(tracker_metadata) do
    has_override? =
      not is_nil(Map.get(tracker_metadata, "project_desired_milestone")) or
        not is_nil(Map.get(tracker_metadata, :project_desired_milestone))

    milestone_number =
      get_in(tracker_metadata, ["milestone", "number"]) ||
        get_in(tracker_metadata, [:milestone, :number])

    cond do
      has_override? ->
        tracker_metadata

      is_integer(milestone_number) and milestone_number > 0 ->
        Map.put(tracker_metadata, "project_desired_milestone", milestone_number)

      true ->
        tracker_metadata
    end
  end

  defp put_default_desired_assignees_override(tracker_metadata, issue)
       when is_map(tracker_metadata) and is_map(issue) do
    has_override? =
      is_list(Map.get(tracker_metadata, "project_desired_assignees")) or
        is_list(Map.get(tracker_metadata, :project_desired_assignees)) or
        is_binary(Map.get(tracker_metadata, "project_desired_assignees")) or
        is_binary(Map.get(tracker_metadata, :project_desired_assignees))

    case Map.get(issue, :assignee_id) do
      assignee_id when is_binary(assignee_id) and assignee_id != "" and not has_override? ->
        Map.put(tracker_metadata, "project_desired_assignees", [assignee_id])

      _ ->
        tracker_metadata
    end
  end

  # Conservative policy: derive only low-risk defaults from current issue/metadata,
  # and only when a GitHub project item context exists.
  defp build_policy_desired_project_custom_fields(%{tracker_metadata: tracker_metadata} = issue)
       when is_map(tracker_metadata) do
    project_items = Map.get(tracker_metadata, "project_items", [])

    if is_list(project_items) and project_items != [] do
      %{}
      |> maybe_put_points_default(issue)
      |> maybe_put_progress_default(issue)
    else
      %{}
    end
  end

  defp build_policy_desired_project_custom_fields(_issue), do: %{}

  defp maybe_put_points_default(fields, %{priority: priority}) when is_integer(priority) do
    points =
      case priority do
        1 -> 8
        2 -> 5
        3 -> 3
        4 -> 1
        _ -> nil
      end

    if is_integer(points), do: Map.put(fields, "Points", %{"number" => points}), else: fields
  end

  defp maybe_put_points_default(fields, _issue), do: fields

  defp maybe_put_progress_default(fields, %{state: state_name}) when is_binary(state_name) do
    normalized = String.downcase(String.trim(state_name))

    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> MapSet.new()

    active_states =
      Config.settings!().tracker.active_states
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> MapSet.new()

    progress =
      cond do
        MapSet.member?(terminal_states, normalized) -> 100
        MapSet.member?(active_states, normalized) -> 0
        true -> nil
      end

    if is_integer(progress) do
      Map.put(fields, "Progress", %{"number" => progress})
    else
      fields
    end
  end

  defp maybe_put_progress_default(fields, _issue), do: fields

  defp dispatch_on_selected_worker_host(%State{} = state, issue, attempt, recipient, preferred_worker_host, board_context) do
    candidate_hosts = Config.worker_hosts_for_issue(issue, attempt)

    case select_worker_host(state, preferred_worker_host, candidate_hosts) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, board_context)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, board_context) do
    slice_member_ids = SlicePlanner.slice_member_ids(issue)

    case reserve_worker_slot_on_owner(recipient, issue, worker_host, slice_member_ids, attempt) do
      {:ok, reservation_token} ->
        case start_agent_child(issue, recipient, attempt, worker_host, board_context) do
          {:ok, pid} ->
            send(recipient, {:worker_started, issue.id, pid, issue, worker_host, slice_member_ids})

            Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

            # The owner GenServer has already recorded the reservation. The
            # existing worker_started message remains the authority that
            # promotes it to running, so this copied state must not invent a
            # second worker entry.
            Map.put(state, :retry_attempts, Map.delete(state.retry_attempts, issue.id))

          {:error, reason} ->
            release_worker_reservation_on_owner(recipient, reservation_token)
            Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
            next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

            schedule_issue_retry(
              state,
              issue.id,
              next_attempt,
              %{
                identifier: issue.identifier,
                error: "failed to spawn agent: #{inspect(reason)}",
                worker_host: worker_host
              },
              recipient
            )
        end

      {:error, :admission_closed} ->
        Logger.info("Control state closed worker admission before dispatch: #{issue_context(issue)}")
        state

      {:error, :no_worker_capacity} ->
        Logger.debug("Owner rejected worker reservation for #{issue_context(issue)}: no capacity")
        state

      {:error, :issue_claimed} ->
        Logger.debug("Owner rejected worker reservation for #{issue_context(issue)}: issue or slice already claimed")
        state

      {:error, reason} ->
        Logger.warning("Owner rejected worker reservation for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp start_agent_child(issue, recipient, attempt, worker_host, board_context) do
    try do
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        AgentRunner.run(issue, recipient,
          attempt: attempt,
          worker_host: worker_host,
          board_context: board_context
        )
      end)
    rescue
      exception -> {:error, {:exception, exception, __STACKTRACE__}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp revalidate_issue_for_dispatch(%{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp reconcile_tracker_primitives_for_dispatch(%{} = issue) do
    case Tracker.reconcile_issue_primitives(issue) do
      :ok ->
        issue

      {:error, reason} ->
        Logger.warning("Continuing without tracker primitive reconciliation for #{issue_context(issue)}: #{inspect(reason)}")

        issue
    end
  end

  defp reconcile_tracker_primitives_for_dispatch(issue), do: issue

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_delivery_retry(state, issue_id, running_entry, %Delivery{} = delivery) do
    retry_limit = Config.max_delivery_retry_attempts()

    if delivery_retry_budget_exhausted?(delivery, retry_limit) do
      reason = {:delivery_retry_budget_exhausted, retry_limit, delivery.failure_reason}

      case persist_permanent_delivery_failure(issue_id, delivery, reason) do
        {:ok, failed_delivery} ->
          Logger.error(
            "Delivery retry budget exhausted for issue_id=#{issue_id} " <>
              "issue_identifier=#{running_entry.identifier} attempts=#{delivery.attempt} limit=#{retry_limit}; " <>
              "parking for manual escalation"
          )

          state
          |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, failed_delivery))
          |> complete_issue(issue_id)

        {:error, persist_reason} ->
          Logger.error("Could not persist exhausted delivery for issue_id=#{issue_id}: #{inspect(persist_reason)}; refusing retry")

          complete_issue(state, issue_id)
      end
    else
      case mark_final_escalation_if_needed(issue_id, delivery, retry_limit) do
        {:ok, delivery} ->
          failure = List.first(delivery.failures) || %{}
          classification = Map.get(failure, :classification) || Map.get(failure, "classification")
          next_attempt = max(delivery.attempt, next_retry_attempt_from_running(running_entry))

          state
          |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, delivery))
          |> schedule_issue_retry(issue_id, next_attempt, %{
            identifier: running_entry.identifier,
            error: "delivery #{delivery.state}: #{inspect(delivery.failure_reason)}",
            delay_type: :failure,
            failure_class: classification,
            failure_attempt: delivery.attempt,
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            resume_thread_id: Map.get(running_entry, :resume_thread_id),
            slice_metadata: slice_metadata_from_running(running_entry)
          })

        {:error, reason} ->
          Logger.error("Could not persist final escalation for issue_id=#{issue_id}: #{inspect(reason)}; refusing retry")
          complete_issue(state, issue_id)
      end
    end
  end

  defp delivery_retry_attempt(%Delivery{attempt: attempt}) when is_integer(attempt) and attempt > 0,
    do: attempt

  defp delivery_retry_attempt(_delivery), do: 0

  defp permanently_fail_token_exhausted_delivery(state, issue_id, %Delivery{} = delivery) do
    reason = {:token_budget_exhausted, Config.settings!().codex.max_total_tokens}

    case persist_permanent_delivery_failure(issue_id, delivery, reason) do
      {:ok, failed_delivery} ->
        state
        |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, failed_delivery))
        |> complete_issue(issue_id)

      {:error, persist_reason} ->
        Logger.error(
          "Could not persist token-budget terminal failure for issue_id=#{issue_id}: #{inspect(persist_reason)}; " <>
            "retaining delivery state"
        )

        state
    end
  end

  defp delivery_retry_budget_exhausted?(%Delivery{} = delivery, retry_limit) do
    delivery.attempt > retry_limit and delivery.escalation > 0
  end

  defp mark_final_escalation_if_needed(issue_id, %Delivery{} = delivery, retry_limit) do
    if delivery.attempt >= retry_limit and delivery.escalation == 0 do
      persist_final_escalation(issue_id, delivery)
    else
      {:ok, delivery}
    end
  end

  defp persist_final_escalation(issue_id, %Delivery{} = delivery) do
    with {:ok, controller} <-
           DeliveryController.start_link(
             delivery_id: issue_id,
             delivery: delivery,
             runtime_dir: delivery_runtime_dir(),
             github_adapter: DeliveryAdapter
           ),
         {:ok, escalated_delivery} <-
           DeliveryController.handle_event(
             controller,
             %Delivery.Event.Escalated{classification: :code, reason: :final_sol_delivery_retry}
           ) do
      if Process.alive?(controller), do: GenServer.stop(controller)
      {:ok, escalated_delivery}
    else
      {:error, reason, _delivery} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_permanent_delivery_failure(issue_id, %Delivery{} = delivery, reason) do
    with {:ok, controller} <-
           DeliveryController.start_link(
             delivery_id: issue_id,
             delivery: delivery,
             runtime_dir: delivery_runtime_dir(),
             github_adapter: DeliveryAdapter
           ),
         {:ok, failed_delivery} <-
           DeliveryController.handle_event(controller, %Delivery.Event.PermanentFailure{reason: reason}) do
      if Process.alive?(controller), do: GenServer.stop(controller)
      {:ok, failed_delivery}
    else
      {:error, reason, _delivery} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preserve_slice_metadata(original, refreshed) when is_map(original) and is_map(refreshed) do
    original_metadata = Map.get(original, :tracker_metadata, %{})
    refreshed_metadata = Map.get(refreshed, :tracker_metadata, %{})

    slice_metadata =
      original_metadata
      |> Map.take(["slice_key", "slice_member_ids", "slice_members"])

    if slice_metadata == %{} do
      refreshed
    else
      Map.put(refreshed, :tracker_metadata, Map.merge(refreshed_metadata, slice_metadata))
    end
  end

  defp preserve_slice_metadata(_original, refreshed), do: refreshed

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata),
       do: schedule_issue_retry(state, issue_id, attempt, metadata, self())

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata, owner)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(owner, {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            delay_type: Map.get(metadata, :delay_type),
            worker_host: worker_host,
            workspace_path: workspace_path,
            resume_thread_id: Map.get(metadata, :resume_thread_id) || Map.get(previous_retry, :resume_thread_id),
            failure_class: Map.get(metadata, :failure_class) || Map.get(previous_retry, :failure_class),
            failure_attempt: Map.get(metadata, :failure_attempt) || Map.get(previous_retry, :failure_attempt),
            delivery_retry: Map.get(metadata, :delivery_retry, Map.get(previous_retry, :delivery_retry, false)),
            delivery_failure_reason: Map.get(metadata, :delivery_failure_reason) || Map.get(previous_retry, :delivery_failure_reason),
            slice_metadata: Map.get(metadata, :slice_metadata, %{})
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          delay_type: Map.get(retry_entry, :delay_type),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          resume_thread_id: Map.get(retry_entry, :resume_thread_id),
          failure_class: Map.get(retry_entry, :failure_class),
          failure_attempt: Map.get(retry_entry, :failure_attempt),
          delivery_retry: Map.get(retry_entry, :delivery_retry, false),
          delivery_failure_reason: Map.get(retry_entry, :delivery_failure_reason),
          slice_metadata: Map.get(retry_entry, :slice_metadata, %{})
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp retry_metadata(retry_entry) when is_map(retry_entry) do
    %{
      identifier: Map.get(retry_entry, :identifier),
      error: Map.get(retry_entry, :error),
      delay_type: Map.get(retry_entry, :delay_type),
      worker_host: Map.get(retry_entry, :worker_host),
      workspace_path: Map.get(retry_entry, :workspace_path),
      resume_thread_id: Map.get(retry_entry, :resume_thread_id),
      failure_class: Map.get(retry_entry, :failure_class),
      failure_attempt: Map.get(retry_entry, :failure_attempt),
      delivery_retry: Map.get(retry_entry, :delivery_retry, false),
      delivery_failure_reason: Map.get(retry_entry, :delivery_failure_reason),
      slice_metadata: Map.get(retry_entry, :slice_metadata, %{})
    }
  end

  defp find_retry_lookup(retry_attempts, task_ref) when is_map(retry_attempts) and is_reference(task_ref) do
    Enum.find_value(retry_attempts, fn
      {issue_id, %{lookup_task_ref: ^task_ref} = retry_entry} -> {issue_id, retry_entry}
      _ -> nil
    end)
  end

  defp find_retry_lookup(_retry_attempts, _task_ref), do: nil

  defp clear_retry_lookup_state(%State{} = state, issue_id, attempt) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: ^attempt, lookup_task_ref: task_ref} = retry_entry when is_reference(task_ref) ->
        if is_reference(Map.get(retry_entry, :lookup_timeout_timer_ref)) do
          Process.cancel_timer(retry_entry.lookup_timeout_timer_ref)
        end

        Process.demonitor(task_ref, [:flush])
        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

      _ ->
        state
    end
  end

  defp clear_retry_schedule(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      retry when is_map(retry) ->
        if is_reference(Map.get(retry, :timer_ref)), do: Process.cancel_timer(retry.timer_ref)
        if is_reference(Map.get(retry, :lookup_timeout_timer_ref)), do: Process.cancel_timer(retry.lookup_timeout_timer_ref)
        if is_reference(Map.get(retry, :lookup_task_ref)), do: Process.demonitor(retry.lookup_task_ref, [:flush])
        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

      _ ->
        state
    end
  end

  defp park_retry_for_provider(%State{} = state, issue_id, retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        schedule_issue_retry(state, issue_id, attempt, Map.put(retry_metadata(retry_entry), :delay_type, :provider))

      _ ->
        state
    end
  end

  defp handle_retry_issue_lookup(%{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    delivery_retry? =
      metadata[:delivery_retry] == true and
        match?(%Delivery{state: :retry_ready}, Map.get(state.deliveries, issue_id))

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) or delivery_retry? ->
        handle_active_retry(state, issue, attempt, Map.put(metadata, :delivery_retry, delivery_retry?))

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup(deliveries) do
    terminal_delivery_identifiers(deliveries)
    |> Kernel.++(fetch_terminal_issues_for_cleanup())
    |> Enum.uniq_by(& &1.identifier)
    |> Enum.each(fn
      %{identifier: identifier} when is_binary(identifier) ->
        cleanup_issue_workspace(identifier)

      _ ->
        :ok
    end)
  end

  defp start_terminal_workspace_cleanup(deliveries) when is_map(deliveries) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> run_terminal_workspace_cleanup(deliveries) end)

    :ok
  end

  defp terminal_delivery_identifiers(deliveries) when is_map(deliveries) do
    deliveries
    |> Enum.flat_map(fn
      {_issue_id, %Delivery{state: state, metadata: metadata}}
      when state in [:complete, :failed] and is_map(metadata) ->
        identifier = Map.get(metadata, "identifier") || Map.get(metadata, :identifier)

        if is_binary(identifier) and identifier != "" do
          [%{identifier: identifier}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp terminal_delivery_identifiers(_deliveries), do: []

  defp fetch_terminal_issues_for_cleanup do
    terminal_states =
      terminal_state_set()
      |> MapSet.to_list()

    case Tracker.fetch_issues_by_states(terminal_states) do
      {:ok, issues} when is_list(issues) ->
        issues

      {:ok, _} ->
        []

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
        []
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    issue = issue |> restore_slice_metadata(metadata) |> restore_retry_metadata(metadata)

    cond do
      not control_admits?(state, :retry) ->
        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt,
           Map.merge(metadata, %{identifier: issue.identifier, delay_type: :control})
         )}

      (retry_candidate_issue?(issue, terminal_state_set()) or metadata[:delivery_retry] == true) and
        dispatch_slots_available?(issue, state) and
          worker_slots_available?(state, metadata[:worker_host]) ->
        dispatched =
          if metadata[:delivery_retry] == true do
            dispatch_delivery_retry(state, issue, attempt, metadata[:worker_host])
          else
            dispatch_issue(state, issue, attempt, metadata[:worker_host])
          end

        {:noreply, dispatched}

      true ->
        Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "no available orchestrator slots"
           })
         )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp claim_issue(%State{} = state, issue_id) do
    %{state | claimed: MapSet.put(state.claimed, issue_id)}
  end

  defp nonterminal_delivery?(%Delivery{state: state}), do: not Delivery.terminal?(state)
  defp nonterminal_delivery?(_delivery), do: false

  defp release_running_claims(%State{} = state, %{slice_member_ids: member_ids}) when is_list(member_ids) do
    %{state | claimed: Enum.reduce(member_ids, state.claimed, &MapSet.delete(&2, &1))}
  end

  defp release_running_claims(%State{} = state, _running_entry), do: state

  defp slice_metadata_from_running(%{slice_member_ids: member_ids, issue: issue})
       when is_list(member_ids) and is_map(issue) do
    metadata = Map.get(issue, :tracker_metadata, %{})

    metadata
    |> Map.take(["slice_key", "slice_member_ids", "slice_members"])
    |> Map.put_new("slice_member_ids", member_ids)
  end

  defp slice_metadata_from_running(_running_entry), do: %{}

  defp restore_slice_metadata(issue, %{slice_metadata: metadata})
       when is_map(issue) and is_map(metadata) and metadata != %{} do
    current = Map.get(issue, :tracker_metadata, %{})
    Map.put(issue, :tracker_metadata, Map.merge(current, metadata))
  end

  defp restore_slice_metadata(issue, _metadata), do: issue

  defp restore_retry_metadata(issue, metadata) when is_map(issue) and is_map(metadata) do
    tracker_metadata =
      issue
      |> Map.get(:tracker_metadata, %{})
      |> maybe_put_runtime_value("resume_thread_id", Map.get(metadata, :resume_thread_id))
      |> maybe_put_runtime_value("failure_class", Map.get(metadata, :failure_class))
      |> maybe_put_runtime_value("failure_attempt", Map.get(metadata, :failure_attempt))
      |> maybe_put_runtime_value("delivery_failure_reason", Map.get(metadata, :delivery_failure_reason))

    Map.put(issue, :tracker_metadata, tracker_metadata)
  end

  defp restore_retry_metadata(issue, _metadata), do: issue

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case metadata[:delay_type] do
      :continuation when attempt == 1 -> @continuation_retry_delay_ms
      :provider -> provider_retry_delay()
      :control -> 900_000
      _ -> failure_retry_delay(attempt)
    end
  end

  defp provider_retry_delay do
    case GitHubGateway.snapshot() do
      %{retry_in_ms: retry_in_ms} when is_integer(retry_in_ms) and retry_in_ms > 0 -> retry_in_ms
      _ -> 300_000
    end
  end

  defp github_gateway_open? do
    case GitHubGateway.snapshot() do
      %{available?: true, circuit: :open} -> true
      _ -> false
    end
  end

  # Only typed transient failures may park the scheduler. In particular, do
  # not infer an outage from a GitHub API message: 4xx validation and
  # permission failures must consume the normal delivery retry path instead.
  defp provider_wait_error?({:github_rate_limited, _reset_at, _retry_in_ms}), do: true
  defp provider_wait_error?({:github_provider_unavailable, _details}), do: true
  defp provider_wait_error?({:provider_unavailable, reason}), do: provider_wait_error?(reason)
  defp provider_wait_error?({:github, reason}), do: provider_wait_error?(reason)
  defp provider_wait_error?({:error, reason}), do: provider_wait_error?(reason)

  defp provider_wait_error?(_reason), do: false

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp reconcile_issue_primitives(%{} = issue) do
    Tracker.reconcile_issue_primitives(issue)
  end

  defp reconcile_issue_primitives(_issue), do: :ok

  defp apply_orchestrator_tracker_writes(%{tracker_metadata: tracker_metadata} = issue)
       when is_map(tracker_metadata) do
    writes =
      Map.get(tracker_metadata, "orchestrator_tracker_writes") ||
        Map.get(tracker_metadata, :orchestrator_tracker_writes)

    if is_map(writes) and writes != %{} do
      Tracker.apply_orchestrator_tracker_writes(issue, writes)
    else
      :ok
    end
  end

  defp apply_orchestrator_tracker_writes(_issue), do: :ok

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host, Config.settings!().worker.ssh_hosts)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host, candidate_hosts) do
    case candidate_hosts do
      [] ->
        # An empty SSH host list is the normal local-worker configuration.
        # Keep the host value nil so Workspace/AgentRunner use the local
        # process path, but still account for it as a bounded worker slot.
        select_worker_host(state, preferred_worker_host, [nil])

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp running_worker_host_count(_running, nil), do: 0

  defp reserved_worker_host_count(reservations, worker_host)
       when is_map(reservations) and is_binary(worker_host) do
    Enum.count(reservations, fn
      {_token, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp reserved_worker_host_count(_reservations, nil), do: 0

  defp reserved_worker_host_count(_reservations, _worker_host), do: 0

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) +
          reserved_worker_host_count(state.reservations, worker_host) < limit

      _ ->
        true
    end
  end

  defp worker_host_slots_available?(%State{}, nil), do: true
  defp worker_host_slots_available?(_state, _worker_host), do: false

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp ensure_worker_monitor(%{ref: ref} = entry, _pid) when is_reference(ref), do: {ref, entry}

  defp ensure_worker_monitor(entry, pid) when is_map(entry) and is_pid(pid) do
    {Process.monitor(pid), entry}
  end

  defp new_running_entry(pid, ref, issue, worker_host, slice_member_ids, attempt) do
    %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: worker_host,
      workspace_path: nil,
      resume_thread_id: nil,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: normalize_retry_attempt(attempt),
      started_at: DateTime.utc_now(),
      slice_member_ids: slice_member_ids
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running) - map_size(state.reservations),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec request_targeted_refresh(map()) :: map() | :unavailable
  def request_targeted_refresh(targets), do: request_targeted_refresh(__MODULE__, targets)

  @spec request_targeted_refresh(GenServer.server(), map()) :: map() | :unavailable
  def request_targeted_refresh(server, targets) when is_map(targets) do
    if Process.whereis(server) do
      GenServer.call(server, {:request_targeted_refresh, targets})
    else
      :unavailable
    end
  end

  @spec control(atom(), map()) :: {:ok, map()} | {:error, term()} | :unavailable
  def control(command, params \\ %{}), do: control(__MODULE__, command, params)

  @spec control(GenServer.server(), atom(), map()) :: {:ok, map()} | {:error, term()} | :unavailable
  def control(server, command, params) when is_atom(command) and is_map(params) do
    if Process.whereis(server) do
      GenServer.call(server, {:control, command, params})
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec cached_snapshot() :: map() | nil
  def cached_snapshot do
    :persistent_term.get(@snapshot_cache_key, nil)
  end

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    gateway_snapshot = GitHubGateway.snapshot()

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    snapshot = %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       github_api:
         Map.merge(gateway_snapshot, %{
           rate_limited?: gateway_snapshot[:circuit] == :open or github_rate_limited?(state),
           retry_in_ms: gateway_snapshot[:retry_in_ms] || next_poll_in_ms(state.github_rate_limited_until_ms, now_ms)
         }),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       },
       control: control_snapshot(state),
       github_events:
         Map.merge(GitHubProjection.snapshot(state.github_projection), %{
           processing?: state.target_refresh_in_progress == true
         }),
       deliveries:
         Map.new(state.deliveries, fn {issue_id, delivery} ->
           {issue_id, Delivery.serialize(delivery)}
         end)
     }

    :persistent_term.put(@snapshot_cache_key, snapshot)
    {:reply, snapshot, state}
  end

  def handle_call({:control, command, params}, _from, %State{} = state)
      when is_atom(command) and is_map(params) do
    state = refresh_control_obligations(state)

    case apply_control_command(state, command, params) do
      {:ok, next_state, details} ->
        next_state = persist_control_state(next_state)
        notify_dashboard()
        {:reply, {:ok, Map.merge(control_snapshot(next_state), details)}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:worker_admission, _from, %State{} = state) do
    {:reply, control_admits?(state, :worker), state}
  end

  def handle_call(
        {:reserve_worker_slot, %{} = issue, worker_host, slice_member_ids, attempt},
        _from,
        %State{} = state
      )
      when is_list(slice_member_ids) do
    state = refresh_runtime_config(state)

    case reserve_worker_slot(state, issue, worker_host, slice_member_ids, attempt) do
      {:ok, token, next_state} ->
        next_state = refresh_control_obligations(next_state)
        notify_dashboard()
        {:reply, {:ok, token}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release_worker_reservation, token}, _from, %State{} = state) do
    {next_state, released?} = release_worker_reservation(state, token)
    next_state = if released?, do: refresh_control_obligations(next_state), else: next_state
    if released?, do: notify_dashboard()
    {:reply, :ok, next_state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)
    state = schedule_delivery_reconcile(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:request_targeted_refresh, targets}, _from, %State{} = state)
      when is_map(targets) do
    projection = GitHubProjection.ingest(state.github_projection, targets)

    state =
      state
      |> Map.put(:github_projection, projection)
      |> persist_github_projection()
      |> schedule_targeted_refresh(0)
      |> schedule_delivery_reconcile(0)

    snapshot = GitHubProjection.snapshot(projection)

    {:reply,
     %{
       queued: true,
       scope: :targeted,
       queue_size: snapshot.queue_size,
       pending_size: snapshot.pending_size
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp poll_delay(%State{} = state) do
    cond do
      github_gateway_open?() -> provider_retry_delay()
      is_integer(state.github_rate_limited_until_ms) -> max(0, state.github_rate_limited_until_ms - System.monotonic_time(:millisecond))
      true -> state.poll_interval_ms
    end
  end

  defp github_rate_limited?(%State{github_rate_limited_until_ms: until_ms})
       when is_integer(until_ms),
       do: until_ms > System.monotonic_time(:millisecond)

  defp github_rate_limited?(%State{}), do: false

  defp clear_github_rate_limit(%State{} = state) do
    %{state | github_rate_limited_until_ms: nil, github_rate_limit_backoff_ms: @github_rate_limit_fallback_ms}
  end

  defp mark_github_rate_limited(%State{} = state, reason) do
    backoff_ms = min(state.github_rate_limit_backoff_ms || @github_rate_limit_fallback_ms, @github_rate_limit_max_backoff_ms)
    until_ms = System.monotonic_time(:millisecond) + backoff_ms

    Logger.error("GitHub API rate limit detected; pausing tracker requests for #{backoff_ms}ms: #{inspect(reason)}")

    %{
      state
      | github_rate_limited_until_ms: until_ms,
        github_rate_limit_backoff_ms: min(backoff_ms * 2, @github_rate_limit_max_backoff_ms)
    }
  end

  defp github_rate_limit_error?({:github_graphql_errors, errors}) when is_list(errors) do
    Enum.any?(errors, fn error ->
      code = Map.get(error, "type") || Map.get(error, :type) || Map.get(error, "code") || Map.get(error, :code)
      message = Map.get(error, "message") || Map.get(error, :message) || ""

      code in ["RATE_LIMIT", "graphql_rate_limit", :rate_limit] or
        String.contains?(String.downcase(to_string(message)), "rate limit")
    end)
  end

  defp github_rate_limit_error?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&github_rate_limit_error?/1)
  end

  defp github_rate_limit_error?(reason) when is_binary(reason),
    do: String.contains?(String.downcase(reason), "rate limit")

  defp github_rate_limit_error?(_reason), do: false

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp schedule_stall_check(%State{} = state) do
    if is_reference(state.stall_check_timer_ref) do
      Process.cancel_timer(state.stall_check_timer_ref)
    end

    configured_timeout = Config.settings!().codex.stall_timeout_ms

    interval_ms =
      if is_integer(configured_timeout) and configured_timeout > 0 do
        min(@stall_check_interval_ms, max(1_000, div(configured_timeout, 4)))
      else
        @stall_check_interval_ms
      end

    timer_ref = Process.send_after(self(), :stall_check, interval_ms)
    %{state | stall_check_timer_ref: timer_ref}
  end

  defp clear_poll_cycle_tracking(%State{} = state) do
    if is_reference(state.poll_timeout_timer_ref) do
      Process.cancel_timer(state.poll_timeout_timer_ref)
    end

    if is_reference(state.poll_task_ref) do
      Process.demonitor(state.poll_task_ref, [:flush])
    end

    %{
      state
      | poll_task_pid: nil,
        poll_task_ref: nil,
        poll_timeout_timer_ref: nil
    }
  end

  defp clear_target_refresh_tracking(%State{} = state) do
    if is_reference(state.target_refresh_timeout_timer_ref) do
      Process.cancel_timer(state.target_refresh_timeout_timer_ref)
    end

    if is_reference(state.target_refresh_task_ref) do
      Process.demonitor(state.target_refresh_task_ref, [:flush])
    end

    %{
      state
      | target_refresh_in_progress: false,
        target_refresh_task_pid: nil,
        target_refresh_task_ref: nil,
        target_refresh_timeout_timer_ref: nil,
        target_refresh_item: nil
    }
  end

  defp clear_delivery_reconcile_tracking(%State{} = state) do
    if is_reference(state.delivery_reconcile_timer_ref) do
      Process.cancel_timer(state.delivery_reconcile_timer_ref)
    end

    if is_reference(state.delivery_reconcile_task_ref) do
      Process.demonitor(state.delivery_reconcile_task_ref, [:flush])
    end

    %{
      state
      | delivery_reconcile_in_progress: false,
        delivery_reconcile_timer_ref: nil,
        delivery_reconcile_task_pid: nil,
        delivery_reconcile_task_ref: nil
    }
  end

  defp find_provider_recovery_task(tasks, task_ref)
       when is_map(tasks) and is_reference(task_ref) do
    Enum.find_value(tasks, fn
      {issue_id, %{task_ref: ^task_ref} = task} -> {issue_id, task}
      _ -> nil
    end)
  end

  defp find_provider_recovery_task(_tasks, _task_ref), do: nil

  defp clear_provider_recovery_task(%State{} = state, issue_id, task_ref)
       when is_binary(issue_id) and is_reference(task_ref) do
    case Map.get(state.provider_recovery_tasks, issue_id) do
      %{task_ref: ^task_ref} = task ->
        if is_reference(task.timeout_timer_ref) do
          Process.cancel_timer(task.timeout_timer_ref)
        end

        Process.demonitor(task_ref, [:flush])
        %{state | provider_recovery_tasks: Map.delete(state.provider_recovery_tasks, issue_id)}

      _ ->
        state
    end
  end

  # A recovery task can be killed after its controller has durably moved from
  # :waiting_provider to :delivering. Re-read that durable state on the next
  # recovery pass and resume it, rather than leaving the claim stranded until
  # a process restart or a future webhook happens to arrive.
  defp schedule_provider_recovery_retry(%State{} = state) do
    if github_gateway_ready?() do
      Process.send_after(self(), :provider_available, provider_retry_delay())
    end

    state
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp merge_poll_cycle_state(%State{} = current, %State{} = polled, base_running_entries) do
    base_running_entries =
      case base_running_entries do
        %MapSet{} = ids -> Map.new(ids, &{&1, nil})
        ids when is_list(ids) -> Map.new(ids, &{&1, nil})
        entries when is_map(entries) -> entries
        _ -> %{}
      end

    base_running_ids = Map.keys(base_running_entries)

    # The GenServer owns worker state. Worker-start messages are the only
    # authority allowed to add entries: importing new entries from the poll
    # snapshot could resurrect a worker that already emitted DOWN while the
    # poll was still in flight.
    removed_by_poll =
      MapSet.difference(MapSet.new(base_running_ids), MapSet.new(Map.keys(polled.running)))

    current_running =
      current.running
      |> Enum.reject(fn {issue_id, entry} ->
        MapSet.member?(removed_by_poll, issue_id) and
          poll_owned_entry?(entry, Map.get(base_running_entries, issue_id))
      end)
      |> Map.new()

    removed_claims =
      removed_by_poll
      |> Enum.filter(fn issue_id ->
        current_entry = Map.get(current.running, issue_id)
        poll_owned_entry?(current_entry, Map.get(base_running_entries, issue_id))
      end)

    claimed = Enum.reduce(removed_claims, current.claimed, &MapSet.delete(&2, &1))

    %{
      current
      | running: current_running,
        claimed: claimed,
        retry_attempts: Map.merge(polled.retry_attempts, current.retry_attempts),
        completed: MapSet.union(current.completed, polled.completed),
        poll_interval_ms: polled.poll_interval_ms,
        max_concurrent_agents: polled.max_concurrent_agents,
        codex_rate_limits: current.codex_rate_limits || polled.codex_rate_limits
    }
  end

  defp poll_owned_entry?(current_entry, base_entry) when is_map(current_entry) and is_map(base_entry) do
    Map.get(current_entry, :ref) == Map.get(base_entry, :ref)
  end

  defp poll_owned_entry?(_current_entry, _base_entry), do: false

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    case Config.settings() do
      {:ok, config} ->
        %{
          state
          | poll_interval_ms: config.polling.interval_ms,
            max_concurrent_agents: config.agent.max_concurrent_agents
        }

      {:error, reason} ->
        Logger.error("Ignoring invalid runtime configuration; retaining last known-good settings: #{inspect(reason)}")
        state
    end
  end

  defp retry_candidate_issue?(%{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !active_issue_blocked_by_non_terminal?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(Map.get(update, "rateLimits")) ||
      rate_limits_from_payload(Map.get(update, :rateLimits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct =
      Map.get(payload, "rate_limits") ||
        Map.get(payload, :rate_limits) ||
        Map.get(payload, "rateLimits") ||
        Map.get(payload, :rateLimits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    # Codex's account/rateLimits/updated notification uses the bucket names
    # directly and does not include a limit_id. Older app-server payloads did
    # include one, so accept both shapes while still requiring a recognizable
    # rate-limit envelope (rather than mistaking arbitrary nested maps for it).
    has_limit_fields =
      Enum.any?(
        [
          "remaining",
          :remaining,
          "resetsAt",
          :resetsAt,
          "resets_at",
          :resets_at,
          "usedPercent",
          :usedPercent,
          "used_percent",
          :used_percent,
          "rateLimitReachedType",
          :rateLimitReachedType,
          "rate_limit_reached_type",
          :rate_limit_reached_type
        ],
        &Map.has_key?(payload, &1)
      )

    (not is_nil(limit_id) and has_buckets) or (has_buckets and has_limit_fields)
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp handle_retry_timer(issue_id, retry_token, state) do
    if Map.has_key?(state.running, issue_id) or Map.has_key?(state.reservations, issue_id) do
      Logger.info("Discarding retry for already-running issue_id=#{issue_id}")
      {:noreply, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}
    else
      if github_gateway_open?() do
        {:noreply, park_retry_for_provider(state, issue_id, retry_token)}
      else
        case pop_retry_attempt_state(state, issue_id, retry_token) do
          {:ok, attempt, metadata, state} ->
            orchestrator = self()

            case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
                   result =
                     try do
                       Tracker.fetch_issue_states_by_ids([issue_id])
                     rescue
                       exception -> {:error, {:exception, exception, __STACKTRACE__}}
                     catch
                       kind, reason -> {:error, {kind, reason}}
                     end

                   send(orchestrator, {:retry_issue_lookup, issue_id, attempt, metadata, result})
                 end) do
              {:ok, pid} ->
                task_ref = Process.monitor(pid)
                timeout_timer_ref = Process.send_after(self(), {:retry_lookup_timeout, issue_id, attempt, task_ref}, @retry_lookup_timeout_ms)

                retry_entry = %{
                  attempt: attempt,
                  timer_ref: nil,
                  retry_token: make_ref(),
                  due_at_ms: System.monotonic_time(:millisecond),
                  lookup_task_pid: pid,
                  lookup_task_ref: task_ref,
                  lookup_timeout_timer_ref: timeout_timer_ref
                }

                state = %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, Map.merge(retry_entry, metadata))}
                notify_dashboard()
                {:noreply, state}

              {:error, reason} ->
                Logger.warning("Failed to start retry lookup for issue_id=#{issue_id}: #{inspect(reason)}")

                next_state =
                  schedule_issue_retry(
                    state,
                    issue_id,
                    attempt + 1,
                    Map.merge(metadata, %{error: "retry lookup task failed: #{inspect(reason)}"})
                  )

                notify_dashboard()
                {:noreply, next_state}
            end

          :missing ->
            {:noreply, state}
        end
      end
    end
  end

  defp load_control_state(opts) when is_list(opts) do
    path = control_state_path(opts)

    case ControlState.load(path) do
      {:ok, %ControlState{state: :running} = control} ->
        {:ok, recovering} = ControlState.begin_recovery(control, target: :running)
        send(self(), :complete_control_recovery)
        recovering

      {:ok, %ControlState{state: :recovering} = control} ->
        send(self(), :complete_control_recovery)
        control

      {:ok, %ControlState{} = control} ->
        control

      {:error, :enoent} ->
        ControlState.new(path: path)

      {:error, reason} ->
        Logger.error("Control-state snapshot is invalid; starting fail-closed: #{inspect(reason)}")
        {:ok, paused} = ControlState.new(path: path) |> ControlState.request_pause()
        paused
    end
  end

  defp control_state_path(opts) do
    Keyword.get(opts, :control_state_path) ||
      Application.get_env(:symphony_elixir, :control_state_path) ||
      Path.join(
        Application.get_env(:symphony_elixir, :runtime_state_dir) ||
          System.get_env("POLYPHONY_RUNTIME_STATE_DIR") ||
          Path.join([File.cwd!(), ".polyphony", "runtime"]),
        "control-state.json"
      )
  end

  defp control_admits?(%State{control: %ControlState{} = control}, kind),
    do: ControlState.admit?(control, kind)

  # Hand-constructed legacy/test states predate durable controls. Runtime
  # initialization always installs a ControlState before any admission check.
  defp control_admits?(%State{control: nil}, _kind), do: true
  defp control_admits?(%State{}, _kind), do: false

  defp reserve_worker_slot_on_owner(owner, issue, worker_host, slice_member_ids, attempt)
       when is_pid(owner) and owner != self() do
    try do
      GenServer.call(
        owner,
        {:reserve_worker_slot, issue, worker_host, slice_member_ids, attempt},
        5_000
      )
    catch
      :exit, reason -> {:error, {:owner_unavailable, reason}}
    end
  end

  defp reserve_worker_slot_on_owner(_owner, _issue, _worker_host, _slice_member_ids, _attempt),
    do: {:ok, :local}

  defp release_worker_reservation_on_owner(owner, token) when is_pid(owner) and owner != self() do
    try do
      GenServer.call(owner, {:release_worker_reservation, token}, 5_000)
    catch
      :exit, reason ->
        Logger.error("Unable to release worker reservation #{inspect(token)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp release_worker_reservation_on_owner(_owner, _token), do: {:error, :owner_process_required}

  defp reserve_worker_slot(%State{} = state, %{} = issue, worker_host, slice_member_ids, attempt)
       when is_list(slice_member_ids) do
    issue_id = Map.get(issue, :id)
    claim_ids = reservation_claim_ids(issue_id, slice_member_ids)
    claimed = state.claimed || MapSet.new()
    reservations = state.reservations || %{}
    conflicts = MapSet.intersection(claimed, claim_ids)

    cond do
      not is_binary(issue_id) or issue_id == "" ->
        {:error, :invalid_issue}

      not control_admits?(state, :worker) ->
        {:error, :admission_closed}

      conflicts != MapSet.new() and not delivery_retry_claim?(state, issue_id, conflicts) ->
        {:error, :issue_claimed}

      available_slots(state) == 0 or
        not reservation_state_slot_available?(state, issue) or
          not worker_host_slots_available?(state, worker_host) ->
        {:error, :no_worker_capacity}

      true ->
        token = make_ref()

        reservation = %{
          issue_id: issue_id,
          issue: issue,
          worker_host: worker_host,
          slice_member_ids: slice_member_ids,
          attempt: attempt,
          claimed_before: MapSet.intersection(claimed, claim_ids),
          reserved_at: DateTime.utc_now()
        }

        next_state = %{
          state
          | reservations: Map.put(reservations, token, reservation),
            claimed: MapSet.union(claimed, claim_ids)
        }

        {:ok, token, next_state}
    end
  end

  defp reserve_worker_slot(_state, _issue, _worker_host, _slice_member_ids, _attempt),
    do: {:error, :invalid_reservation}

  defp reservation_claim_ids(issue_id, slice_member_ids) do
    [issue_id | slice_member_ids]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  end

  defp delivery_retry_claim?(%State{} = state, issue_id, conflicts) do
    conflicts == MapSet.new([issue_id]) and
      match?(%Delivery{state: :retry_ready}, Map.get(state.deliveries, issue_id))
  end

  defp delivery_retry_claim?(_state, _issue_id, _conflicts), do: false

  defp reservation_state_slot_available?(%State{} = state, %{state: issue_state}) do
    limit = Config.max_concurrent_agents_for_state(issue_state)

    used_running = running_issue_count_for_state(state.running, issue_state)
    used_reserved = reserved_issue_count_for_state(state.reservations, issue_state)
    limit > used_running + used_reserved
  end

  defp reservation_state_slot_available?(_state, _issue), do: false

  defp reserved_issue_count_for_state(reservations, issue_state) when is_map(reservations) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(reservations, fn
      {_token, %{issue: %{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp reserved_issue_count_for_state(_reservations, _issue_state), do: 0

  defp take_worker_reservation(%State{} = state, issue_id) when is_binary(issue_id) do
    case Enum.find(state.reservations, fn {_token, reservation} -> reservation.issue_id == issue_id end) do
      {token, reservation} -> {:ok, reservation, Map.delete(state.reservations, token)}
      nil -> :none
    end
  end

  defp take_worker_reservation(_state, _issue_id), do: :none

  defp release_worker_reservation(%State{} = state, token) do
    case Map.pop(state.reservations, token) do
      {nil, _reservations} ->
        {state, false}

      {reservation, reservations} ->
        claim_ids = reservation_claim_ids(reservation.issue_id, reservation.slice_member_ids)

        claimed =
          state.claimed
          |> MapSet.difference(claim_ids)
          |> MapSet.union(reservation.claimed_before || MapSet.new())

        {%{state | reservations: reservations, claimed: claimed}, true}
    end
  end

  defp refresh_control_obligations(%State{control: %ControlState{} = control} = state) do
    delivery_count =
      Enum.count(state.deliveries, fn {_issue_id, delivery} ->
        delivery.state in [:setup, :delivering, :waiting_ci, :waiting_merge, :merged]
      end)

    cleanup_count = Enum.count(state.deliveries, fn {_issue_id, delivery} -> delivery.state == :cleaning end)

    obligations = %{
      execution: map_size(state.running) + map_size(state.reservations),
      delivery: delivery_count,
      cleanup: cleanup_count
    }

    case ControlState.set_obligations(control, obligations) do
      {:ok, next_control} ->
        state
        |> Map.put(:control, next_control)
        |> persist_control_state_if_changed(control)

      {:error, reason} ->
        Logger.warning("Failed to refresh control obligations: #{inspect(reason)}")
        state
    end
  end

  defp refresh_control_obligations(%State{} = state), do: state

  defp persist_control_state_if_changed(%State{control: control} = state, previous) do
    if control == previous, do: state, else: persist_control_state(state)
  end

  defp persist_control_state(%State{control: %ControlState{} = control} = state) do
    case ControlState.persist(control) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error("Failed to persist control state: #{inspect(reason)}")
        state
    end
  end

  defp persist_control_state(%State{} = state), do: state

  defp apply_delivery_reconcile(state, issue_id, delivery, summary) do
    case reconcile_delivery(delivery, summary) do
      {:ok, %Delivery{} = reconciled} ->
        state
        |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, reconciled))
        |> apply_reconciled_delivery_state(issue_id, reconciled)
        |> refresh_control_obligations()

      {:error, reason, %Delivery{} = retained} ->
        Logger.warning("Unable to apply delivery reconciliation for issue_id=#{issue_id}: #{inspect(reason)}")
        %{state | deliveries: Map.put(state.deliveries, issue_id, retained)}

      {:error, reason} ->
        Logger.warning("Unable to open persisted delivery for issue_id=#{issue_id}: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_delivery(%Delivery{} = delivery, summary) when is_map(summary) do
    with {:ok, controller} <-
           DeliveryController.start_link(
             delivery_id: delivery.issue_id,
             delivery: delivery,
             runtime_dir: delivery_runtime_dir(),
             github_adapter: DeliveryAdapter,
             cleanup_adapter: DeliveryController.SystemCommandAdapter
           ) do
      result = apply_reconcile_summary(controller, delivery, summary)
      if Process.alive?(controller), do: GenServer.stop(controller)
      result
    end
  end

  defp apply_reconcile_summary(_controller, delivery, %{status: :pending}),
    do: {:ok, delivery}

  defp apply_reconcile_summary(controller, %Delivery{state: :waiting_ci}, %{status: :failed} = summary),
    do: DeliveryController.handle_ci_event(controller, %{conclusion: "failure", failure_reason: summary})

  defp apply_reconcile_summary(controller, %Delivery{state: :waiting_ci}, %{status: :passed} = summary),
    do: DeliveryController.handle_ci_event(controller, %{conclusion: "success", id: summary[:commit_sha]})

  defp apply_reconcile_summary(controller, %Delivery{state: :waiting_ci}, %{status: status} = summary)
       when status in [:merged, :conflict] do
    case DeliveryController.handle_ci_event(controller, %{conclusion: "success", id: summary[:commit_sha]}) do
      {:ok, waiting_merge} -> apply_reconcile_summary(controller, waiting_merge, summary)
      error -> error
    end
  end

  defp apply_reconcile_summary(controller, %Delivery{state: :waiting_merge}, %{status: :merged} = summary),
    do:
      DeliveryController.handle_pull_request_event(controller, %{
        merged: true,
        merge_commit_sha: summary[:merge_sha]
      })

  defp apply_reconcile_summary(controller, %Delivery{state: :waiting_merge}, %{status: :conflict} = summary),
    do: DeliveryController.handle_pull_request_event(controller, %{conflict: true, reason: summary[:reason]})

  defp apply_reconcile_summary(_controller, delivery, _summary), do: {:ok, delivery}

  defp apply_reconciled_delivery_state(state, issue_id, %Delivery{state: :retry_ready} = delivery) do
    retry_limit = Config.max_delivery_retry_attempts()

    if delivery_retry_budget_exhausted?(delivery, retry_limit) do
      reason = {:delivery_retry_budget_exhausted, retry_limit, delivery.failure_reason}

      case persist_permanent_delivery_failure(issue_id, delivery, reason) do
        {:ok, failed_delivery} ->
          Logger.error(
            "Persisted delivery retry budget exhausted for issue_id=#{issue_id} " <>
              "attempts=#{delivery.attempt} limit=#{retry_limit}; parking for manual escalation"
          )

          state
          |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, failed_delivery))
          |> complete_issue(issue_id)

        {:error, persist_reason} ->
          Logger.error("Could not persist exhausted reconciled delivery for issue_id=#{issue_id}: #{inspect(persist_reason)}; refusing retry")

          complete_issue(state, issue_id)
      end
    else
      case mark_final_escalation_if_needed(issue_id, delivery, retry_limit) do
        {:ok, delivery} ->
          failure = List.first(delivery.failures) || %{}
          classification = Map.get(failure, :classification) || Map.get(failure, "classification")

          state
          |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, delivery))
          |> Map.put(:completed, MapSet.delete(state.completed, issue_id))
          |> schedule_issue_retry(issue_id, max(delivery.attempt, 1), %{
            identifier: Map.get(delivery.metadata, "identifier") || issue_id,
            error: "delivery retry required: #{inspect(delivery.failure_reason)}",
            delay_type: :failure,
            failure_class: classification,
            failure_attempt: delivery.attempt,
            workspace_path: delivery.workspace,
            resume_thread_id: Map.get(delivery.metadata, "thread_id"),
            delivery_retry: true,
            delivery_failure_reason: delivery.failure_reason
          })

        {:error, reason} ->
          Logger.error("Could not persist final reconciled escalation for issue_id=#{issue_id}: #{inspect(reason)}; refusing retry")
          complete_issue(state, issue_id)
      end
    end
  end

  defp apply_reconciled_delivery_state(state, issue_id, %Delivery{state: :complete}) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp apply_reconciled_delivery_state(state, issue_id, %Delivery{}) do
    %{state | claimed: MapSet.put(state.claimed, issue_id)}
  end

  defp resume_provider_waits(%State{} = state), do: resume_provider_waits(state, github_gateway_ready?())

  defp resume_provider_waits(%State{} = state, false), do: state

  defp resume_provider_waits(%State{} = state, true) do
    Enum.reduce(state.deliveries, state, fn
      {issue_id, %Delivery{state: :waiting_provider} = delivery}, state ->
        start_provider_recovery(state, issue_id, delivery)

      _entry, state ->
        state
    end)
  end

  defp start_provider_recovery(%State{} = state, issue_id, %Delivery{} = delivery)
       when is_binary(issue_id) do
    if Map.has_key?(state.provider_recovery_tasks, issue_id) do
      state
    else
      try do
        runtime_dir = state.delivery_runtime_dir

        task =
          Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            resume_provider_delivery(delivery, runtime_dir)
          end)

        timeout_timer_ref =
          Process.send_after(
            self(),
            {:provider_recovery_timeout, issue_id, task.ref},
            @provider_recovery_timeout_ms
          )

        recovery_task = %{
          pid: task.pid,
          task_ref: task.ref,
          timeout_timer_ref: timeout_timer_ref
        }

        %{state | provider_recovery_tasks: Map.put(state.provider_recovery_tasks, issue_id, recovery_task)}
      rescue
        error ->
          Logger.warning("Unable to start provider recovery issue_id=#{issue_id}: #{Exception.message(error)}")
          state
      catch
        :exit, reason ->
          Logger.warning("Provider recovery supervisor unavailable issue_id=#{issue_id}: #{inspect(reason)}")
          state
      end
    end
  end

  defp apply_provider_recovery_result(%State{} = state, issue_id, {:ok, %Delivery{} = resumed}) do
    Logger.info(
      "Provider recovered; resumed parked delivery issue_id=#{issue_id} " <>
        "state=#{resumed.state} attempt=#{resumed.attempt}"
    )

    state
    |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, resumed))
    |> apply_reconciled_delivery_state(issue_id, resumed)
  end

  defp apply_provider_recovery_result(
         %State{} = state,
         issue_id,
         {:error, reason, %Delivery{} = resumed}
       ) do
    Logger.warning("Unable to resume parked delivery issue_id=#{issue_id}: #{inspect(reason)}")

    state
    |> Map.put(:deliveries, Map.put(state.deliveries, issue_id, resumed))
    |> apply_reconciled_delivery_state(issue_id, resumed)
  end

  defp apply_provider_recovery_result(%State{} = state, issue_id, {:error, reason}) do
    Logger.warning("Unable to resume parked delivery issue_id=#{issue_id}: #{inspect(reason)}")
    state
  end

  defp apply_provider_recovery_result(%State{} = state, issue_id, result) do
    Logger.warning("Invalid provider recovery result issue_id=#{issue_id}: #{inspect(result)}")
    state
  end

  defp resume_provider_delivery(%Delivery{} = delivery, runtime_dir) when is_binary(runtime_dir) do
    delivery = load_durable_provider_delivery(delivery, runtime_dir)

    case DeliveryController.start_link(
           delivery_id: delivery.issue_id,
           delivery: delivery,
           runtime_dir: runtime_dir,
           github_adapter: DeliveryAdapter,
           cleanup_adapter: DeliveryController.SystemCommandAdapter
         ) do
      {:ok, controller} ->
        try do
          case delivery.state do
            :waiting_provider ->
              with {:ok, %Delivery{} = resumed} <- DeliveryController.provider_available(controller) do
                resume_provider_delivery_operation(controller, resumed)
              end

            :delivering ->
              DeliveryController.resume_delivery(controller)

            _ ->
              {:ok, delivery}
          end
        after
          if Process.alive?(controller), do: GenServer.stop(controller)
        end

      {:error, reason, %Delivery{}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_durable_provider_delivery(%Delivery{} = delivery, runtime_dir) do
    case DeliveryController.load(runtime_dir, delivery.issue_id) do
      {:ok, %Delivery{} = persisted} -> persisted
      {:error, _reason} -> delivery
    end
  end

  defp resume_provider_delivery_operation(controller, %Delivery{state: :delivering}),
    do: DeliveryController.resume_delivery(controller)

  defp resume_provider_delivery_operation(_controller, %Delivery{} = delivery), do: {:ok, delivery}

  defp github_gateway_ready? do
    case GitHubGateway.snapshot() do
      %{available?: true, circuit: :closed} -> true
      _ -> false
    end
  end

  defp schedule_delivery_reconcile(%State{} = state, delay_ms)
       when is_integer(delay_ms) and delay_ms >= 0 do
    if state.delivery_reconcile_in_progress == true do
      state
    else
      if is_reference(state.delivery_reconcile_timer_ref) do
        Process.cancel_timer(state.delivery_reconcile_timer_ref)
      end

      timer_ref = Process.send_after(self(), :reconcile_deliveries, delay_ms)
      %{state | delivery_reconcile_timer_ref: timer_ref}
    end
  end

  defp next_reconcilable_delivery(deliveries, cursor) when is_map(deliveries) do
    candidates =
      deliveries
      |> Enum.filter(fn
        {_issue_id, %Delivery{state: state, pr_number: pr_number}}
        when state in [:waiting_ci, :waiting_merge] and is_integer(pr_number) and pr_number > 0 ->
          true

        _ ->
          false
      end)
      |> Enum.sort_by(fn {issue_id, _delivery} -> issue_id end)

    case candidates do
      [] ->
        nil

      candidates when is_nil(cursor) ->
        List.first(candidates)

      candidates ->
        {before, after_cursor} = Enum.split_while(candidates, fn {issue_id, _} -> issue_id != cursor end)

        case after_cursor do
          [{^cursor, _} | next] -> List.first(next) || List.first(candidates)
          _ -> List.first(before) || List.first(candidates)
        end
    end
  end

  defp advance_delivery_reconcile(%State{} = state, issue_id) do
    candidate_count = reconcilable_delivery_count(state.deliveries)
    cycle_count = state.delivery_reconcile_cycle_count + 1

    if candidate_count <= 1 or cycle_count >= candidate_count do
      state
      |> Map.put(:delivery_reconcile_cursor, nil)
      |> Map.put(:delivery_reconcile_cycle_count, 0)
      |> schedule_delivery_reconcile(@delivery_reconcile_interval_ms)
    else
      state
      |> Map.put(:delivery_reconcile_cursor, issue_id)
      |> Map.put(:delivery_reconcile_cycle_count, cycle_count)
      |> schedule_delivery_reconcile(stateful_reconcile_delay())
    end
  end

  defp stateful_reconcile_delay, do: 0

  defp reconcilable_delivery_count(deliveries) do
    Enum.count(deliveries, fn
      {_issue_id, %Delivery{state: state, pr_number: pr_number}}
      when state in [:waiting_ci, :waiting_merge] and is_integer(pr_number) and pr_number > 0 ->
        true

      _ ->
        false
    end)
  end

  defp load_deliveries(opts) when is_list(opts) do
    delivery_runtime_dir(opts)
    |> Path.join("deliveries/*.json")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, deliveries ->
      case File.read(path) do
        {:ok, json} ->
          case Delivery.decode(json) do
            {:ok, %Delivery{issue_id: issue_id} = delivery} when is_binary(issue_id) ->
              Map.put(deliveries, issue_id, delivery)

            {:error, reason} ->
              Logger.warning("Ignoring invalid delivery state #{path}: #{inspect(reason)}")
              deliveries
          end

        {:error, reason} ->
          Logger.warning("Unable to read delivery state #{path}: #{inspect(reason)}")
          deliveries
      end
    end)
  end

  defp recover_interrupted_deliveries(deliveries, opts) when is_map(deliveries) do
    Enum.reduce(deliveries, deliveries, fn
      {issue_id, %Delivery{state: state} = delivery}, recovered
      when state in [:setup, :executing, :delivering, :cleaning] ->
        reason = {:orchestrator_restart, "worker interrupted while delivery was #{state}"}

        recovered_delivery = %{
          delivery
          | state: :retry_ready,
            attempt: delivery.attempt + 1,
            failure_reason: reason,
            failures: [%{classification: :code, reason: reason} | delivery.failures],
            last_event: :orchestrator_restart
        }

        case persist_loaded_delivery(recovered_delivery, opts) do
          :ok ->
            Logger.warning(
              "Recovered interrupted delivery issue_id=#{issue_id} " <>
                "previous_state=#{state} as retry_ready"
            )

          {:error, persist_reason} ->
            Logger.error(
              "Unable to persist interrupted delivery recovery issue_id=#{issue_id}: " <>
                "#{inspect(persist_reason)}"
            )
        end

        Map.put(recovered, issue_id, recovered_delivery)

      _, recovered ->
        recovered
    end)
  end

  defp persist_loaded_delivery(%Delivery{} = delivery, opts) do
    with {:ok, json} <- Delivery.encode(delivery),
         runtime_dir = delivery_runtime_dir(opts),
         :ok <- File.mkdir_p(Path.join(runtime_dir, "deliveries")),
         :ok <- File.write(Path.join(runtime_dir, "deliveries/#{delivery.issue_id}.json"), json) do
      :ok
    end
  end

  defp pending_delivery_ids(deliveries) do
    deliveries
    |> Enum.filter(fn {_issue_id, delivery} -> not Delivery.terminal?(delivery.state) end)
    |> Enum.map(fn {issue_id, _delivery} -> issue_id end)
    |> MapSet.new()
  end

  defp completed_delivery_ids(deliveries) do
    deliveries
    |> Enum.filter(fn {_issue_id, delivery} -> delivery.state == :complete end)
    |> Enum.map(fn {issue_id, _delivery} -> issue_id end)
    |> MapSet.new()
  end

  defp schedule_loaded_delivery_retries(%State{} = state) do
    Enum.reduce(state.deliveries, state, fn
      {issue_id, %Delivery{state: :retry_ready} = delivery}, state ->
        apply_reconciled_delivery_state(state, issue_id, delivery)

      _delivery, state ->
        state
    end)
  end

  defp delivery_runtime_dir(opts \\ []) do
    Keyword.get(opts, :runtime_state_dir) ||
      control_state_runtime_dir(opts) ||
      Application.get_env(:symphony_elixir, :runtime_state_dir) ||
      System.get_env("POLYPHONY_RUNTIME_STATE_DIR") ||
      Path.join([File.cwd!(), ".polyphony", "runtime"])
  end

  defp control_state_runtime_dir(opts) do
    case Keyword.get(opts, :control_state_path) do
      path when is_binary(path) and path != "" -> Path.dirname(Path.expand(path))
      _ -> nil
    end
  end

  defp apply_control_command(%State{} = state, command, _params)
       when command in [:pause, :drain, :resume, :stop] do
    with {:ok, control} <- ControlState.transition(state.control, command) do
      next_state = Map.put(state, :control, control)

      if command == :resume and control.state == :recovering do
        send(self(), :complete_control_recovery)
      end

      {:ok, next_state, %{command: command, accepted: true}}
    end
  end

  defp apply_control_command(%State{} = state, :hard_stop, params) do
    with {:ok, scope} <- validate_control_scope(params),
         {:ok, control, action} <- ControlState.hard_stop(state.control, scope) do
      pids =
        state.running
        |> Map.values()
        |> Enum.map(&Map.get(&1, :pid))
        |> Enum.filter(&is_pid/1)

      Enum.each(pids, &terminate_task/1)

      {:ok, %{state | control: control},
       %{
         command: :hard_stop,
         accepted: true,
         action: Map.merge(action, %{performed?: true, terminated_workers: length(pids)})
       }}
    end
  end

  defp apply_control_command(_state, command, _params), do: {:error, {:unsupported_control_command, command}}

  defp validate_control_scope(params) when is_map(params) do
    requested = Map.get(params, :scope) || Map.get(params, "scope") || params
    project = Map.get(requested, :project) || Map.get(requested, "project")
    cgroup = Map.get(requested, :cgroup) || Map.get(requested, "cgroup")
    expected = configured_control_scope()

    if project == expected.project and cgroup == expected.cgroup do
      {:ok, expected}
    else
      {:error, {:control_scope_mismatch, expected}}
    end
  end

  defp configured_control_scope do
    %{
      project: System.get_env("POLYPHONY_PROJECT_ID") || "patches",
      cgroup: System.get_env("POLYPHONY_PROJECT_CGROUP") || "polyphony-patches.service"
    }
  end

  defp control_snapshot(%State{control: %ControlState{} = control}) do
    %{
      state: control.state,
      generation: control.generation,
      obligations: control.obligations,
      admission: Map.new(ControlState.admission_kinds(), &{&1, ControlState.admission(control, &1)}),
      scope: configured_control_scope(),
      updated_at_ms: control.updated_at_ms
    }
  end

  defp control_snapshot(%State{}), do: %{state: :unavailable, scope: configured_control_scope()}

  defp defer_retry_for_control(%State{} = state, issue_id, retry_token) do
    case pop_retry_attempt_state(state, issue_id, retry_token) do
      {:ok, attempt, metadata, next_state} ->
        schedule_issue_retry(next_state, issue_id, attempt, Map.put(metadata, :delay_type, :control))

      :missing ->
        state
    end
  end

  defp load_github_projection(opts) when is_list(opts) do
    path =
      Keyword.get(opts, :github_projection_path) ||
        Application.get_env(:symphony_elixir, :github_projection_path) ||
        Path.join(
          Application.get_env(:symphony_elixir, :runtime_state_dir) ||
            System.get_env("POLYPHONY_RUNTIME_STATE_DIR") ||
            Path.join([File.cwd!(), ".polyphony", "runtime"]),
          "github-projection.term"
        )

    case GitHubProjection.load(path: path) do
      {:ok, projection} ->
        projection

      {:error, reason} ->
        Logger.error("GitHub projection is invalid; starting with an empty queue: #{inspect(reason)}")
        GitHubProjection.new(path: path)
    end
  end

  defp persist_github_projection(%State{github_projection: projection} = state) do
    case GitHubProjection.persist(projection) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error("Failed to persist GitHub targeted projection: #{inspect(reason)}")
        state
    end
  end

  defp schedule_targeted_refresh(%State{} = state, delay_ms)
       when is_integer(delay_ms) and delay_ms >= 0 do
    ready? = GitHubProjection.ready_ids(state.github_projection) != []

    cond do
      not ready? or state.target_refresh_in_progress == true ->
        state

      true ->
        if is_reference(state.target_refresh_timer_ref) do
          Process.cancel_timer(state.target_refresh_timer_ref)
        end

        timer_ref = Process.send_after(self(), :process_targeted_refresh, delay_ms)
        %{state | target_refresh_timer_ref: timer_ref}
    end
  end

  defp targeted_issue_node_id(nil), do: nil

  defp targeted_issue_node_id(%{target: target}) when is_map(target) do
    case Map.get(target, "node_id") || Map.get(target, :node_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp targeted_issue_node_id(_item), do: nil

  defp targeted_dispatch_issue(issues, %State{} = state) when is_list(issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    Enum.find(issues, fn
      %{} = issue -> should_dispatch_issue?(issue, state, active_states, terminal_states)
      _ -> false
    end)
  end

  defp targeted_dispatch_issue(_issues, _state), do: nil

  defp start_targeted_dispatch(%State{} = state, item, issue) do
    owner = self()
    base_running = state.running

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           result =
             try do
               {:ok, do_dispatch_issue(state, issue, nil, nil, board_context([issue]), owner)}
             rescue
               exception -> {:error, {:exception, exception, __STACKTRACE__}}
             catch
               kind, reason -> {:error, {kind, reason}}
             end

           case result do
             {:ok, dispatched_state} ->
               send(owner, {:targeted_dispatch_complete, item, dispatched_state, base_running})

             {:error, reason} ->
               send(owner, {:targeted_dispatch_failed, item, reason})
           end
         end) do
      {:ok, pid} ->
        task_ref = Process.monitor(pid)
        timeout_timer_ref = Process.send_after(self(), {:targeted_refresh_timeout, task_ref}, @targeted_refresh_timeout_ms)

        {:noreply,
         %{
           state
           | target_refresh_in_progress: true,
             target_refresh_task_pid: pid,
             target_refresh_task_ref: task_ref,
             target_refresh_timeout_timer_ref: timeout_timer_ref,
             target_refresh_item: item
         }}

      {:error, reason} ->
        next_state =
          state
          |> requeue_targeted_item(item, reason, true)
          |> Map.put(:target_refresh_in_progress, false)
          |> schedule_targeted_refresh(targeted_failure_delay(item))

        {:noreply, next_state}
    end
  end

  defp acknowledge_targeted_item(%State{} = state, nil, _metadata), do: state

  defp acknowledge_targeted_item(%State{} = state, item, metadata) do
    projection = GitHubProjection.acknowledge(state.github_projection, item, metadata)
    state |> Map.put(:github_projection, projection) |> persist_github_projection()
  end

  defp requeue_targeted_item(%State{} = state, nil, _reason, _increment?), do: state

  defp requeue_targeted_item(%State{} = state, item, reason, increment?) do
    projection =
      if increment? do
        GitHubProjection.requeue(state.github_projection, item,
          increment_attempt: true,
          provider_wait: nil
        )
      else
        GitHubProjection.requeue_provider_wait(state.github_projection, item, reason)
      end

    state |> Map.put(:github_projection, projection) |> persist_github_projection()
  end

  defp targeted_failure_delay(%{attempts: attempts}) when is_integer(attempts) do
    min(@failure_retry_base_ms * (1 <<< min(attempts, 6)), 900_000)
  end

  defp targeted_failure_delay(_item), do: @failure_retry_base_ms
end

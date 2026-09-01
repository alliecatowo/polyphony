defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Delivery, DeliveryController, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.GitHub.Gateway, as: GitHubGateway
  alias SymphonyElixir.GitHub.DeliveryAdapter

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    model =
      Config.codex_model_for_issue(issue,
        attempt: Keyword.get(opts, :attempt, 0),
        failure_class: Keyword.get(opts, :failure_class),
        failure_attempt: Keyword.get(opts, :failure_attempt)
      )

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, Keyword.put(opts, :model, model), worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        retryable_reason = normalize_provider_error(reason)
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(retryable_reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(retryable_reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        case existing_delivery_retry(issue, workspace) do
          {:ok, delivery} ->
            retry_opts = Keyword.put(opts, :model, delivery_retry_model(issue, delivery))
            retry_existing_delivery(delivery, issue, worker_host, codex_update_recipient, retry_opts)

          :none ->
            with :ok <- prepare_delivery_for_model_retry(issue, workspace, worker_host, codex_update_recipient, opts),
                 :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
                 {:ok, turn_session} <-
                   run_codex_with_finalized_hooks(workspace, issue, codex_update_recipient, opts, worker_host) do
              maybe_deliver_turn(
                issue,
                workspace,
                worker_host,
                turn_session,
                codex_update_recipient,
                opts
              )
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    resume_thread_id = resume_thread_id_for_issue(issue, opts)

    with {:ok, session} <-
           AppServer.start_session(workspace,
             worker_host: worker_host,
             model: Keyword.get(opts, :model),
             resume_thread_id: resume_thread_id
           ) do
      send_codex_thread_info(codex_update_recipient, issue, session[:thread_id])

      try do
        case do_run_codex_turns(
               session,
               workspace,
               issue,
               codex_update_recipient,
               opts,
               issue_state_fetcher,
               1,
               max_turns
             ) do
          result ->
            result
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_codex_with_finalized_hooks(workspace, issue, recipient, opts, worker_host) do
    try do
      run_codex_turns(workspace, issue, recipient, opts, worker_host)
    after
      Workspace.run_after_run_hook(workspace, issue, worker_host)
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          {:ok, turn_session}

        {:done, _refreshed_issue} ->
          {:ok, turn_session}

        {:error, reason} ->
          if provider_wait_error?(reason) do
            Logger.warning("Provider unavailable after completed turn for #{issue_context(issue)}; parking continuation without failing the agent")
            {:ok, turn_session}
          else
            {:error, reason}
          end
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case GitHubGateway.snapshot() do
      %{available?: true, circuit: :open} ->
        {:error, {:provider_unavailable, :github_circuit_open}}

      _ ->
        refresh_issue_state(issue, issue_id, issue_state_fetcher)
    end
  end

  defp refresh_issue_state(issue, issue_id, issue_state_fetcher) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp provider_wait_error?({:github_rate_limited, _reset_at, _retry_in_ms}), do: true
  defp provider_wait_error?({:github_provider_unavailable, _details}), do: true
  defp provider_wait_error?({:codex_provider_unavailable, _details}), do: true
  defp provider_wait_error?({:provider_unavailable, _details}), do: true

  defp provider_wait_error?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&provider_wait_error?/1)
  end

  defp provider_wait_error?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)
    String.contains?(normalized, "rate limit") or String.contains?(normalized, "provider circuit")
  end

  defp provider_wait_error?(_reason), do: false

  defp normalize_provider_error({:codex_provider_unavailable, details}) when is_map(details) do
    {:provider_unavailable, provider_wait_message(details)}
  end

  defp normalize_provider_error(reason) do
    case AppServer.classify_provider_error(reason) do
      {:ok, details} -> {:provider_unavailable, provider_wait_message(details)}
      :none -> reason
    end
  end

  defp provider_wait_message(details) when is_map(details) do
    kind = Map.get(details, :kind, :provider)
    retry_in_ms = Map.get(details, :retry_in_ms)
    retry_at_ms = Map.get(details, :retry_at_ms)

    "Codex provider circuit open (#{kind}; rate limit/usage limit); " <>
      "retry_in_ms=#{inspect(retry_in_ms)} retry_at_ms=#{inspect(retry_at_ms)}"
  end

  defp maybe_deliver_turn(issue, workspace, worker_host, turn_session, recipient, opts) do
    if delivery_enabled?(opts) do
      with {:ok, branch} <- current_workspace_branch(workspace),
           {:ok, controller} <-
             DeliveryController.start_link(
               delivery_id: issue.id,
               delivery: delivery_for_turn(issue, workspace, branch, turn_session, opts),
               runtime_dir: delivery_runtime_dir(),
               github_adapter: Keyword.get(opts, :delivery_github_adapter, DeliveryAdapter),
               command_adapter: Keyword.get(opts, :delivery_command_adapter, DeliveryController.SystemCommandAdapter),
               cleanup_adapter: Keyword.get(opts, :delivery_cleanup_adapter, DeliveryController.SystemCommandAdapter)
             ),
           :ok <- ensure_delivery_executing(controller),
           result <-
             DeliveryController.codex_turn_completed(controller, %{
               session_id: turn_session[:session_id],
               thread_id: turn_session[:thread_id],
               summary: delivery_summary(turn_session)
             }) do
        handle_delivery_result(result, controller, issue, recipient, worker_host)
      else
        {:error, reason} -> {:error, {:delivery_harness_failed, reason}}
      end
    else
      :ok
    end
  end

  defp delivery_enabled?(opts) do
    Keyword.get(opts, :delivery_enabled, Config.settings!().tracker.kind == "github")
  end

  defp delivery_for_turn(issue, workspace, branch, turn_session, opts) do
    case DeliveryController.load(delivery_runtime_dir(), issue.id) do
      {:ok, %Delivery{} = delivery} ->
        %{delivery | metadata: Map.merge(delivery.metadata, issue_delivery_metadata(issue))}

      _ ->
        Delivery.new(
          issue_id: issue.id,
          workspace: workspace,
          branch: branch,
          metadata: %{
            "identifier" => issue.identifier,
            "title" => issue.title,
            "description" => issue.description,
            "url" => issue.url,
            "thread_id" => turn_session[:thread_id],
            "model" => Keyword.get(opts, :model)
          }
        )
    end
  end

  defp issue_delivery_metadata(issue) do
    %{
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "url" => issue.url
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp ensure_delivery_executing(controller) do
    case DeliveryController.snapshot(controller) do
      {:ok, %Delivery{state: :setup}} ->
        case DeliveryController.setup_completed(controller) do
          {:ok, %Delivery{state: :executing}} -> :ok
          {:error, reason, _delivery} -> {:error, reason}
        end

      {:ok, %Delivery{state: :executing}} ->
        :ok

      {:ok, %Delivery{state: state}} ->
        {:error, {:delivery_not_executable, state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_delivery_result(result, controller, issue, recipient, worker_host) do
    response =
      case result do
        {:ok, %Delivery{} = delivery} ->
          send_delivery_update(recipient, issue, delivery, worker_host)
          :ok

        {:error, {:provider_unavailable, _reason}, %Delivery{} = delivery} ->
          send_delivery_update(recipient, issue, delivery, worker_host)
          :ok

        {:error, reason, %Delivery{} = delivery} ->
          send_delivery_update(recipient, issue, delivery, worker_host)
          {:error, {:delivery_failed, reason}}
      end

    if Process.alive?(controller), do: GenServer.stop(controller)
    response
  end

  defp send_delivery_update(recipient, %{id: issue_id}, %Delivery{} = delivery, worker_host)
       when is_pid(recipient) do
    send(recipient, {:worker_delivery_state, issue_id, delivery, worker_host})
    :ok
  end

  defp send_delivery_update(_recipient, _issue, _delivery, _worker_host), do: :ok

  defp current_workspace_branch(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} when is_binary(branch) ->
        case String.trim(branch) do
          "" -> {:error, {:branch_detection_failed, 0, "empty branch"}}
          branch -> {:ok, branch}
        end

      {output, status} ->
        {:error, {:branch_detection_failed, status, String.slice(output, 0, 500)}}
    end
  rescue
    error -> {:error, {:branch_detection_exception, Exception.message(error)}}
  end

  defp delivery_runtime_dir do
    System.get_env("POLYPHONY_RUNTIME_STATE_DIR") ||
      Path.join([File.cwd!(), ".polyphony", "runtime"])
  end

  defp existing_delivery_retry(issue, workspace) do
    case DeliveryController.load(delivery_runtime_dir(), issue.id) do
      {:ok, %Delivery{state: :retry_ready, workspace: ^workspace} = delivery} ->
        {:ok, delivery}

      _ ->
        :none
    end
  end

  defp delivery_retry_model(issue, %Delivery{} = delivery) do
    failure = List.first(delivery.failures) || %{}
    failure_class = Map.get(failure, :classification) || Map.get(failure, "classification")

    Config.codex_model_for_issue(issue,
      failure_attempt: delivery.attempt,
      failure_class: failure_class
    )
  end

  defp prepare_delivery_for_model_retry(issue, workspace, worker_host, recipient, opts) do
    case DeliveryController.load(delivery_runtime_dir(), issue.id) do
      {:ok, %Delivery{state: :retry_ready, workspace: ^workspace} = delivery} ->
        with {:ok, controller} <-
               DeliveryController.start_link(
                 delivery_id: issue.id,
                 delivery: delivery,
                 runtime_dir: delivery_runtime_dir(),
                 github_adapter: Keyword.get(opts, :delivery_github_adapter, DeliveryAdapter),
                 command_adapter: Keyword.get(opts, :delivery_command_adapter, DeliveryController.SystemCommandAdapter),
                 cleanup_adapter: Keyword.get(opts, :delivery_cleanup_adapter, DeliveryController.SystemCommandAdapter)
               ),
             {:ok, %Delivery{state: :executing} = executing} <- DeliveryController.admit_retry(controller) do
          send_delivery_update(recipient, issue, executing, worker_host)
          if Process.alive?(controller), do: GenServer.stop(controller)
          :ok
        else
          {:error, reason, %Delivery{} = failed} ->
            send_delivery_update(recipient, issue, failed, worker_host)
            {:error, {:delivery_retry_admission_failed, reason}}

          {:error, reason} ->
            {:error, {:delivery_retry_admission_failed, reason}}
        end

      {:ok, %Delivery{}} ->
        :ok

      {:error, {:delivery_read_failed, _path, :enoent}} ->
        :ok

      {:error, reason} ->
        {:error, {:delivery_retry_load_failed, reason}}
    end
  end

  defp retry_existing_delivery(delivery, issue, worker_host, recipient, opts) do
    workspace = delivery.workspace

    # A retry is a new implementation turn with the prior delivery evidence
    # available in the worktree/persisted delivery. Replaying delivery alone
    # cannot repair a conflict or failing CI and creates a hot retry loop.
    with :ok <- prepare_delivery_for_model_retry(issue, workspace, worker_host, recipient, opts),
         :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
         {:ok, turn_session} <-
           run_codex_with_finalized_hooks(workspace, issue, recipient, opts, worker_host) do
      maybe_deliver_turn(issue, workspace, worker_host, turn_session, recipient, opts)
    end
  end

  defp resume_thread_id_for_issue(_issue, opts) do
    # A new orchestrator admission is a new agent task.  Its workspace and
    # persisted retry evidence provide continuity; replaying the old Codex
    # thread would resend the entire conversation on every CI fix attempt and
    # make input usage grow without bound.  Only an explicit caller request
    # may resume a thread (for example, an in-process recovery flow).
    Keyword.get(opts, :resume_thread_id)
  end

  defp send_codex_thread_info(recipient, %{id: issue_id}, thread_id)
       when is_pid(recipient) and is_binary(issue_id) and is_binary(thread_id) do
    send(recipient, {:worker_runtime_info, issue_id, %{resume_thread_id: thread_id}})
    :ok
  end

  defp send_codex_thread_info(_recipient, _issue, _thread_id), do: :ok

  defp delivery_summary(turn_session) do
    case turn_session[:result] do
      result when is_binary(result) -> String.slice(result, 0, 2_000)
      result -> inspect(result, limit: 20, printable_limit: 2_000)
    end
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end

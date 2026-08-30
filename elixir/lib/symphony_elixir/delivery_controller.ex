defmodule SymphonyElixir.DeliveryController do
  @moduledoc """
  Harness-owned delivery for one Codex workspace.

  This module is intentionally independent of `SymphonyElixir.Orchestrator`.
  The orchestrator may decide when a turn is admitted; this controller proves
  what happened after the turn, owns the delivery state, and exposes event
  handlers for webhook consumers.

  All command execution goes through an argv-based adapter.  No command is
  assembled as a shell string.  GitHub operations go through a separate
  adapter, which keeps this lifecycle fully testable without network access.
  """

  use GenServer

  alias SymphonyElixir.Delivery
  alias SymphonyElixir.Delivery.Event

  @type command_result :: {:ok, binary(), non_neg_integer()} | {:error, term()}
  @type command_adapter :: module() | map() | function()
  @type github_adapter :: module() | map() | function()
  @type result :: {:ok, Delivery.t()} | {:error, term(), Delivery.t()}

  @default_base_branch "main"
  @default_commit_prefix "symphony: deliver"
  @call_timeout_ms 300_000

  defmodule SystemCommandAdapter do
    @moduledoc false

    @spec run(Path.t(), [String.t()], keyword()) ::
            {:ok, binary(), non_neg_integer()} | {:error, term()}
    def run(cwd, argv, opts) when is_binary(cwd) and is_list(argv) do
      if Enum.all?(argv, &is_binary/1) do
        try do
          {output, status} =
            System.cmd("git", argv,
              cd: cwd,
              stderr_to_stdout: true,
              env: Keyword.get(opts, :env, [])
            )

          {:ok, output, status}
        rescue
          error -> {:error, {:command_exception, Exception.message(error)}}
        end
      else
        {:error, :invalid_argv}
      end
    end

    @spec cleanup_workspace(Path.t()) :: :ok | {:error, term()}
    def cleanup_workspace(workspace) do
      case SymphonyElixir.Workspace.remove(workspace) do
        {:ok, _removed} -> :ok
        {:error, reason, path} -> {:error, {:cleanup_failed, reason, path}}
      end
    end
  end

  defstruct [
    :delivery,
    :runtime_dir,
    :delivery_path,
    :command_adapter,
    :github_adapter,
    :clock,
    :base_branch,
    :commit_prefix,
    :cleanup_adapter,
    :command_timeout_ms
  ]

  @type t :: %__MODULE__{
          delivery: Delivery.t(),
          runtime_dir: Path.t(),
          delivery_path: Path.t(),
          command_adapter: command_adapter(),
          github_adapter: github_adapter() | nil,
          clock: (-> term()),
          base_branch: String.t(),
          commit_prefix: String.t(),
          cleanup_adapter: term(),
          command_timeout_ms: pos_integer()
        }

  # Public process API -------------------------------------------------------

  @doc "Starts one durable controller. Existing valid state is resumed."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Creates an in-memory controller state without starting a process."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    with {:ok, state} <- build_state(opts),
         :ok <- persist(state) do
      {:ok, state}
    end
  end

  @doc "Marks setup complete; normally this is called before the Codex turn."
  @spec setup_completed(GenServer.server(), map() | keyword()) :: result()
  def setup_completed(server, attrs \\ %{}), do: call(server, {:setup_completed, attrs})

  @doc "Consumes a completed Codex turn and runs the full delivery protocol."
  @spec codex_turn_completed(GenServer.server(), map() | keyword()) :: result()
  def codex_turn_completed(server, attrs \\ %{}), do: call(server, {:codex_turn_completed, attrs})

  @doc "Alias suitable for a worker completion callback."
  @spec handle_codex_turn_completed(GenServer.server(), map() | keyword()) :: result()
  def handle_codex_turn_completed(server, attrs \\ %{}), do: codex_turn_completed(server, attrs)

  @doc "Alias suitable for a worker completion callback named after the harness hook."
  @spec after_codex_turn(GenServer.server(), map() | keyword()) :: result()
  def after_codex_turn(server, attrs \\ %{}), do: codex_turn_completed(server, attrs)

  @doc "Applies a typed `SymphonyElixir.Delivery.Event` from another durable consumer."
  @spec handle_event(GenServer.server(), Delivery.event()) :: result()
  def handle_event(server, event), do: call(server, {:delivery_event, event})

  @doc "Admits a parked retry without allocating a new delivery/workspace."
  @spec admit_retry(GenServer.server()) :: result()
  def admit_retry(server), do: call(server, :admit_retry)

  @doc "Handles a provider recovery notification."
  @spec provider_available(GenServer.server()) :: result()
  def provider_available(server), do: call(server, :provider_available)

  @doc "Handles normalized webhook payloads without polling the whole board."
  @spec handle_webhook_event(GenServer.server(), atom() | String.t(), map()) :: result()
  def handle_webhook_event(server, event, payload),
    do: call(server, {:webhook_event, normalize_event_name(event), payload})

  @doc "Handles a check-run/check-suite payload."
  @spec handle_ci_event(GenServer.server(), map()) :: result()
  def handle_ci_event(server, payload), do: call(server, {:ci_event, payload})

  @doc "Handles a pull-request payload, including merge and conflict events."
  @spec handle_pull_request_event(GenServer.server(), map()) :: result()
  def handle_pull_request_event(server, payload), do: call(server, {:pull_request_event, payload})

  @doc "Retries cleanup for a lifecycle already in `:cleaning`."
  @spec cleanup(GenServer.server()) :: result()
  def cleanup(server), do: call(server, :cleanup)

  @doc "Returns the durable delivery snapshot."
  @spec snapshot(GenServer.server()) :: {:ok, Delivery.t()} | {:error, term()}
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Loads one persisted delivery without starting a process."
  @spec load(Path.t(), String.t()) :: {:ok, Delivery.t()} | {:error, term()}
  def load(runtime_dir, delivery_id) do
    path = delivery_path(runtime_dir, delivery_id)

    case File.read(path) do
      {:ok, json} -> Delivery.decode(json)
      {:error, reason} -> {:error, {:delivery_read_failed, path, reason}}
    end
  end

  @doc "Returns the recommended model profile for the current failure history."
  @spec escalation_recommendation(Delivery.t()) :: :luna | :terra | :sol
  def escalation_recommendation(%Delivery{failures: failures}) do
    case equivalent_failure_count(failures) do
      count when count >= 3 -> :sol
      2 -> :terra
      _ -> :luna
    end
  end

  # GenServer callbacks ------------------------------------------------------

  @impl true
  def init(opts) do
    with {:ok, state} <- build_state(opts),
         :ok <- persist(state) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state.delivery}, state}

  @impl true
  def handle_call({:setup_completed, attrs}, _from, state) do
    workspace = value(attrs, :workspace) || state.delivery.workspace

    with {:ok, delivery} <- transition(state.delivery, %Event.SetupCompleted{workspace: workspace}),
         {:ok, state} <- save(%{state | delivery: delivery}) do
      {:reply, {:ok, delivery}, state}
    else
      {:error, reason} -> {:reply, error_reply(state, reason), state}
    end
  end

  @impl true
  def handle_call({:codex_turn_completed, attrs}, _from, state) do
    case transition(state.delivery, %Event.CodexTurnCompleted{
           session_id: value(attrs, :session_id),
           summary: value(attrs, :summary)
         }) do
      {:ok, delivering} ->
        metadata =
          state.delivery.metadata
          |> Map.put("session_id", value(attrs, :session_id))
          |> Map.put("thread_id", value(attrs, :thread_id))
          |> Map.put("codex_summary", value(attrs, :summary))

        delivering = %{delivering | metadata: metadata}

        case save(%{state | delivery: delivering}) do
          {:ok, state} ->
            case deliver(state) do
              {:ok, state} -> {:reply, {:ok, state.delivery}, state}
              {:error, reason, state} -> {:reply, error_reply(state, reason), state}
            end

          {:error, reason} ->
            {:reply, error_reply(state, reason), state}
        end

      {:error, reason} ->
        {:reply, error_reply(state, reason), state}
    end
  end

  @impl true
  def handle_call(:admit_retry, _from, state) do
    case transition(state.delivery, %Event.RetryAvailable{}) do
      {:ok, delivery} -> reply_saved(state, delivery)
      {:error, reason} -> {:reply, error_reply(state, reason), state}
    end
  end

  @impl true
  def handle_call({:delivery_event, event}, _from, state), do: apply_event_reply(state, event)

  @impl true
  def handle_call(:provider_available, _from, state) do
    case transition(state.delivery, %Event.ProviderAvailable{}) do
      {:ok, delivery} -> reply_saved(state, delivery)
      {:error, reason} -> {:reply, error_reply(state, reason), state}
    end
  end

  @impl true
  def handle_call({:ci_event, payload}, _from, state) do
    case ci_event(payload) do
      {:ok, event} -> apply_webhook_event(state, event)
      :ignore -> {:reply, {:ok, state.delivery}, state}
    end
  end

  @impl true
  def handle_call({:pull_request_event, payload}, _from, state) do
    case pull_request_event(payload) do
      {:ok, event} -> apply_webhook_event(state, event)
      :ignore -> {:reply, {:ok, state.delivery}, state}
      {:error, reason} -> {:reply, error_reply(state, reason), state}
    end
  end

  @impl true
  def handle_call({:webhook_event, event_name, payload}, _from, state) do
    case event_name do
      event when event in [:check_run, :check_suite, :workflow_run] ->
        handle_webhook_call(state, ci_event(payload))

      :pull_request ->
        handle_webhook_call(state, pull_request_event(payload))

      _ ->
        {:reply, {:ok, state.delivery}, state}
    end
  end

  @impl true
  def handle_call(:cleanup, _from, state) do
    case perform_cleanup(state) do
      {:ok, state} -> {:reply, {:ok, state.delivery}, state}
      {:error, reason, state} -> {:reply, error_reply(state, reason), state}
    end
  end

  defp call(server, message), do: GenServer.call(server, message, @call_timeout_ms)

  # Delivery protocol --------------------------------------------------------

  defp deliver(state) do
    with :ok <- validate_workspace(state),
         {:ok, status} <- inspect_status(state),
         {:ok, commit_sha, status} <- stage_and_commit(state, status),
         :ok <- push(state),
         {:ok, pr} <- find_or_create_pr(state, commit_sha),
         {:ok, auto_merge} <- enable_auto_merge(state, pr, commit_sha),
         proof <- delivery_proof(state, commit_sha, pr, auto_merge, status),
         {:ok, delivery} <-
           transition(state.delivery, %Event.DeliveryCompleted{
             branch: expected_branch(state),
             commit_sha: commit_sha,
             pr_number: pr_number(pr)
           }),
         {:ok, state} <-
           save(%{state | delivery: %{delivery | delivery_proof: proof}}) do
      {:ok, state}
    else
      {:error, reason} -> delivery_failure(state, reason)
    end
  end

  defp validate_workspace(state) do
    workspace = state.delivery.workspace

    with :ok <- required_path(workspace, :missing_workspace),
         {:ok, top} <- git_output(state, ["rev-parse", "--show-toplevel"]),
         :ok <- same_path?(top, workspace),
         {:ok, branch} <- git_output(state, ["branch", "--show-current"]),
         :ok <- same_branch?(branch, expected_branch(state)) do
      :ok
    end
  end

  defp inspect_status(state) do
    with {:ok, output} <- git_output(state, ["status", "--porcelain=v1"]) do
      {:ok, output}
    end
  end

  defp stage_and_commit(state, status) do
    if String.trim(status) == "" do
      with {:ok, sha} <- git_output(state, ["rev-parse", "HEAD"]) do
        {:ok, sha, status}
      end
    else
      with :ok <- git_ok(state, ["add", "--all"]),
           {:ok, diff_status} <- git_run(state, ["diff", "--cached", "--quiet"]),
           :ok <- maybe_commit(state, diff_status),
           {:ok, sha} <- git_output(state, ["rev-parse", "HEAD"]) do
        {:ok, sha, status}
      end
    end
  end

  defp maybe_commit(_state, 0), do: :ok

  defp maybe_commit(state, 1) do
    git_ok(state, ["commit", "-m", "#{state.commit_prefix} #{delivery_identifier(state)}"])
  end

  defp maybe_commit(_state, status), do: {:error, {:git_diff_failed, status}}

  defp push(state) do
    git_ok(state, ["push", "--set-upstream", "origin", expected_branch(state)])
  end

  defp find_or_create_pr(state, commit_sha) do
    attrs = github_attrs(state, commit_sha)

    case github_call(state.github_adapter, :find_or_create_pull_request, [attrs]) do
      {:ok, pr} when is_map(pr) ->
        if valid_pr?(pr, expected_branch(state)) do
          {:ok, pr}
        else
          {:error, {:invalid_pull_request_proof, pr}}
        end

      {:ok, number} when is_integer(number) and number > 0 ->
        {:ok, %{"number" => number, "head" => expected_branch(state)}}

      {:error, reason} ->
        {:error, {:github, reason}}

      other ->
        {:error, {:invalid_github_response, :find_or_create_pull_request, other}}
    end
  end

  defp enable_auto_merge(state, pr, commit_sha) do
    case github_call(state.github_adapter, :enable_auto_merge, [pr, github_attrs(state, commit_sha)]) do
      :ok -> {:ok, %{"enabled" => true}}
      {:ok, proof} -> {:ok, %{"enabled" => true, "proof" => proof}}
      {:error, reason} -> {:error, {:github, reason}}
      other -> {:error, {:invalid_github_response, :enable_auto_merge, other}}
    end
  end

  defp delivery_proof(state, commit_sha, pr, auto_merge, status) do
    %{
      "workspace" => state.delivery.workspace,
      "branch" => expected_branch(state),
      "commit_sha" => commit_sha,
      "pr_number" => pr_number(pr),
      "status_before" => status,
      "pr" => pr,
      "auto_merge" => auto_merge,
      "delivered_at" => to_string(state.clock.())
    }
  end

  # Webhook protocol ---------------------------------------------------------

  defp handle_webhook_call(state, {:ok, event}), do: apply_webhook_event(state, event)
  defp handle_webhook_call(state, :ignore), do: {:reply, {:ok, state.delivery}, state}
  defp handle_webhook_call(state, {:error, reason}), do: {:reply, error_reply(state, reason), state}

  defp apply_webhook_event(state, %Event.ProviderUnavailable{} = event), do: apply_event_reply(state, event)

  defp apply_webhook_event(state, %Event.CiFailed{} = event), do: apply_event_reply(state, event)
  defp apply_webhook_event(state, %Event.CiPassed{} = event), do: apply_event_reply(state, event)
  defp apply_webhook_event(state, %Event.MergeConflict{} = event), do: apply_event_reply(state, event)

  defp apply_webhook_event(state, %Event.MergeCompleted{} = event) do
    case transition(state.delivery, event) do
      {:ok, merged} ->
        with {:ok, state} <- save(%{state | delivery: merged}),
             {:ok, cleaning} <- transition(state.delivery, %Event.CleanupStarted{}),
             {:ok, state} <- save(%{state | delivery: cleaning}),
             {:ok, state} <- perform_cleanup(state) do
          {:reply, {:ok, state.delivery}, state}
        else
          {:error, reason, state} -> {:reply, error_reply(state, reason), state}
          {:error, reason} -> {:reply, error_reply(%{state | delivery: merged}, reason), state}
        end

      {:error, reason} ->
        {:reply, error_reply(state, reason), state}
    end
  end

  defp apply_event_reply(state, event) do
    case transition(state.delivery, event) do
      {:ok, delivery} -> reply_saved(state, delivery)
      {:error, reason} -> {:reply, error_reply(state, reason), state}
    end
  end

  defp ci_event(payload) do
    conclusion = value(payload, :conclusion) || value(payload, :status)
    check_id = value(payload, :check_run_id) || value(payload, :id)

    cond do
      conclusion in [:success, "success", :passed, "passed"] ->
        {:ok, %Event.CiPassed{check_run_id: stringify(check_id)}}

      conclusion in [:failure, "failure", :failed, "failed", :cancelled, "cancelled", :timed_out, "timed_out"] ->
        {:ok, %Event.CiFailed{reason: value(payload, :failure_reason) || conclusion, check_run_id: stringify(check_id)}}

      provider_error?(payload) ->
        {:ok, %Event.ProviderUnavailable{reason: payload, retry_at: value(payload, :retry_at)}}

      true ->
        :ignore
    end
  end

  defp pull_request_event(payload) do
    cond do
      truthy?(value(payload, :merged)) ->
        case value(payload, :merge_commit_sha) || value(payload, :merge_sha) do
          nil -> {:error, :missing_merge_proof}
          sha -> {:ok, %Event.MergeCompleted{merge_sha: stringify(sha)}}
        end

      truthy?(value(payload, :mergeable_conflict)) or truthy?(value(payload, :conflict)) ->
        {:ok, %Event.MergeConflict{reason: value(payload, :reason) || :merge_conflict}}

      provider_error?(payload) ->
        {:ok, %Event.ProviderUnavailable{reason: payload, retry_at: value(payload, :retry_at)}}

      true ->
        :ignore
    end
  end

  # Cleanup and failures -----------------------------------------------------

  defp perform_cleanup(state) do
    with :ok <- ensure_cleaning(state),
         {:ok, cleanup_result} <- cleanup_call(state),
         :ok <- cleanup_success(cleanup_result),
         {:ok, delivery} <-
           transition(state.delivery, %Event.CleanupCompleted{workspace: state.delivery.workspace}),
         {:ok, state} <- save(%{state | delivery: delivery}) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp cleanup_success(:ok), do: :ok
  defp cleanup_success({:ok, _}), do: :ok
  defp cleanup_success({:error, reason}), do: {:error, reason}
  defp cleanup_success(other), do: {:error, {:invalid_cleanup_response, other}}

  defp ensure_cleaning(%{delivery: %{state: :cleaning}}), do: :ok
  defp ensure_cleaning(%{delivery: _delivery}), do: {:error, {:invalid_transition, :cleanup_started}}

  defp cleanup_call(%{cleanup_adapter: adapter, delivery: %{workspace: workspace}}) when is_function(adapter, 1),
    do: {:ok, adapter.(workspace)}

  defp cleanup_call(%{cleanup_adapter: adapter, delivery: %{workspace: workspace}}) do
    case adapter do
      %{cleanup_workspace: fun} when is_function(fun, 1) -> {:ok, fun.(workspace)}
      module when is_atom(module) -> {:ok, apply(module, :cleanup_workspace, [workspace])}
      _ -> {:error, :missing_cleanup_adapter}
    end
  rescue
    error -> {:error, {:cleanup_exception, Exception.message(error)}}
  end

  defp delivery_failure(state, reason) do
    if provider_error?(reason) do
      park_provider(state, reason)
    else
      classification = failure_classification(reason)
      event = %Event.DeliveryFailed{classification: classification, reason: reason}

      case transition(state.delivery, event) do
        {:ok, delivery} ->
          delivery = add_failure_recommendation(delivery)

          case save(%{state | delivery: delivery}) do
            {:ok, state} -> {:error, reason, state}
            {:error, save_reason} -> {:error, {:delivery_persist_failed, save_reason}, state}
          end

        {:error, transition_reason} ->
          {:error, transition_reason, state}
      end
    end
  end

  defp park_provider(state, reason) do
    event = %Event.ProviderUnavailable{reason: reason, retry_at: provider_retry_at(reason)}

    case transition(state.delivery, event) do
      {:ok, delivery} ->
        case save(%{state | delivery: delivery}) do
          {:ok, state} -> {:error, {:provider_unavailable, reason}, state}
          {:error, save_reason} -> {:error, {:delivery_persist_failed, save_reason}, state}
        end

      {:error, transition_reason} ->
        {:error, transition_reason, state}
    end
  end

  defp add_failure_recommendation(delivery) do
    count = equivalent_failure_count(delivery.failures)

    metadata =
      delivery.metadata
      |> Map.put("recommended_profile", Atom.to_string(escalation_recommendation(delivery)))
      |> Map.put("equivalent_failure_count", count)

    %{delivery | metadata: metadata}
  end

  defp equivalent_failure_count([]), do: 0

  defp equivalent_failure_count([first | rest]) do
    1 +
      (rest
       |> Enum.take_while(&same_failure?(&1, first))
       |> length())
  end

  defp same_failure?(left, right) do
    left.classification == right.classification and failure_fingerprint(left.reason) == failure_fingerprint(right.reason)
  end

  defp failure_fingerprint(reason) do
    :crypto.hash(:sha256, inspect(reason, limit: :infinity, printable_limit: :infinity))
    |> Base.encode16(case: :lower)
  end

  defp failure_classification(reason) do
    if merge_conflict?(reason), do: :code, else: :code
  end

  defp merge_conflict?(reason), do: match?({:merge_conflict, _}, reason) or value(reason, :classification) == :merge_conflict

  defp provider_retry_at(reason) do
    value(reason, :retry_at) || value(reason, :reset_at) ||
      case reason do
        {:github, nested} -> provider_retry_at(nested)
        {:command, _argv, nested} -> provider_retry_at(nested)
        {:rate_limited, retry_at} -> retry_at
        {:provider_unavailable, retry_at} -> retry_at
        _ -> nil
      end
  end

  # Persistence --------------------------------------------------------------

  defp build_state(opts) do
    runtime_dir = runtime_dir(opts)

    delivery_id =
      value(opts, :delivery_id) ||
        value(opts, :issue_id) ||
        case value(opts, :delivery) do
          %Delivery{issue_id: issue_id} -> issue_id
          _ -> nil
        end

    with :ok <- required_path(delivery_id, :missing_delivery_id),
         {:ok, delivery} <- load_or_build_delivery(opts, runtime_dir, delivery_id),
         :ok <- Delivery.validate(delivery) do
      {:ok,
       %__MODULE__{
         delivery: delivery,
         runtime_dir: runtime_dir,
         delivery_path: delivery_path(runtime_dir, delivery_id),
         command_adapter: value(opts, :command_adapter) || SystemCommandAdapter,
         github_adapter: value(opts, :github_adapter),
         clock: value(opts, :clock) || fn -> DateTime.utc_now() end,
         base_branch: value(opts, :base_branch) || @default_base_branch,
         commit_prefix: value(opts, :commit_prefix) || @default_commit_prefix,
         cleanup_adapter: value(opts, :cleanup_adapter) || SystemCommandAdapter,
         command_timeout_ms: value(opts, :command_timeout_ms) || 120_000
       }}
    end
  end

  defp load_or_build_delivery(opts, runtime_dir, delivery_id) do
    case value(opts, :delivery) do
      %Delivery{} = delivery ->
        {:ok, delivery}

      attrs when is_map(attrs) ->
        {:ok, Delivery.new(Map.put(attrs, :issue_id, delivery_id))}

      _ ->
        case load(runtime_dir, delivery_id) do
          {:ok, delivery} ->
            {:ok, delivery}

          {:error, {:delivery_read_failed, _path, :enoent}} ->
            {:ok,
             Delivery.new(
               issue_id: delivery_id,
               workspace: value(opts, :workspace),
               branch: value(opts, :branch)
             )}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp save(state) do
    case persist(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist(%{delivery: delivery, runtime_dir: runtime_dir, delivery_path: path}) do
    with :ok <- File.mkdir_p(runtime_dir),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- delivery_json(delivery),
         tmp <- path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive])),
         :ok <- File.write(tmp, encoded, [:binary]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, {:delivery_persist_failed, path, reason}}
    end
  end

  defp delivery_json(delivery) do
    delivery
    |> Delivery.serialize()
    |> json_safe()
    |> Jason.encode()
  end

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {json_safe(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
  defp json_safe(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp reply_saved(state, delivery) do
    case save(%{state | delivery: delivery}) do
      {:ok, state} -> {:reply, {:ok, delivery}, state}
      {:error, reason} -> {:reply, error_reply(state, reason), state}
    end
  end

  defp transition(delivery, event), do: Delivery.transition(delivery, event)

  defp error_reply(state, reason), do: {:error, reason, state.delivery}

  # Adapter boundaries -------------------------------------------------------

  defp git_run(state, argv) do
    case command_call(state.command_adapter, state.delivery.workspace, argv, state.command_timeout_ms) do
      {:ok, _output, status} -> {:ok, status}
      {:error, reason} -> {:error, {:command, argv, reason}}
    end
  end

  defp git_ok(state, argv) do
    case command_call(state.command_adapter, state.delivery.workspace, argv, state.command_timeout_ms) do
      {:ok, _output, 0} -> :ok
      {:ok, output, status} -> {:error, {:git_command_failed, argv, status, output}}
      {:error, reason} -> {:error, {:command, argv, reason}}
    end
  end

  defp git_output(state, argv) do
    case command_call(state.command_adapter, state.delivery.workspace, argv, state.command_timeout_ms) do
      {:ok, output, 0} -> {:ok, String.trim(output)}
      {:ok, output, status} -> {:error, {:git_command_failed, argv, status, output}}
      {:error, reason} -> {:error, {:command, argv, reason}}
    end
  end

  defp command_call(adapter, cwd, argv, timeout_ms) do
    result =
      cond do
        is_function(adapter, 3) -> adapter.(cwd, argv, timeout: timeout_ms)
        is_function(adapter, 2) -> adapter.(cwd, argv)
        is_map(adapter) and is_function(adapter[:run], 3) -> adapter[:run].(cwd, argv, timeout: timeout_ms)
        is_map(adapter) and is_function(adapter[:run], 2) -> adapter[:run].(cwd, argv)
        is_atom(adapter) -> apply(adapter, :run, [cwd, argv, [timeout: timeout_ms]])
        true -> {:error, :missing_command_adapter}
      end

    normalize_command_result(result)
  rescue
    error -> {:error, {:command_exception, Exception.message(error)}}
  end

  defp normalize_command_result({:ok, output, status}) when is_binary(output) and is_integer(status), do: {:ok, output, status}
  defp normalize_command_result({:ok, {output, status}}) when is_binary(output) and is_integer(status), do: {:ok, output, status}
  defp normalize_command_result({:ok, output}) when is_binary(output), do: {:ok, output, 0}
  defp normalize_command_result({:error, _reason} = error), do: error
  defp normalize_command_result(other), do: {:error, {:invalid_command_response, other}}

  defp github_call(adapter, operation, args) do
    cond do
      is_nil(adapter) -> {:error, :missing_github_adapter}
      is_function(adapter, 2) -> adapter.(operation, args)
      is_map(adapter) and is_function(adapter[operation], length(args)) -> apply(adapter[operation], args)
      is_atom(adapter) -> apply(adapter, operation, args)
      true -> {:error, {:missing_github_operation, operation}}
    end
  rescue
    error -> {:error, {:github_exception, Exception.message(error)}}
  end

  # Validation and helpers ---------------------------------------------------

  defp github_attrs(state, commit_sha) do
    %{
      issue_id: delivery_identifier(state),
      title: pull_request_title(state),
      body: pull_request_body(state),
      workspace: state.delivery.workspace,
      branch: expected_branch(state),
      base_branch: state.base_branch,
      commit_sha: commit_sha,
      session_id: Map.get(state.delivery.metadata, "session_id")
    }
  end

  defp pull_request_title(state) do
    identifier = Map.get(state.delivery.metadata, "identifier")
    title = Map.get(state.delivery.metadata, "title")

    case {identifier, title} do
      {identifier, title} when is_binary(identifier) and is_binary(title) -> "#{identifier}: #{title}"
      {_identifier, title} when is_binary(title) -> title
      {identifier, _title} when is_binary(identifier) -> "Polyphony: #{identifier}"
      _ -> "Polyphony delivery"
    end
  end

  defp pull_request_body(state) do
    metadata = state.delivery.metadata
    description = Map.get(metadata, "description")
    issue_url = Map.get(metadata, "url")
    summary = Map.get(metadata, "codex_summary")

    [
      description,
      if(is_binary(issue_url), do: "Source issue: #{issue_url}"),
      if(is_binary(summary) and String.trim(summary) != "", do: "## Worker handoff\n\n#{summary}"),
      "---\nDelivered by Polyphony. CI, retry, merge, and cleanup are harness-owned."
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end

  defp valid_pr?(pr, branch) do
    head = value(pr, :head)
    head_branch = if is_map(head), do: value(head, :ref) || value(head, :branch), else: head

    is_integer(pr_number(pr)) and pr_number(pr) > 0 and
      (head_branch == branch or value(pr, :head_branch) == branch)
  end

  defp pr_number(pr), do: value(pr, :number) || value(pr, :pr_number)

  defp expected_branch(state) do
    state.delivery.branch || Map.get(state.delivery.metadata, "branch") || "agent/#{delivery_identifier(state)}"
  end

  defp delivery_identifier(state), do: state.delivery.issue_id

  defp same_path?(actual, expected) do
    if Path.expand(actual) == Path.expand(expected) do
      :ok
    else
      {:error, {:workspace_not_canonical, actual, expected}}
    end
  end

  defp same_branch?(actual, expected) do
    actual = String.trim(actual)
    expected = String.trim(expected)

    cond do
      actual == expected and actual in ["main", "master", "trunk"] ->
        {:error, {:workspace_non_unique_branch, actual}}

      actual == expected ->
        :ok

      true ->
        {:error, {:workspace_wrong_branch, actual, expected}}
    end
  end

  defp required_path(value, _reason) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp required_path(_value, reason), do: {:error, reason}

  defp runtime_dir(opts) do
    dir =
      value(opts, :runtime_dir) ||
        System.get_env("POLYPHONY_RUNTIME_STATE_DIR") ||
        Path.join(File.cwd!(), ".symphony-runtime")

    Path.expand(dir)
  end

  defp delivery_path(runtime_dir, delivery_id) do
    safe_id =
      delivery_id
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")

    Path.join([Path.expand(runtime_dir), "deliveries", safe_id <> ".json"])
  end

  defp normalize_event_name(event) when is_atom(event), do: event

  defp normalize_event_name(event) when is_binary(event) do
    case event do
      "check_run" -> :check_run
      "check_suite" -> :check_suite
      "workflow_run" -> :workflow_run
      "pull_request" -> :pull_request
      _ -> :unknown
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(list, key) when is_list(list), do: Keyword.get(list, key)
  defp value(_value, _key), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp provider_error?(reason) do
    text = inspect(reason, limit: 20, printable_limit: 2_000) |> String.downcase()

    match?({:provider, _}, reason) or
      match?({:rate_limited, _}, reason) or
      value(reason, :provider_error) == true or
      value(reason, :rate_limited) == true or
      String.contains?(text, "rate limit") or
      String.contains?(text, "rate_limit") or
      String.contains?(text, "github_api") or
      String.contains?(text, "provider unavailable") or
      String.contains?(text, "status: 429") or
      String.contains?(text, "status: 503")
  end
end

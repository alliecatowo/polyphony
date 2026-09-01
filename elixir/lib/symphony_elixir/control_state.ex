defmodule SymphonyElixir.ControlState do
  @moduledoc """
  Durable, side-effect-free control state for one Polyphony runtime.

  This module deliberately does not own a process and never starts or kills
  anything. It provides the state machine and persistence boundary that a
  scheduler, web server, or supervisor can use independently.

  A pause closes admission immediately. `:pausing` is the observable request
  state, while `:draining` records that active work is being allowed to finish.
  Neither state becomes `:paused` until execution, delivery, and cleanup
  obligations are all zero.
  """

  @version 1

  @states [:running, :pausing, :paused, :draining, :stopping, :stopped, :recovering]
  @obligation_kinds [:execution, :delivery, :cleanup]
  @admission_kinds [:worker, :retry, :reviewer, :reconciler]

  @type state_name :: unquote(Enum.reduce(@states, &{:|, [], [&1, &2]}))
  @type obligation_kind :: :execution | :delivery | :cleanup
  @type admission_kind :: :worker | :retry | :reviewer | :reconciler
  @type obligations :: %{
          execution: non_neg_integer(),
          delivery: non_neg_integer(),
          cleanup: non_neg_integer()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          state: state_name(),
          obligations: obligations(),
          path: String.t() | nil,
          generation: non_neg_integer(),
          updated_at_ms: integer(),
          metadata: map(),
          recovery_target: state_name() | nil,
          recovery_reason: term() | nil,
          stop_mode: :graceful | :hard | nil,
          stop_scope: map() | nil,
          stop_reason: term() | nil
        }

  defstruct version: @version,
            state: :running,
            obligations: %{execution: 0, delivery: 0, cleanup: 0},
            path: nil,
            generation: 0,
            updated_at_ms: 0,
            metadata: %{},
            recovery_target: nil,
            recovery_reason: nil,
            stop_mode: nil,
            stop_scope: nil,
            stop_reason: nil

  @doc "Creates an in-memory running state. `:path` and `:now_ms` are injectable."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    obligations =
      opts
      |> Keyword.get(:obligations, %{})
      |> initial_obligations!()

    %__MODULE__{
      obligations: obligations,
      path: Keyword.get(opts, :path),
      updated_at_ms: Keyword.get(opts, :now_ms, now_ms()),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Returns the supported control states, useful for serializers and UIs."
  @spec states() :: [state_name()]
  def states, do: @states

  @doc "Returns the three obligation counters tracked by the drain gate."
  @spec obligation_kinds() :: [obligation_kind()]
  def obligation_kinds, do: @obligation_kinds

  @doc "Returns the worker roles controlled by admission."
  @spec admission_kinds() :: [admission_kind()]
  def admission_kinds, do: @admission_kinds

  @doc "Whether all execution, delivery, and cleanup obligations are complete."
  @spec obligations_zero?(t()) :: boolean()
  def obligations_zero?(%__MODULE__{obligations: obligations}) do
    Enum.all?(obligations, fn {_kind, count} -> count == 0 end)
  end

  @doc "Applies a pure control command without touching the filesystem or OS."
  @spec transition(t(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{} = state, command, opts \\ []) do
    case command do
      :pause -> request_pause(state, opts)
      :drain -> begin_drain(state, opts)
      :advance -> settle(state, opts)
      :resume -> resume(state, opts)
      :recover -> begin_recovery(state, opts)
      :complete_recovery -> complete_recovery(state, opts)
      :stop -> stop(state, opts)
      :complete_stop -> complete_stop(state, opts)
      _ -> {:error, {:unknown_command, command}}
    end
  end

  @doc "Requests a pause and closes admission immediately."
  @spec request_pause(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def request_pause(%__MODULE__{state: state} = current, opts \\ []) do
    case state do
      :running -> current |> move_to(:pausing, opts) |> settle(opts)
      :pausing -> settle(current, opts)
      :draining -> {:ok, current}
      :paused -> {:ok, current}
      :recovering -> {:error, :recovery_in_progress}
      :stopping -> {:error, :stop_in_progress}
      :stopped -> {:error, :stopped}
    end
  end

  @doc "Starts draining active work; it reaches paused only at zero obligations."
  @spec begin_drain(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def begin_drain(%__MODULE__{state: state} = current, opts \\ []) do
    case state do
      state when state in [:running, :pausing, :draining] ->
        current |> move_to(:draining, opts) |> settle(opts)

      :paused ->
        {:ok, current}

      :recovering ->
        {:error, :recovery_in_progress}

      :stopping ->
        {:error, :stop_in_progress}

      :stopped ->
        {:error, :stopped}
    end
  end

  @doc "Re-evaluates a pending pause or stop after an obligation changes."
  @spec settle(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def settle(%__MODULE__{} = current, opts \\ []) do
    next_state =
      case {current.state, obligations_zero?(current)} do
        {state, true} when state in [:pausing, :draining] -> :paused
        {:stopping, true} -> :stopped
        _ -> current.state
      end

    if next_state == current.state do
      {:ok, current}
    else
      {:ok, move_to(current, next_state, opts)}
    end
  end

  @doc "Replaces obligation counters and settles a pending drain if possible."
  @spec set_obligations(t(), map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def set_obligations(%__MODULE__{} = current, updates, opts \\ []) do
    with {:ok, obligations} <- merge_obligations(current.obligations, updates) do
      current
      |> Map.put(:obligations, obligations)
      |> touch(opts)
      |> settle(opts)
    end
  end

  @doc "Adds or removes one obligation count without allowing a negative count."
  @spec update_obligation(t(), obligation_kind(), integer(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def update_obligation(current, kind, delta, opts \\ [])

  @spec update_obligation(t(), obligation_kind(), integer(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def update_obligation(%__MODULE__{} = current, kind, delta, opts)
      when kind in @obligation_kinds and is_integer(delta) do
    next_count = Map.fetch!(current.obligations, kind) + delta

    if next_count < 0 do
      {:error, {:negative_obligation, kind, next_count}}
    else
      set_obligations(current, %{kind => next_count}, opts)
    end
  end

  def update_obligation(_current, kind, _delta, _opts),
    do: {:error, {:invalid_obligation, kind}}

  @doc "Moves a paused or stopped runtime into recovery before resuming admission."
  @spec resume(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def resume(%__MODULE__{state: state} = current, opts \\ []) do
    case state do
      state when state in [:pausing, :draining, :paused, :stopped] ->
        {:ok,
         current
         |> Map.put(:recovery_target, :running)
         |> Map.put(:recovery_reason, Keyword.get(opts, :reason, :resume_requested))
         |> move_to(:recovering, opts)}

      :recovering ->
        {:ok, current}

      :running ->
        {:ok, current}

      :stopping ->
        # A hard stop terminates execution immediately, but it deliberately
        # preserves delivery records so PR/CI progress can be reconciled on
        # the next run. Do not make those durable delivery obligations turn a
        # recoverable runtime into a permanent stop.
        if current.stop_mode == :hard and current.obligations.execution == 0 do
          {:ok,
           current
           |> Map.put(:recovery_target, :running)
           |> Map.put(:recovery_reason, Keyword.get(opts, :reason, :resume_after_hard_stop))
           |> move_to(:recovering, opts)}
        else
          {:error, :stop_in_progress}
        end
    end
  end

  @doc "Marks a runtime as requiring reconciliation before admission can resume."
  @spec begin_recovery(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def begin_recovery(%__MODULE__{state: state} = current, opts \\ []) do
    if state == :recovering do
      {:ok, current}
    else
      target = Keyword.get(opts, :target, if(state == :stopped, do: :stopped, else: :running))

      if target in [:running, :paused, :stopped] do
        {:ok,
         current
         |> Map.put(:recovery_target, target)
         |> Map.put(:recovery_reason, Keyword.get(opts, :reason, :restart_reconciliation))
         |> move_to(:recovering, opts)}
      else
        {:error, {:invalid_recovery_target, target}}
      end
    end
  end

  @doc "Completes recovery only after the caller has reconciled external obligations."
  @spec complete_recovery(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def complete_recovery(current, opts \\ [])

  @spec complete_recovery(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def complete_recovery(%__MODULE__{state: :recovering} = current, opts) do
    if Keyword.get(opts, :reconciled?, false) do
      target = current.recovery_target || :running

      {:ok,
       current
       |> Map.put(:recovery_target, nil)
       |> Map.put(:recovery_reason, nil)
       |> move_to(target, opts)}
    else
      {:error, :reconciliation_required}
    end
  end

  def complete_recovery(_current, _opts), do: {:error, :not_recovering}

  @doc "Begins graceful stopping; pending obligations keep the state stopping."
  @spec stop(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def stop(%__MODULE__{state: state} = current, opts \\ []) do
    case state do
      :stopped -> {:ok, current}
      :stopping -> settle(current, opts)
      _ -> current |> move_to(:stopping, opts) |> settle(opts)
    end
  end

  @doc "Acknowledges that the scoped stop has completed; it does no OS work."
  @spec complete_stop(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def complete_stop(%__MODULE__{} = current, opts \\ []) do
    case current.state do
      state when state in [:stopping, :stopped] -> {:ok, move_to(current, :stopped, opts)}
      _ -> {:error, :stop_not_requested}
    end
  end

  @doc "Returns a scoped hard-stop action; the caller decides whether to execute it."
  @spec hard_stop(t(), map(), keyword()) :: {:ok, t(), map()} | {:error, term()}
  def hard_stop(%__MODULE__{} = current, scope, opts \\ []) do
    with {:ok, normalized_scope} <- normalize_scope(scope) do
      next =
        current
        |> Map.put(:stop_mode, :hard)
        |> Map.put(:stop_scope, normalized_scope)
        |> Map.put(:stop_reason, Keyword.get(opts, :reason, :operator_requested))
        |> move_to(:stopping, opts)

      action = %{
        type: :hard_stop,
        operation: :terminate_project_cgroup,
        scope: normalized_scope,
        performed?: false,
        os_kill_performed?: false
      }

      {:ok, next, action}
    end
  end

  @doc "Returns an admission decision for a worker, retry, reviewer, or reconciler."
  @spec admission(t(), admission_kind() | String.t()) :: map()
  def admission(%__MODULE__{} = current, kind) do
    case normalize_admission_kind(kind) do
      {:ok, role} ->
        decision =
          case current.state do
            :running -> {:admit, :running}
            :recovering -> {:wait, :recovery_in_progress}
            :pausing -> {:wait, :pause_requested}
            :draining -> {:wait, :draining}
            :paused -> {:wait, :paused}
            :stopping -> {:reject, :stopping}
            :stopped -> {:reject, :stopped}
          end

        {decision_name, reason} = decision
        %{role: role, decision: decision_name, reason: reason, generation: current.generation}

      {:error, reason} ->
        %{role: kind, decision: :reject, reason: reason, generation: current.generation}
    end
  end

  @doc "Convenience predicate; only a running state admits new work."
  @spec admit?(t(), admission_kind() | String.t()) :: boolean()
  def admit?(%__MODULE__{} = current, kind), do: admission(current, kind).decision == :admit

  @doc "Atomically writes a versioned JSON snapshot using rename in the same directory."
  @spec persist(t(), String.t() | nil) :: :ok | {:error, term()}
  def persist(%__MODULE__{} = current, path \\ nil) do
    path = path || current.path

    with :ok <- validate_path(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(to_persisted_map(current)),
         temp_path = temporary_path(path),
         result <- write_and_rename(encoded, temp_path, path) do
      result
    end
  end

  @doc "Alias for `persist/2`."
  @spec save(t(), String.t() | nil) :: :ok | {:error, term()}
  def save(%__MODULE__{} = current, path \\ nil), do: persist(current, path)

  @doc "Loads a snapshot from an injectable path; `recover?: true` gates it in recovery."
  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) do
    with :ok <- validate_path(path),
         {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, current} <- from_persisted_map(decoded, path) do
      if Keyword.get(opts, :recover?, false) do
        begin_recovery(current, opts)
      else
        {:ok, current}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Applies a pure transition and persists the resulting state when requested."
  @spec transition_and_persist(t(), atom(), String.t() | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  def transition_and_persist(%__MODULE__{} = current, command, path \\ nil, opts \\ []) do
    with {:ok, next} <- transition(current, command, opts),
         :ok <- persist(next, path || next.path || current.path) do
      {:ok, next}
    end
  end

  defp move_to(%__MODULE__{} = current, next_state, opts) do
    if current.state == next_state do
      current
    else
      current
      |> Map.put(:state, next_state)
      |> touch(opts)
    end
  end

  defp touch(%__MODULE__{} = current, opts) do
    current
    |> Map.update!(:generation, &(&1 + 1))
    |> Map.put(:updated_at_ms, Keyword.get(opts, :now_ms, now_ms()))
  end

  defp merge_obligations(current, updates) when is_list(updates),
    do: merge_obligations(current, Map.new(updates))

  defp merge_obligations(current, updates) when is_map(updates) do
    unknown = Map.keys(updates) -- @obligation_kinds

    cond do
      unknown != [] ->
        {:error, {:invalid_obligation, hd(unknown)}}

      true ->
        Enum.reduce_while(@obligation_kinds, {:ok, current}, fn kind, {:ok, acc} ->
          case Map.fetch(updates, kind) do
            :error -> {:cont, {:ok, acc}}
            {:ok, count} when is_integer(count) and count >= 0 -> {:cont, {:ok, Map.put(acc, kind, count)}}
            {:ok, count} -> {:halt, {:error, {:invalid_obligation_count, kind, count}}}
          end
        end)
    end
  end

  defp merge_obligations(_current, updates), do: {:error, {:invalid_obligations, updates}}

  defp initial_obligations!(updates) do
    case merge_obligations(%{execution: 0, delivery: 0, cleanup: 0}, updates) do
      {:ok, obligations} -> obligations
      {:error, reason} -> raise ArgumentError, "invalid control-state obligations: #{inspect(reason)}"
    end
  end

  defp normalize_admission_kind(kind) when kind in @admission_kinds, do: {:ok, kind}

  defp normalize_admission_kind(kind) when is_binary(kind) do
    case Enum.find(@admission_kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, {:invalid_admission_kind, kind}}
      role -> {:ok, role}
    end
  end

  defp normalize_admission_kind(kind), do: {:error, {:invalid_admission_kind, kind}}

  defp normalize_scope(scope) when is_map(scope) do
    project = Map.get(scope, :project) || Map.get(scope, "project")
    cgroup = Map.get(scope, :cgroup) || Map.get(scope, "cgroup")

    if non_empty_binary?(project) and non_empty_binary?(cgroup) do
      {:ok, %{project: project, cgroup: cgroup}}
    else
      {:error, :invalid_stop_scope}
    end
  end

  defp normalize_scope(_scope), do: {:error, :invalid_stop_scope}

  defp non_empty_binary?(value), do: is_binary(value) and byte_size(String.trim(value)) > 0

  defp validate_path(path) when is_binary(path) do
    if String.trim(path) == "", do: {:error, :invalid_persistence_path}, else: :ok
  end

  defp validate_path(_path), do: {:error, :invalid_persistence_path}

  defp temporary_path(path), do: path <> ".tmp-" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp write_and_rename(encoded, temp_path, path) do
    result =
      case File.open(temp_path, [:write, :binary, :exclusive]) do
        {:ok, device} ->
          write_result =
            try do
              with :ok <- IO.binwrite(device, encoded),
                   :ok <- :file.sync(device),
                   :ok <- File.close(device),
                   :ok <- File.rename(temp_path, path) do
                :ok
              end
            after
              File.close(device)
            end

          write_result

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, reason}
    end
  end

  defp to_persisted_map(%__MODULE__{} = current) do
    %{
      "version" => current.version,
      "state" => Atom.to_string(current.state),
      "obligations" => Map.new(current.obligations, fn {kind, count} -> {Atom.to_string(kind), count} end),
      "generation" => current.generation,
      "updated_at_ms" => current.updated_at_ms,
      "metadata" => current.metadata,
      "recovery_target" => encode_optional_atom(current.recovery_target),
      "recovery_reason" => current.recovery_reason,
      "stop_mode" => encode_optional_atom(current.stop_mode),
      "stop_scope" => current.stop_scope,
      "stop_reason" => current.stop_reason
    }
  end

  defp from_persisted_map(decoded, path) when is_map(decoded) do
    with {:ok, version} <- fetch_non_negative(decoded, "version"),
         :ok <- validate_version(version),
         {:ok, state} <- decode_state(Map.get(decoded, "state")),
         {:ok, obligations} <- decode_obligations(Map.get(decoded, "obligations")),
         {:ok, generation} <- fetch_non_negative(decoded, "generation"),
         {:ok, updated_at_ms} <- fetch_integer(decoded, "updated_at_ms"),
         {:ok, recovery_target} <- decode_optional_state(Map.get(decoded, "recovery_target")),
         {:ok, stop_mode} <- decode_optional_atom(Map.get(decoded, "stop_mode"), [:graceful, :hard]) do
      {:ok,
       %__MODULE__{
         version: version,
         state: state,
         obligations: obligations,
         path: path,
         generation: generation,
         updated_at_ms: updated_at_ms,
         metadata: Map.get(decoded, "metadata", %{}),
         recovery_target: recovery_target,
         recovery_reason: Map.get(decoded, "recovery_reason"),
         stop_mode: stop_mode,
         stop_scope: Map.get(decoded, "stop_scope"),
         stop_reason: Map.get(decoded, "stop_reason")
       }}
    end
  end

  defp from_persisted_map(_decoded, _path), do: {:error, :invalid_snapshot}

  defp validate_version(@version), do: :ok
  defp validate_version(version), do: {:error, {:unsupported_snapshot_version, version}}

  defp fetch_non_negative(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_snapshot_field, key, value}}
    end
  end

  defp fetch_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> {:ok, value}
      value -> {:error, {:invalid_snapshot_field, key, value}}
    end
  end

  defp decode_state(value) when is_binary(value) do
    case Enum.find(@states, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_snapshot_state, value}}
      state -> {:ok, state}
    end
  end

  defp decode_state(value), do: {:error, {:invalid_snapshot_state, value}}

  defp decode_optional_state(nil), do: {:ok, nil}
  defp decode_optional_state(value), do: decode_state(value)

  defp decode_optional_atom(nil, _allowed), do: {:ok, nil}

  defp decode_optional_atom(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_snapshot_atom, value}}
      atom -> {:ok, atom}
    end
  end

  defp decode_optional_atom(value, _allowed), do: {:error, {:invalid_snapshot_atom, value}}

  defp encode_optional_atom(nil), do: nil
  defp encode_optional_atom(atom), do: Atom.to_string(atom)

  defp decode_obligations(value) when is_map(value) do
    updates =
      Enum.reduce(@obligation_kinds, %{}, fn kind, acc ->
        Map.put(acc, kind, Map.get(value, Atom.to_string(kind)))
      end)

    if Enum.any?(updates, fn {_kind, count} -> is_nil(count) end) do
      {:error, :invalid_snapshot_obligations}
    else
      merge_obligations(%{execution: 0, delivery: 0, cleanup: 0}, updates)
    end
  end

  defp decode_obligations(_value), do: {:error, :invalid_snapshot_obligations}

  defp now_ms, do: System.system_time(:millisecond)
end

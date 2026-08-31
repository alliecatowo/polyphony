defmodule SymphonyElixir.Delivery do
  @moduledoc """
  Pure delivery lifecycle for one issue/workspace run.

  A Codex turn only produces material to deliver. It never proves success. The
  harness must carry the run through PR delivery, CI, merge, and cleanup before
  it can become `:complete`.

  `:waiting_provider` is a parked state. It remembers the state that was active
  when the provider became unavailable and resumes that state after
  `ProviderAvailable` arrives. It is deliberately distinct from `:failed` so
  provider outages cannot consume a retry or escalation budget.
  """

  @version 1

  @states [
    :setup,
    :executing,
    :delivering,
    :waiting_ci,
    :retry_ready,
    :waiting_merge,
    :merged,
    :cleaning,
    :complete,
    :waiting_provider,
    :failed
  ]

  @counted_failure_classifications [:code, :ci]

  defmodule Event do
    @moduledoc "Typed events accepted by `SymphonyElixir.Delivery.transition/2`."

    defmodule SetupCompleted do
      @enforce_keys []
      defstruct [:workspace]
      @type t :: %__MODULE__{workspace: String.t() | nil}
      @spec new(keyword() | map()) :: t()
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule CodexTurnCompleted do
      @enforce_keys []
      defstruct [:session_id, :summary]
      @type t :: %__MODULE__{session_id: String.t() | nil, summary: String.t() | nil}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule DeliveryCompleted do
      @enforce_keys []
      defstruct [:branch, :commit_sha, :pr_number]

      @type t :: %__MODULE__{
              branch: String.t() | nil,
              commit_sha: String.t() | nil,
              pr_number: pos_integer() | nil
            }

      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule CodeFailure do
      @enforce_keys []
      defstruct [:reason]
      @type t :: %__MODULE__{reason: term()}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule CodexTurnFailed do
      @enforce_keys []
      defstruct [:reason]
      @type t :: %__MODULE__{reason: term()}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule CiPassed do
      @enforce_keys []
      defstruct [:check_run_id]
      @type t :: %__MODULE__{check_run_id: String.t() | nil}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule CiFailed do
      @enforce_keys []
      defstruct [:reason, :check_run_id]
      @type t :: %__MODULE__{reason: term(), check_run_id: String.t() | nil}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule MergeConflict do
      @enforce_keys []
      defstruct [:reason]
      @type t :: %__MODULE__{reason: term()}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule MergeCompleted do
      @enforce_keys []
      defstruct [:merge_sha]
      @type t :: %__MODULE__{merge_sha: String.t() | nil}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule CleanupStarted do
      @enforce_keys []
      defstruct []
      @type t :: %__MODULE__{}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule CleanupCompleted do
      @enforce_keys []
      defstruct [:workspace]
      @type t :: %__MODULE__{workspace: String.t() | nil}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule RetryAvailable do
      @enforce_keys []
      defstruct []
      @type t :: %__MODULE__{}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule DeliveryFailed do
      @enforce_keys []
      defstruct [:classification, :reason]

      @type t :: %__MODULE__{
              classification: :code | :ci | :provider | :capacity | :unknown,
              reason: term()
            }

      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule Escalated do
      @enforce_keys []
      defstruct [:classification, :reason]

      @type t :: %__MODULE__{classification: :code | :ci, reason: term()}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule ProviderUnavailable do
      @enforce_keys []
      defstruct [:reason, :retry_at]
      @type t :: %__MODULE__{reason: term(), retry_at: term()}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule ProviderAvailable do
      @enforce_keys []
      defstruct []
      @type t :: %__MODULE__{}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end

    defmodule PermanentFailure do
      @enforce_keys []
      defstruct [:reason]
      @type t :: %__MODULE__{reason: term()}
      @spec new(keyword() | map()) :: t()
      def new(attrs \\ []), do: struct!(__MODULE__, attrs)
    end
  end

  @type state_name ::
          :setup
          | :executing
          | :delivering
          | :waiting_ci
          | :retry_ready
          | :waiting_merge
          | :merged
          | :cleaning
          | :complete
          | :waiting_provider
          | :failed

  @type failure_classification :: :code | :ci | :provider | :capacity | :unknown

  @type event ::
          Event.SetupCompleted.t()
          | Event.CodexTurnCompleted.t()
          | Event.DeliveryCompleted.t()
          | Event.CodeFailure.t()
          | Event.CodexTurnFailed.t()
          | Event.CiPassed.t()
          | Event.CiFailed.t()
          | Event.MergeConflict.t()
          | Event.MergeCompleted.t()
          | Event.CleanupStarted.t()
          | Event.CleanupCompleted.t()
          | Event.RetryAvailable.t()
          | Event.DeliveryFailed.t()
          | Event.Escalated.t()
          | Event.ProviderUnavailable.t()
          | Event.ProviderAvailable.t()
          | Event.PermanentFailure.t()

  @type failure_record :: %{
          classification: failure_classification(),
          reason: term()
        }

  @type t :: %__MODULE__{
          issue_id: String.t() | nil,
          workspace: String.t() | nil,
          branch: String.t() | nil,
          commit_sha: String.t() | nil,
          pr_number: pos_integer() | nil,
          state: state_name(),
          resume_state: state_name() | nil,
          provider_error: term(),
          provider_retry_at: term(),
          failure_reason: term(),
          ci_status: :green | :red | nil,
          delivery_proof: map() | nil,
          merge_proof: map() | nil,
          cleanup_proof: map() | nil,
          attempt: non_neg_integer(),
          escalation: non_neg_integer(),
          failures: [failure_record()],
          escalations: [failure_record()],
          last_event: atom() | nil,
          metadata: map()
        }

  defstruct [
    :issue_id,
    :workspace,
    :branch,
    :commit_sha,
    :pr_number,
    :provider_error,
    :provider_retry_at,
    :failure_reason,
    :delivery_proof,
    :merge_proof,
    :cleanup_proof,
    :last_event,
    state: :setup,
    resume_state: nil,
    ci_status: nil,
    attempt: 0,
    escalation: 0,
    failures: [],
    escalations: [],
    metadata: %{}
  ]

  @doc "Returns a new lifecycle in `:setup`."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    struct!(__MODULE__, attrs)
  end

  @doc "Returns all lifecycle states in their canonical serialization order."
  @spec states() :: [state_name()]
  def states, do: @states

  @doc "Returns true for terminal states. Provider waits are resumable, not terminal."
  @spec terminal?(state_name()) :: boolean()
  def terminal?(state), do: state in [:complete, :failed]

  @doc "Returns true when a run is parked waiting for provider recovery."
  @spec waiting_for_provider?(t() | state_name()) :: boolean()
  def waiting_for_provider?(%__MODULE__{state: state}), do: state == :waiting_provider
  def waiting_for_provider?(state), do: state == :waiting_provider

  @doc "Returns the action the harness should take next for a lifecycle state."
  @spec next_action(t() | state_name()) :: atom()
  def next_action(%__MODULE__{state: state}), do: next_action(state)
  def next_action(:setup), do: :prepare_workspace
  def next_action(:executing), do: :run_codex
  def next_action(:delivering), do: :verify_and_deliver
  def next_action(:waiting_ci), do: :wait_for_ci
  def next_action(:retry_ready), do: :admit_retry
  def next_action(:waiting_merge), do: :wait_for_merge
  def next_action(:merged), do: :begin_cleanup
  def next_action(:cleaning), do: :cleanup_workspace
  def next_action(:complete), do: :none
  def next_action(:waiting_provider), do: :wait_for_provider
  def next_action(:failed), do: :none

  @doc "Returns whether an event can be applied without changing the lifecycle."
  @spec valid_transition?(t(), event()) :: boolean()
  def valid_transition?(delivery, event) do
    match?({:ok, _}, transition(delivery, event))
  end

  @doc "Applies one typed event and validates the resulting lifecycle."
  @spec transition(t(), event()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{} = delivery, event) do
    with :ok <- validate_current(delivery),
         {:ok, transitioned} <- do_transition(delivery, event),
         :ok <- validate(transitioned) do
      {:ok, transitioned}
    end
  end

  @doc "Alias for `transition/2`, useful at event-consumption call sites."
  @spec apply_event(t(), event()) :: {:ok, t()} | {:error, term()}
  def apply_event(delivery, event), do: transition(delivery, event)

  @doc "Returns true when all lifecycle invariants hold."
  @spec valid?(t()) :: boolean()
  def valid?(delivery), do: validate(delivery) == :ok

  @doc "Returns `:ok` or all invariant violations for a lifecycle."
  @spec validate(t()) :: :ok | {:error, [term()]}
  def validate(%__MODULE__{} = delivery) do
    errors =
      []
      |> check_known_state(delivery)
      |> check_non_negative_counter(delivery, :attempt)
      |> check_non_negative_counter(delivery, :escalation)
      |> check_failure_history(delivery)
      |> check_provider_wait(delivery)
      |> check_delivery_proof(delivery)
      |> check_ci_proof(delivery)
      |> check_merge_proof(delivery)
      |> check_cleanup_proof(delivery)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc "Serializes a lifecycle to a versioned map. Use `encode/1` for JSON."
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = delivery) do
    %{
      "version" => @version,
      "issue_id" => delivery.issue_id,
      "workspace" => delivery.workspace,
      "branch" => delivery.branch,
      "commit_sha" => delivery.commit_sha,
      "pr_number" => delivery.pr_number,
      "state" => Atom.to_string(delivery.state),
      "resume_state" => encode_state(delivery.resume_state),
      "provider_error" => delivery.provider_error,
      "provider_retry_at" => delivery.provider_retry_at,
      "failure_reason" => delivery.failure_reason,
      "ci_status" => encode_state(delivery.ci_status),
      "delivery_proof" => delivery.delivery_proof,
      "merge_proof" => delivery.merge_proof,
      "cleanup_proof" => delivery.cleanup_proof,
      "attempt" => delivery.attempt,
      "escalation" => delivery.escalation,
      "failures" => Enum.map(delivery.failures, &serialize_failure/1),
      "escalations" => Enum.map(delivery.escalations, &serialize_failure/1),
      "last_event" => encode_state(delivery.last_event),
      "metadata" => delivery.metadata
    }
  end

  @doc "Restores and validates a lifecycle from `serialize/1` output."
  @spec deserialize(map()) :: {:ok, t()} | {:error, term()}
  def deserialize(map) when is_map(map) do
    with :ok <- validate_version(value(map, "version", @version)),
         {:ok, state} <- decode_state(value(map, "state", "setup")),
         {:ok, resume_state} <- decode_optional_state(value(map, "resume_state")),
         {:ok, ci_status} <- decode_ci_status(value(map, "ci_status")),
         {:ok, failures} <- deserialize_failures(value(map, "failures", [])),
         {:ok, escalations} <- deserialize_failures(value(map, "escalations", [])) do
      delivery = %__MODULE__{
        issue_id: value(map, "issue_id"),
        workspace: value(map, "workspace"),
        branch: value(map, "branch"),
        commit_sha: value(map, "commit_sha"),
        pr_number: value(map, "pr_number"),
        state: state,
        resume_state: resume_state,
        provider_error: value(map, "provider_error"),
        provider_retry_at: value(map, "provider_retry_at"),
        failure_reason: value(map, "failure_reason"),
        ci_status: ci_status,
        delivery_proof: value(map, "delivery_proof"),
        merge_proof: value(map, "merge_proof"),
        cleanup_proof: value(map, "cleanup_proof"),
        attempt: value(map, "attempt", 0),
        escalation: value(map, "escalation", 0),
        failures: failures,
        escalations: escalations,
        last_event: decode_atom(value(map, "last_event")),
        metadata: value(map, "metadata", %{})
      }

      case validate(delivery) do
        :ok -> {:ok, delivery}
        {:error, errors} -> {:error, {:invalid_delivery, errors}}
      end
    end
  end

  def deserialize(_), do: {:error, :expected_map}

  @doc "Encodes a lifecycle as JSON."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(delivery), do: delivery |> serialize() |> json_safe() |> Jason.encode()

  # Delivery failures are deliberately kept as rich Erlang terms in memory so
  # retry classification can inspect them. Persisted state is a JSON boundary,
  # though, and tuples/structs are common in exception and adapter reasons.
  # Convert those values here instead of allowing a restart or dashboard read
  # to crash on Jason. This also keeps recovery evidence useful to a fresh
  # worker without requiring the original process to still be alive.
  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {json_safe(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
  defp json_safe(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp json_safe(value), do: value

  @doc "Decodes JSON produced by `encode/1`."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, map} -> deserialize(map)
      {:error, reason} -> {:error, reason}
    end
  end

  # Setup and execution ------------------------------------------------------

  defp do_transition(%__MODULE__{state: :setup} = delivery, %Event.SetupCompleted{} = event) do
    advance(delivery, :executing, :setup_completed, workspace: event.workspace || delivery.workspace)
  end

  defp do_transition(%__MODULE__{state: :executing} = delivery, %Event.CodexTurnCompleted{}) do
    advance(delivery, :delivering, :codex_turn_completed)
  end

  defp do_transition(%__MODULE__{state: :executing} = delivery, %Event.CodeFailure{} = event) do
    retry_after_failure(delivery, :code, event.reason, :code_failure)
  end

  defp do_transition(%__MODULE__{state: :executing} = delivery, %Event.CodexTurnFailed{} = event) do
    retry_after_failure(delivery, :code, event.reason, :codex_turn_failed)
  end

  # Delivery must contain external proof. A completed Codex turn alone cannot
  # enter CI or become terminal success.
  defp do_transition(%__MODULE__{state: :delivering} = delivery, %Event.DeliveryCompleted{} = event) do
    if delivery_proof_present?(event) do
      advance(delivery, :waiting_ci, :delivery_completed,
        branch: event.branch,
        commit_sha: event.commit_sha,
        pr_number: event.pr_number,
        delivery_proof: %{
          "branch" => event.branch,
          "commit_sha" => event.commit_sha,
          "pr_number" => event.pr_number
        },
        failure_reason: nil
      )
    else
      {:error, :missing_delivery_proof}
    end
  end

  defp do_transition(%__MODULE__{state: :delivering} = delivery, %Event.DeliveryFailed{} = event) do
    case event.classification do
      classification when classification in @counted_failure_classifications ->
        retry_after_failure(delivery, classification, event.reason, :delivery_failed)

      :provider ->
        park_for_provider(delivery, event.reason, nil, :delivery_failed)

      _ ->
        fail(delivery, event.reason, :delivery_failed)
    end
  end

  # CI and retry -------------------------------------------------------------

  defp do_transition(%__MODULE__{state: :waiting_ci} = delivery, %Event.CiPassed{} = event) do
    advance(delivery, :waiting_merge, :ci_passed,
      ci_status: :green,
      metadata: put_metadata(delivery.metadata, :check_run_id, event.check_run_id),
      failure_reason: nil
    )
  end

  defp do_transition(%__MODULE__{state: :waiting_ci} = delivery, %Event.CiFailed{} = event) do
    retry_after_failure(delivery, :ci, event.reason, :ci_failed,
      metadata: put_metadata(delivery.metadata, :check_run_id, event.check_run_id),
      ci_status: :red
    )
  end

  defp do_transition(%__MODULE__{state: :waiting_merge} = delivery, %Event.MergeConflict{} = event) do
    retry_after_failure(delivery, :code, event.reason, :merge_conflict)
  end

  defp do_transition(%__MODULE__{state: :retry_ready} = delivery, %Event.RetryAvailable{}) do
    advance(delivery, :executing, :retry_available, failure_reason: nil)
  end

  defp do_transition(%__MODULE__{state: :retry_ready} = delivery, %Event.Escalated{} = event) do
    if event.classification in @counted_failure_classifications do
      advance(delivery, :retry_ready, :escalated,
        escalation: delivery.escalation + 1,
        escalations: [%{classification: event.classification, reason: event.reason} | delivery.escalations]
      )
    else
      {:error, :escalation_requires_classified_failure}
    end
  end

  # Merge and cleanup --------------------------------------------------------

  defp do_transition(%__MODULE__{state: :waiting_merge} = delivery, %Event.MergeCompleted{} = event) do
    if present?(event.merge_sha) do
      advance(delivery, :merged, :merge_completed,
        merge_proof: %{"merge_sha" => event.merge_sha},
        failure_reason: nil
      )
    else
      {:error, :missing_merge_proof}
    end
  end

  defp do_transition(%__MODULE__{state: :merged} = delivery, %Event.CleanupStarted{}) do
    advance(delivery, :cleaning, :cleanup_started)
  end

  defp do_transition(%__MODULE__{state: :cleaning} = delivery, %Event.CleanupCompleted{} = event) do
    advance(delivery, :complete, :cleanup_completed,
      cleanup_proof: %{"workspace" => event.workspace || delivery.workspace},
      failure_reason: nil
    )
  end

  # Provider and terminal outcomes ------------------------------------------

  defp do_transition(%__MODULE__{state: :waiting_provider} = delivery, %Event.ProviderUnavailable{} = event) do
    {:ok, %{delivery | provider_error: event.reason, provider_retry_at: event.retry_at, last_event: :provider_unavailable}}
  end

  defp do_transition(%__MODULE__{state: state} = delivery, %Event.ProviderUnavailable{} = event)
       when state not in [:complete, :failed] do
    park_for_provider(delivery, event.reason, event.retry_at, :provider_unavailable)
  end

  defp do_transition(%__MODULE__{state: :waiting_provider, resume_state: resume_state} = delivery, %Event.ProviderAvailable{})
       when resume_state in @states and resume_state not in [:waiting_provider, :complete, :failed] do
    {:ok, %{delivery | state: resume_state, resume_state: nil, provider_error: nil, provider_retry_at: nil, last_event: :provider_available}}
  end

  defp do_transition(%__MODULE__{state: state} = delivery, %Event.PermanentFailure{} = event)
       when state not in [:complete, :failed] do
    fail(delivery, event.reason, :permanent_failure)
  end

  defp do_transition(_delivery, event) do
    {:error, {:invalid_transition, event_name(event)}}
  end

  defp advance(delivery, state, event, updates \\ []) do
    {:ok, struct!(delivery, Keyword.merge([state: state, last_event: event], updates))}
  end

  defp retry_after_failure(delivery, classification, reason, event, updates \\ []) do
    failure = %{classification: classification, reason: reason}

    advance(
      delivery,
      :retry_ready,
      event,
      Keyword.merge(
        [
          attempt: delivery.attempt + 1,
          failures: [failure | delivery.failures],
          failure_reason: reason
        ],
        updates
      )
    )
  end

  defp park_for_provider(delivery, reason, retry_at, event) do
    advance(delivery, :waiting_provider, event,
      resume_state: delivery.state,
      provider_error: reason,
      provider_retry_at: retry_at
    )
  end

  defp fail(delivery, reason, event) do
    advance(delivery, :failed, event,
      failure_reason: reason,
      resume_state: nil,
      provider_error: nil,
      provider_retry_at: nil
    )
  end

  defp validate_current(delivery) do
    case validate(delivery) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_delivery, errors}}
    end
  end

  defp check_known_state(errors, %{state: state}) when state in @states, do: errors
  defp check_known_state(errors, %{state: state}), do: [{:unknown_state, state} | errors]

  defp check_non_negative_counter(errors, delivery, field) do
    case Map.get(delivery, field) do
      value when is_integer(value) and value >= 0 -> errors
      value -> [{:invalid_counter, field, value} | errors]
    end
  end

  defp check_failure_history(errors, delivery) do
    failures_valid? = valid_failure_history?(delivery.failures)
    escalations_valid? = valid_failure_history?(delivery.escalations)
    attempt_error = if delivery.attempt == length(delivery.failures), do: [], else: [{:attempt_mismatch, delivery.attempt, length(delivery.failures)}]
    escalation_error = if delivery.escalation == length(delivery.escalations), do: [], else: [{:escalation_mismatch, delivery.escalation, length(delivery.escalations)}]
    failure_error = if failures_valid?, do: [], else: [{:invalid_failure_history, :failures}]
    escalation_history_error = if escalations_valid?, do: [], else: [{:invalid_failure_history, :escalations}]

    attempt_error ++ escalation_error ++ failure_error ++ escalation_history_error ++ errors
  end

  defp check_provider_wait(errors, %{state: :waiting_provider, resume_state: resume_state})
       when resume_state in @states and resume_state not in [:waiting_provider, :complete, :failed], do: errors

  defp check_provider_wait(errors, %{state: :waiting_provider, resume_state: resume_state}),
    do: [{:missing_provider_resume_state, resume_state} | errors]

  defp check_provider_wait(errors, %{state: state, resume_state: nil}) when state != :waiting_provider, do: errors
  defp check_provider_wait(errors, %{state: state, resume_state: resume_state}), do: [{:unexpected_provider_resume_state, state, resume_state} | errors]

  defp check_delivery_proof(errors, %{state: state, delivery_proof: proof})
       when state in [:waiting_ci, :waiting_merge, :merged, :cleaning, :complete] do
    if delivery_proof_valid?(proof) do
      errors
    else
      [{:invalid_delivery_proof, state} | errors]
    end
  end

  defp check_delivery_proof(errors, %{state: state}) when state in [:waiting_ci, :waiting_merge, :merged, :cleaning, :complete],
    do: [{:missing_delivery_proof, state} | errors]

  defp check_delivery_proof(errors, _delivery), do: errors

  defp check_ci_proof(errors, %{state: state, ci_status: :green}) when state in [:waiting_merge, :merged, :cleaning, :complete], do: errors
  defp check_ci_proof(errors, %{state: state}) when state in [:waiting_merge, :merged, :cleaning, :complete], do: [{:missing_green_ci, state} | errors]
  defp check_ci_proof(errors, _delivery), do: errors

  defp check_merge_proof(errors, %{state: state, merge_proof: proof}) when state in [:merged, :cleaning, :complete] do
    if is_map(proof) and present?(Map.get(proof, "merge_sha")) do
      errors
    else
      [{:invalid_merge_proof, state} | errors]
    end
  end

  defp check_merge_proof(errors, %{state: state}) when state in [:merged, :cleaning, :complete], do: [{:missing_merge_proof, state} | errors]
  defp check_merge_proof(errors, _delivery), do: errors

  defp check_cleanup_proof(errors, %{state: :complete, cleanup_proof: proof}) when is_map(proof), do: errors
  defp check_cleanup_proof(errors, %{state: :complete}), do: [{:missing_cleanup_proof, :complete} | errors]
  defp check_cleanup_proof(errors, _delivery), do: errors

  defp valid_failure_history?(history) when is_list(history) do
    Enum.all?(history, fn
      %{classification: classification} when classification in @counted_failure_classifications -> true
      _ -> false
    end)
  end

  defp valid_failure_history?(_), do: false

  defp delivery_proof_present?(%Event.DeliveryCompleted{branch: branch, commit_sha: sha, pr_number: pr_number}) do
    present?(branch) and present?(sha) and is_integer(pr_number) and pr_number > 0
  end

  defp delivery_proof_valid?(proof) when is_map(proof) do
    present?(Map.get(proof, "branch")) and
      present?(Map.get(proof, "commit_sha")) and
      is_integer(Map.get(proof, "pr_number")) and Map.get(proof, "pr_number") > 0
  end

  defp delivery_proof_valid?(_), do: false

  defp present?(value), do: is_binary(value) and byte_size(value) > 0

  defp put_metadata(metadata, key, value) when is_map(metadata), do: Map.put(metadata, key, value)
  defp put_metadata(_metadata, key, value), do: %{key => value}

  defp event_name(%Event.SetupCompleted{}), do: :setup_completed
  defp event_name(%Event.CodexTurnCompleted{}), do: :codex_turn_completed
  defp event_name(%Event.DeliveryCompleted{}), do: :delivery_completed
  defp event_name(%Event.CodeFailure{}), do: :code_failure
  defp event_name(%Event.CodexTurnFailed{}), do: :codex_turn_failed
  defp event_name(%Event.CiPassed{}), do: :ci_passed
  defp event_name(%Event.CiFailed{}), do: :ci_failed
  defp event_name(%Event.MergeConflict{}), do: :merge_conflict
  defp event_name(%Event.MergeCompleted{}), do: :merge_completed
  defp event_name(%Event.CleanupStarted{}), do: :cleanup_started
  defp event_name(%Event.CleanupCompleted{}), do: :cleanup_completed
  defp event_name(%Event.RetryAvailable{}), do: :retry_available
  defp event_name(%Event.DeliveryFailed{}), do: :delivery_failed
  defp event_name(%Event.Escalated{}), do: :escalated
  defp event_name(%Event.ProviderUnavailable{}), do: :provider_unavailable
  defp event_name(%Event.ProviderAvailable{}), do: :provider_available
  defp event_name(%Event.PermanentFailure{}), do: :permanent_failure
  defp event_name(_), do: :unknown

  defp serialize_failure(%{classification: classification, reason: reason}), do: %{"classification" => Atom.to_string(classification), "reason" => reason}

  defp deserialize_failures(failures) when is_list(failures) do
    with {:ok, reversed} <-
           Enum.reduce_while(failures, {:ok, []}, fn
             failure, {:ok, acc} when is_map(failure) ->
               classification = value(failure, "classification")

               if classification in Enum.map(@counted_failure_classifications, &Atom.to_string/1) do
                 {:cont,
                  {:ok,
                   [
                     %{classification: String.to_existing_atom(classification), reason: value(failure, "reason")}
                     | acc
                   ]}}
               else
                 {:halt, {:error, {:invalid_failure_classification, classification}}}
               end

             _failure, _acc ->
               {:halt, {:error, :invalid_failure_record}}
           end) do
      {:ok, Enum.reverse(reversed)}
    end
  end

  defp deserialize_failures(_), do: {:error, :invalid_failure_history}

  defp validate_version(@version), do: :ok
  defp validate_version(version), do: {:error, {:unsupported_version, version}}

  defp decode_state(state) when state in @states, do: {:ok, state}

  defp decode_state(state) when is_binary(state) do
    case Enum.find(@states, &(Atom.to_string(&1) == state)) do
      nil -> {:error, {:unknown_state, state}}
      state -> {:ok, state}
    end
  end

  defp decode_state(state), do: {:error, {:unknown_state, state}}

  defp decode_optional_state(nil), do: {:ok, nil}
  defp decode_optional_state(state), do: decode_state(state)

  defp decode_ci_status(nil), do: {:ok, nil}
  defp decode_ci_status(status) when status in [:green, :red], do: {:ok, status}
  defp decode_ci_status(status) when status in ["green", "red"], do: {:ok, String.to_existing_atom(status)}
  defp decode_ci_status(status), do: {:error, {:invalid_ci_status, status}}

  defp decode_atom(nil), do: nil
  defp decode_atom(value) when is_atom(value), do: value

  defp decode_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> nil
    end
  end

  defp encode_state(nil), do: nil
  defp encode_state(value) when is_atom(value), do: Atom.to_string(value)

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  end
end

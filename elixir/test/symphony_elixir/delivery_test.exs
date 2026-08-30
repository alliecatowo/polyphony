defmodule SymphonyElixir.DeliveryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Delivery
  alias SymphonyElixir.Delivery.Event

  test "models the successful delivery lifecycle in order" do
    delivery = Delivery.new(issue_id: "42", workspace: "/work/42")

    assert {:ok, %{state: :executing} = delivery} = transition(delivery, %Event.SetupCompleted{})
    assert {:ok, %{state: :delivering} = delivery} = transition(delivery, %Event.CodexTurnCompleted{session_id: "thread-1"})
    assert {:ok, %{state: :waiting_ci} = delivery} = transition(delivery, %Event.DeliveryCompleted{branch: "agent/42", commit_sha: "abc123", pr_number: 7})
    assert {:ok, %{state: :waiting_merge} = delivery} = transition(delivery, %Event.CiPassed{check_run_id: "ci-7"})
    assert {:ok, %{state: :merged} = delivery} = transition(delivery, %Event.MergeCompleted{merge_sha: "def456"})
    assert {:ok, %{state: :cleaning} = delivery} = transition(delivery, %Event.CleanupStarted{})
    assert {:ok, %{state: :complete} = delivery} = transition(delivery, %Event.CleanupCompleted{workspace: "/work/42"})

    assert Delivery.terminal?(delivery.state)
    assert Delivery.next_action(delivery) == :none
    assert Delivery.valid?(delivery)
  end

  test "codex turn completion enters delivery and cannot claim success" do
    delivery = progressed_to(:executing)

    assert {:ok, delivery} = transition(delivery, %Event.CodexTurnCompleted{})
    assert delivery.state == :delivering
    refute Delivery.terminal?(delivery.state)
    assert Delivery.next_action(delivery) == :verify_and_deliver
    assert {:error, :missing_delivery_proof} = transition(delivery, %Event.DeliveryCompleted{})
  end

  test "green CI waits for merge and merge waits for cleanup" do
    delivery = progressed_to(:waiting_ci)

    assert {:ok, delivery} = transition(delivery, %Event.CiPassed{})
    assert delivery.state == :waiting_merge
    assert {:ok, delivery} = transition(delivery, %Event.MergeCompleted{merge_sha: "merge"})
    assert delivery.state == :merged
    assert {:ok, delivery} = transition(delivery, %Event.CleanupStarted{})
    assert delivery.state == :cleaning
    refute Delivery.terminal?(delivery.state)
  end

  test "red CI parks for retry and increments only the classified failure attempt" do
    delivery = progressed_to(:waiting_ci)

    assert {:ok, retry_ready} = transition(delivery, %Event.CiFailed{reason: "test failed"})
    assert retry_ready.state == :retry_ready
    assert retry_ready.attempt == 1
    assert retry_ready.escalation == 0
    assert [%{classification: :ci}] = retry_ready.failures
    assert Delivery.next_action(retry_ready) == :admit_retry

    assert {:ok, executing} = transition(retry_ready, %Event.RetryAvailable{})
    assert executing.state == :executing
    assert executing.attempt == 1
    assert executing.escalation == 0
  end

  test "code failures and merge conflicts consume retry attempts" do
    executing = progressed_to(:executing)
    assert {:ok, retry_ready} = transition(executing, %Event.CodeFailure{reason: "assertion"})
    assert retry_ready.attempt == 1

    waiting_merge = progressed_to(:waiting_merge)
    assert {:ok, retry_ready} = transition(waiting_merge, %Event.MergeConflict{reason: "stale base"})
    assert retry_ready.state == :retry_ready
    assert retry_ready.attempt == 1
    assert [%{classification: :code}] = retry_ready.failures
  end

  test "provider outage parks and restores the exact prior state without counting a failure" do
    delivery = progressed_to(:waiting_ci)

    assert {:ok, parked} = transition(delivery, %Event.ProviderUnavailable{reason: :rate_limited, retry_at: 123})
    assert parked.state == :waiting_provider
    assert parked.resume_state == :waiting_ci
    assert parked.provider_error == :rate_limited
    assert parked.attempt == 0
    assert parked.escalation == 0
    assert Delivery.next_action(parked) == :wait_for_provider

    assert {:ok, resumed} = transition(parked, %Event.ProviderAvailable{})
    assert resumed.state == :waiting_ci
    assert resumed.resume_state == nil
    assert resumed.provider_error == nil
    assert Delivery.valid?(resumed)
  end

  test "provider outage is idempotent while parked" do
    parked =
      progressed_to(:executing)
      |> transition_ok(%Event.ProviderUnavailable{reason: :unavailable})

    assert {:ok, parked_again} = transition(parked, %Event.ProviderUnavailable{reason: :still_unavailable})
    assert parked_again.state == :waiting_provider
    assert parked_again.resume_state == :executing
    assert parked_again.attempt == 0
    assert parked_again.provider_error == :still_unavailable
  end

  test "capacity and provider delivery failures do not consume retry budget" do
    delivery = progressed_to(:delivering)

    assert {:ok, parked} = transition(delivery, %Event.DeliveryFailed{classification: :provider, reason: :timeout})
    assert parked.state == :waiting_provider
    assert parked.attempt == 0

    assert {:ok, failed} = transition(delivery, %Event.DeliveryFailed{classification: :capacity, reason: :busy})
    assert failed.state == :failed
    assert failed.attempt == 0
    assert failed.escalation == 0
  end

  test "escalation is explicit and can only count code or CI failures" do
    retry_ready = progressed_to(:executing) |> transition_ok(%Event.CodeFailure{reason: "compile"})

    assert {:ok, escalated} = transition(retry_ready, %Event.Escalated{classification: :code, reason: "second code failure"})
    assert escalated.state == :retry_ready
    assert escalated.attempt == 1
    assert escalated.escalation == 1
    assert [%{classification: :code}] = escalated.escalations

    assert {:error, :escalation_requires_classified_failure} =
             transition(retry_ready, %Event.Escalated{classification: :provider, reason: "outage"})
  end

  test "permanent failure is terminal and does not look like a retry" do
    delivery = progressed_to(:executing)

    assert {:ok, failed} = transition(delivery, %Event.PermanentFailure{reason: :invalid_workspace})
    assert failed.state == :failed
    assert Delivery.terminal?(failed.state)
    assert Delivery.next_action(failed) == :none
    assert failed.attempt == 0
  end

  test "permanent failure clears a parked provider resume marker" do
    parked = progressed_to(:executing) |> transition_ok(%Event.ProviderUnavailable{reason: :down})

    assert {:ok, failed} = transition(parked, %Event.PermanentFailure{reason: :operator_abort})
    assert failed.state == :failed
    assert failed.resume_state == nil
    assert failed.provider_error == nil
    assert Delivery.valid?(failed)
  end

  test "invalid event ordering is rejected" do
    delivery = Delivery.new()

    assert {:error, {:invalid_transition, :ci_passed}} = transition(delivery, %Event.CiPassed{})
    assert {:error, {:invalid_transition, :cleanup_started}} = transition(delivery, %Event.CleanupStarted{})
    assert {:error, {:invalid_transition, :unknown}} = transition(delivery, :unknown)
  end

  test "terminal states reject further lifecycle events" do
    complete =
      progressed_to(:cleaning)
      |> transition_ok(%Event.CleanupCompleted{workspace: "/work"})

    assert {:error, {:invalid_transition, :provider_unavailable}} =
             transition(complete, %Event.ProviderUnavailable{reason: :down})

    failed = progressed_to(:executing) |> transition_ok(%Event.PermanentFailure{reason: :bad})

    assert {:error, {:invalid_transition, :retry_available}} = transition(failed, %Event.RetryAvailable{})
  end

  test "serialization round trips a parked lifecycle" do
    delivery =
      progressed_to(:waiting_ci)
      |> transition_ok(%Event.CiFailed{reason: "red"})
      |> transition_ok(%Event.RetryAvailable{})
      |> transition_ok(%Event.ProviderUnavailable{reason: "rate_limited", retry_at: 456})

    serialized = Delivery.serialize(delivery)
    assert serialized["version"] == 1
    assert serialized["state"] == "waiting_provider"
    assert serialized["resume_state"] == "executing"

    assert {:ok, restored} = Delivery.deserialize(serialized)
    assert restored == delivery
    assert {:ok, encoded} = Delivery.encode(delivery)
    assert {:ok, decoded} = Delivery.decode(encoded)
    assert decoded.state == delivery.state
    assert decoded.resume_state == delivery.resume_state
    assert decoded.attempt == delivery.attempt
    assert decoded.failures == delivery.failures
  end

  test "invalid serialized lifecycle is rejected by invariants" do
    assert {:error, {:invalid_delivery, errors}} =
             Delivery.deserialize(%{"state" => "complete", "attempt" => 0, "escalation" => 0})

    assert {:invalid_delivery_proof, :complete} in errors
    assert {:missing_green_ci, :complete} in errors
    assert {:invalid_merge_proof, :complete} in errors
    assert {:missing_cleanup_proof, :complete} in errors
  end

  test "serialization preserves failure order and rejects malformed records" do
    delivery =
      progressed_to(:waiting_ci)
      |> transition_ok(%Event.CiFailed{reason: "first"})
      |> transition_ok(%Event.RetryAvailable{})
      |> transition_ok(%Event.CodeFailure{reason: "second"})

    assert {:ok, restored} = Delivery.deserialize(Delivery.serialize(delivery))
    assert Enum.map(restored.failures, & &1.reason) == ["second", "first"]

    assert {:error, :invalid_failure_record} =
             Delivery.deserialize(%{"failures" => ["not a map"]})

    assert {:error, {:invalid_failure_classification, "provider"}} =
             Delivery.deserialize(%{"failures" => [%{"classification" => "provider"}]})
  end

  test "valid transition and action helpers expose the lifecycle contract" do
    delivery = Delivery.new()

    assert Delivery.states() == [
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

    assert Delivery.valid_transition?(delivery, %Event.SetupCompleted{})
    refute Delivery.valid_transition?(delivery, %Event.CiPassed{})
    refute Delivery.waiting_for_provider?(delivery)
    assert Delivery.waiting_for_provider?(:waiting_provider)
  end

  defp progressed_to(target) do
    delivery = Delivery.new(workspace: "/work")
    delivery = transition_ok(delivery, %Event.SetupCompleted{})

    case target do
      :setup ->
        Delivery.new(workspace: "/work")

      :executing ->
        delivery

      :delivering ->
        transition_ok(delivery, %Event.CodexTurnCompleted{})

      :waiting_ci ->
        delivery
        |> transition_ok(%Event.CodexTurnCompleted{})
        |> transition_ok(%Event.DeliveryCompleted{branch: "agent/test", commit_sha: "sha", pr_number: 1})

      :waiting_merge ->
        delivery
        |> transition_ok(%Event.CodexTurnCompleted{})
        |> transition_ok(%Event.DeliveryCompleted{branch: "agent/test", commit_sha: "sha", pr_number: 1})
        |> transition_ok(%Event.CiPassed{})

      :merged ->
        progressed_to(:waiting_merge) |> transition_ok(%Event.MergeCompleted{merge_sha: "merge"})

      :cleaning ->
        progressed_to(:merged)
        |> transition_ok(%Event.CleanupStarted{})
    end
  end

  defp transition(delivery, event), do: Delivery.transition(delivery, event)
  defp transition_ok(delivery, event), do: elem(Delivery.transition(delivery, event), 1)
end

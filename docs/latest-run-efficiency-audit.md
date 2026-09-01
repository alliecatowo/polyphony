# Latest Polyphony run: efficiency and quality audit

Date: 2026-08-29 (America/Los_Angeles)

Scope: local repository files, `elixir/log/symphony.log.1`, and local Patches
worktrees only. No GitHub API calls were made and Polyphony was not launched.

## Executive result

The run was not an efficient or successful delivery run. It spent roughly 33
minutes consuming model time while repeatedly exhausting GitHub GraphQL quota,
then converted quota failures into agent failures and retries. The service
process remained alive, but no locally verifiable Polyphony PR/merge delivery
was produced by this run.

## Exact quota hammering paths

The relevant run window is `20:30:00–21:02:59` in the rotated log.

- 24 scheduler poll cycles ran. Eight candidate fetches succeeded, each
  returning 73–74 issues, before quota errors dominated.
- Each normal cycle can issue a running-issue state query
  (`orchestrator.ex:453-475`), a broad candidate query
  (`orchestrator.ex:373-444`), per-candidate dispatch revalidation
  (`orchestrator.ex:927-951`), and tracker writes/reconciliation
  (`orchestrator.ex:954-968`). This makes one poll fan out into many GraphQL
  operations.
- Every retry timer independently started `Tracker.fetch_candidate_issues/0`
  (`orchestrator.ex:300-315`). In the window, there were 37 retry-poll
  failures and 55 retry schedules after the initial failures began.
- Every normally completed Codex turn refreshed the issue state through
  `Tracker.fetch_issue_states_by_ids/1` (`agent_runner.ex:148-162`). This is a
  direct worker-side read path, separate from the scheduler’s admission gate.
- The run logged 313 quota-related lines, including 111 actual GraphQL error
  responses. It logged 16 orchestrator breaker openings, generally once per
  minute after the first exhaustion.

## Why the circuit breaker was bypassed

The orchestrator breaker is checked only at the top of `maybe_dispatch/2`
(`orchestrator.ex:373-378`). It suppresses the normal poll body, but it does
not suppress:

1. retry lookup tasks already scheduled by `handle_info({:retry_issue, ...})`;
2. worker-side state refreshes after a Codex turn; or
3. all tracker writes and non-GraphQL provider operations.

The GitHub client has a second ETS breaker around `graphql/2`
(`github/client.ex:432-460`, `1858-1926`), but it is reactive: concurrent
requests can pass the closed check before the first response opens it. It also
returns a synthetic error to callers, which the orchestrator interprets as an
ordinary worker failure. The result is a feedback loop:

`quota error → worker failure → retry timer → candidate fetch → quota error`.

Evidence: at log lines 53207–53215, retry lookups continued while the normal
poll path was also reporting the breaker; at lines 51740–51773, workers failed
with `issue_state_refresh_failed` caused by `graphql_rate_limit` and were
rescheduled.

## Transcript quality and agent outcomes

The log shows real Codex activity, but completion was only turn completion,
not successful delivery:

- 25 turns started and 25 turns completed in the window.
- 10,566 `item/agentMessage/delta` events, 264 diff updates, and 531 rate-limit
  updates were emitted. Raw deltas were much noisier than useful lifecycle
  events.
- 26 `Agent run failed` records were produced. Several were directly caused by
  GitHub rate-limit state refreshes (`#159`, `#177`, `#178`, `#180`); another
  notable failure was a `:response_timeout` for `#177` at line 41027.
- The run repeatedly re-entered the same issues: #151 five starts, #159 five,
  #178 four, #152/#158 three each, #177 two, and #160/#179/#180 one each.

This is poor efficiency: model work was performed, but provider availability
checks after the turn decided whether the work counted as failure. The system
also had no local quality gate proving that a change was committed, pushed,
associated with a PR, green in CI, or merged.

## PR and worktree delivery failures

Local worktree inspection found two failure modes:

- `_150`, `_151`, `_152`, `_157`, `_158`, and `_159` resolved Git’s top level to
  `/home/allie/develop/patches`, all used the same `agent/polyphony-` branch,
  and contained the parent checkout’s changes. They were not isolated worker
  repositories.
- `_160`, `_177`, `_178`, `_179`, and `_180` were isolated repositories and did
  contain commits or issue handoff artifacts, but the local run log contains no
  delivery-controller record proving a PR was created, checks passed, or a PR
  merged. Existing handoff files are not sufficient proof of external delivery.

The strongest local conclusion is therefore: Codex turns and some commits
existed, but the run did not establish a reliable commit → push → PR → CI →
merge → cleanup chain. Do not treat `Codex session completed` as success.

## Low-quota architecture recommendations

Implement these in order before another high-concurrency run:

1. **One provider gate.** Put every GitHub read/write behind one supervised
   quota gate with a bounded queue, single-flight probes, typed REST/GraphQL
   rate-limit classification, reset-time handling, and a circuit state visible
   in snapshots. When open, retry timers must be parked—not executed and
   rescheduled as agent failures.
2. **Webhook-first state.** Keep the existing signed webhook endpoint, but
   acknowledge quickly, persist/deduplicate `X-GitHub-Delivery`, normalize
   issue/PR/check/workflow events, and update only affected local projections.
   Webhooks should wake targeted reconciliation; they should not trigger a
   full-board poll.
3. **Fetch on completion.** After a worker finishes, do not fetch the whole
   candidate board. Record a local completion/delivery event and fetch only the
   issue, its linked PR/checks, and its dependency neighborhood. Dispatch the
   next candidate only from a locally maintained ready queue.
4. **Bounded reconciliation.** Run a slow safety sweep only when webhooks are
   absent or stale, with one in-flight sweep, a minimum interval, page limits,
   jitter, and a provider budget. Never allow each worker, retry, dashboard
   request, and startup cleanup task to launch independent sweeps.
5. **Separate lifecycle from telemetry.** Coalesce transcript deltas and token
   updates in a bounded read model; retain non-droppable lifecycle events.
   Snapshot reads must not queue behind raw Codex messages.
6. **Delivery state machine.** Make setup, execution, delivery, CI watching,
   merge, and cleanup explicit durable states. Provider outages should pause
   reconciliation, not escalate models or mark agent work failed. A PR/worktree
   must be verified locally before the issue is released or the workspace is
   removed.

## Key evidence

- `elixir/log/symphony.log.1:53207-53215`: retry polling continued during quota
  exhaustion.
- `elixir/log/symphony.log.1:53216-53267`: normal polls repeatedly reopened a
  60-second breaker.
- `elixir/log/symphony.log.1:51740-51773`: rate-limit state refresh failures
  became worker failures and retries.
- `elixir/lib/symphony_elixir/orchestrator.ex:300-315`: retry path directly
  fetches the entire candidate board.
- `elixir/lib/symphony_elixir/orchestrator.ex:373-444`: breaker protects only
  the normal poll path.
- `elixir/lib/symphony_elixir/agent_runner.ex:148-162`: worker turn completion
  performs another provider read.
- Local worktrees under
  `/home/allie/develop/patches/.polyphony/workspaces/`: shared-parent and
  isolated-worktree states described above.

Files changed: `docs/latest-run-efficiency-audit.md` and the pointer in
`docs/production-daemon-readiness-audit.md`. Runtime source, GitHub state,
processes, and worktrees were not modified.

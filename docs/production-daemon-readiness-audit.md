# Polyphony production-daemon readiness audit

Date: 2026-08-29 (America/Los_Angeles)

Scope: dashboard snapshot starvation and event backpressure, worker lifecycle,
retry and escalation policy, PR/CI/merge/cleanup, auth and configuration,
resource limits, observability, portability, and pause/drain behavior.

This is a review and implementation plan only. No runtime source was changed and
the live `polyphony-orchestrator.service` was not restarted, stopped, or signaled
during the audit. The issue proposals below are drafts. GitHub rejected issue
creation while this audit was being finalized because the configured account was
already over its GraphQL API quota; the complete bodies are retained here for
creation after the reset window.

## Executive verdict

Polyphony has useful prototype foundations—OTP supervision, per-issue worker
tasks, tracker reconciliation, workspace path checks, model profiles, retry
timers, rotating logs, a Phoenix dashboard, and a shared Codex app-server mode.
It is not yet safe to run as an unattended production daemon.

There are two immediate launch blockers:

1. The scheduler GenServer is also the high-volume telemetry sink and synchronous
   snapshot server. Raw Codex deltas can starve lifecycle messages and every
   dashboard/API snapshot request. The live API timed out in five consecutive
   requests while the service remained healthy at the OS level.
2. A directory under the workspace root is treated as a valid reusable
   workspace without proving it is an isolated repository. In the live Patches
   run, all six workspace paths resolved through Git to the parent
   `/home/allie/develop/patches` repository. The parent checkout had been changed
   to branch `agent/polyphony-` and remote `git@github.com:/.git`. No PR with an
   `agent/polyphony*` head existed.

The current implementation can therefore spend tokens and report completed
Codex turns without producing isolated commits or PRs. A process being
`active/running` is not sufficient evidence that the daemon is doing valid work.

## Live evidence captured during this audit

The evidence below was collected read-only. It is included because the failure
mode is not hypothetical.

| Signal | Observation | Interpretation |
| --- | --- | --- |
| systemd | `ActiveState=active`, `SubState=running`, PID `1646734`, `NRestarts=0` | The daemon process itself was alive. |
| load | 237–258 tasks, roughly 452–513 MiB current memory | Snapshot failure was not caused by cgroup OOM or process death. |
| cgroup | 800% CPU, 10 GiB memory, 2,048 tasks; no CPU throttling and no OOM events | Host-level containment was active, but it did not establish per-worker fairness. |
| file descriptors | live BEAM soft/hard `NOFILE=16384` | The earlier 1,024 descriptor ceiling was no longer the immediate failure. |
| API | five consecutive `GET /api/v1/state` calls returned `snapshot_timeout` after about 1.001 s, with HTTP 200 | The scheduler mailbox could not serve control-plane reads under event load, and the API used the wrong status code. |
| later recheck | the endpoint later recovered to about 1.4 ms after the active process changed to PID `1662276`; retry `#160` still reported the broken workspace hook | Snapshot starvation is intermittent and load-driven; process liveness or a momentarily fast response does not prove a valid run. |
| event stream | `elixir/log/symphony.log.1` contains dense `item/agentMessage/delta` bursts approximately every 15–25 ms | Raw presentation deltas are entering the hot path without coalescing or admission control. |
| worker lifecycle | sessions for issues `#150`, `#151`, `#152`, and `#157` completed; `#158` also showed a `:response_timeout` and retry | Codex activity and some retry behavior were real, despite broken delivery. |
| workspaces | `_150`, `_151`, `_152`, `_157`, `_158`, and `_159` all reported Git top-level `/home/allie/develop/patches` | Workspace isolation was not established. |
| parent checkout | branch `agent/polyphony-`; origin `git@github.com:/.git` | A failed bootstrap escaped into and mutated the source checkout. |
| delivery | no PR in `alliecatowo/patches` had a head beginning with `agent/polyphony` | Completed turns did not prove a deliverable. |
| GitHub tool use | live logs contain invalid `addComment` node IDs and nonexistent `createIssueComment` mutations | Tool success/failure is left to model behavior rather than a typed lifecycle API. |

The runtime build has no version/config endpoint, so it is also impossible to
prove that the live escript matches the current dirty source tree. Production
diagnostics need a build SHA, config hash, start time, and schema version.

## Production invariants Polyphony should enforce

A production implementation should make these properties mechanically true:

1. Scheduler control messages cannot be starved by token or transcript events.
2. Snapshot reads do not synchronously call the scheduler process.
3. Every active run has a durable run ID, attempt ID, issue lease, workspace ID,
   model/profile decision, and lifecycle state.
4. A workspace is accepted only when its canonical Git top-level equals the
   workspace path and its remote/base/branch match policy.
5. A successful worker result is not a successful delivery until the harness
   has verified commit, push, PR association, required checks, merge policy, and
   terminal tracker state.
6. Retry counters represent failures, not queue waits; escalation is based on
   classified repeated failures and a budget, not incidental contention.
7. A daemon restart cannot duplicate work or forget active workers, retries,
   drain state, PR watches, or cleanup obligations.
8. Pause stops admission of new work immediately while allowing current workers
   and delivery controllers to finish; drain has a durable completion condition.
9. A noisy worker cannot monopolize scheduler mailbox, CPU, RAM, processes,
   descriptors, disk, or logs.
10. Every state transition and external side effect is idempotent, correlated,
    observable, and auditable.
11. Exposing the dashboard beyond loopback requires authentication and
    authorization, including control endpoints.
12. A one-hour fault-injected soak proves bounded queues, successful delivery,
    retry/escalation, pause/drain/resume, and cleanup.

## Findings by subsystem

### 1. Dashboard snapshot starvation and event backpressure — P0

The dashboard symptom comes from control-plane coupling, not from Phoenix
polling alone.

- `AgentRunner.send_codex_update/3` sends every Codex message directly to the
  orchestrator mailbox (`elixir/lib/symphony_elixir/agent_runner.ex:50-60`).
- `Orchestrator.handle_info/2` integrates each update and invokes
  `notify_dashboard/0` for every event
  (`elixir/lib/symphony_elixir/orchestrator.ex:268-286`).
- `notify_dashboard/0` reaches both the terminal dashboard and Phoenix PubSub
  (`elixir/lib/symphony_elixir/orchestrator.ex:1333-1335` and
  `elixir/lib/symphony_elixir/status_dashboard.ex:80-86`).
- `ObservabilityPubSub.broadcast_update/0` broadcasts one undifferentiated
  notification for every update
  (`elixir/lib/symphony_elixir_web/observability_pubsub.ex:15-23`).
- Every connected LiveView handles that notification by synchronously loading a
  full snapshot (`elixir/lib/symphony_elixir_web/live/dashboard_live.ex:33-38,
  261-282`). Multiple viewers multiply scheduler calls.
- `Presenter.state_payload/2` and `issue_payload/3` call
  `Orchestrator.snapshot/2`, which is a `GenServer.call` to the same process
  consuming raw events (`elixir/lib/symphony_elixir_web/presenter.ex:8-49` and
  `elixir/lib/symphony_elixir/orchestrator.ex:1601-1673`).
- Snapshot timeout is converted into a JSON error with HTTP 200
  (`elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex:11-14`).
  Issue snapshot failure is incorrectly converted to `issue_not_found`
  (`elixir/lib/symphony_elixir_web/presenter.ex:34-49`).
- The existing coalescing test only covers terminal rendering
  (`elixir/test/symphony_elixir/orchestrator_status_test.exs:1246`); there is no
  six-worker event-flood test for scheduler mailbox length, lifecycle latency,
  PubSub fan-out, or API p99.

Required direction:

- Split scheduler/control state from telemetry/transcript ingestion.
- Put a latest-state projection in ETS or a dedicated read-model process so
  snapshots never queue behind worker deltas.
- Coalesce replaceable events such as text deltas, token totals, and rate-limit
  updates by `{run_id, event_class}` on a bounded interval.
- Preserve lifecycle transitions (`started`, `failed`, `completed`, `DOWN`) as
  non-droppable events with priority handling.
- Publish versioned snapshot/diff notifications at a bounded rate and let
  clients resync by version after reconnect.
- Return 503 for unavailable/stale control state and 504 for an upstream timeout;
  never report a timeout as 404 or HTTP 200 success.

### 1a. GitHub quota handling — P0 — issue draft

The client does identify GraphQL rate-limit errors, but the orchestrator currently
handles them as generic tracker failures. During the live run, logs showed
`graphql_rate_limit` / `API rate limit already exceeded`, followed by candidate
fetch attempts about every five seconds. That is a provider-wide outage being
treated as an ordinary transient poll failure.

Required direction:

- Normalize REST and GraphQL quota responses into one typed provider state.
- Honor `Retry-After` and reset metadata, with a conservative fallback when it is
  absent or malformed.
- Open one coordinated circuit breaker for candidate, PR, CI, and reconciliation
  calls; do not let each worker independently keep polling.
- Keep local worker supervision and lifecycle state responsive while GitHub is
  paused, and prevent quota errors from causing false failures or model
  escalation.
- Expose provider, remaining quota, reset time, circuit state, and next probe in
  the dashboard/API without exposing credentials.
- Add deterministic tests for REST/GraphQL classification, suppression,
  recovery, concurrent callers, and missing reset metadata.

### 1b. Webhook-first GitHub event ingestion — P0 — issue draft

Polyphony already has a signed `POST /github/webhook` endpoint and the controller
can request a refresh. It does not yet make webhook delivery the authoritative
event path: deliveries are not durably deduplicated, events are not normalized
into typed issue/PR/CI transitions, and the refresh path can still lead to broad
polling. This leaves the daemon exposed to quota exhaustion and stale state.

Required direction:

- Verify signatures and acknowledge quickly; process deliveries asynchronously.
- Deduplicate `X-GitHub-Delivery` IDs and make redelivery idempotent.
- Normalize issue, pull request, check-run, workflow-run, push, and installation
  events into typed local state transitions.
- Invalidate or update only the affected projection and wake targeted
  reconciliation instead of triggering a full-board crawl.
- Retain a slow, quota-aware safety poll for missed events and expose an explicit
  degraded/no-webhook mode.
- Show webhook health, last delivery, backlog, and fallback polling in the
  dashboard/API.
- Add tests for invalid signatures, duplicates, out-of-order events,
  redelivery, affected-issue routing, and fallback recovery.

### 2. Workspace bootstrap and worker lifecycle — P0

Workspace path containment exists, but workspace validity does not.

- `Workspace.ensure_workspace/2` returns any existing directory as reusable
  (`elixir/lib/symphony_elixir/workspace.ex:51-63`).
- `after_create` only runs when the directory was newly created
  (`elixir/lib/symphony_elixir/workspace.ex:227-243`). A partial directory from
  an old build or interrupted hook permanently bypasses bootstrap.
- The current rollback on new-bootstrap failure is a good improvement
  (`elixir/lib/symphony_elixir/workspace.ex:23-41`), but it does not validate or
  quarantine pre-existing directories.
- Path checks prove only that the directory is under the configured root
  (`elixir/lib/symphony_elixir/workspace.ex:384-424`). They do not prove a Git
  repository boundary, expected remote, clean base, or unique branch.
- The Patches hook derives identity from `$PWD` and runs nested shell text through
  `systemd-run` (`elixir/WORKFLOW.md:33-47` and
  `elixir/lib/symphony_elixir/config.ex:123-149`). The live systemd warning
  showed variables being expanded before the intended inner shell. Structured
  arguments or `--expand-environment=no` are needed; nested shell interpolation
  is not a safe lifecycle API.
- If `.git` is absent, Git commands can discover the parent source repository.
  The live run demonstrated exactly that escape.
- Worker tasks are anonymous children of one `Task.Supervisor`
  (`elixir/lib/symphony_elixir/orchestrator.ex:1098-1142`). A restarted
  orchestrator loses monitors and in-memory claims while the worker tasks can
  remain alive under the unchanged TaskSupervisor.
- The top supervisor uses `:one_for_one`
  (`elixir/lib/symphony_elixir.ex:27-40`). There is no restart reconciliation
  protocol that adopts or fences surviving workers before dispatch resumes.
- `AgentRunner.run_after_run_hook/3` is best-effort and its failure is discarded
  (`elixir/lib/symphony_elixir/workspace.ex:198-211`). Delivery cannot rely on it.

Required direction:

- Bootstrap into a staging directory, validate it, then atomically rename it.
- Inject issue/run/repo values as a structured environment map; do not derive
  identity from shell state.
- Set a Git ceiling and require `git rev-parse --show-toplevel` to equal the
  canonical workspace path before any worker starts.
- Require an expected repository identity, base SHA, unique branch, and run
  sentinel. Quarantine rather than silently reuse an invalid workspace.
- Give each worker a durable identity and a DynamicSupervisor child; on daemon
  restart, reconcile persisted leases with OS processes, Codex threads,
  workspaces, tracker state, and PR state before admitting new work.
- Treat setup, execution, delivery, and cleanup as separate, explicit lifecycle
  phases rather than optional shell hooks.

### 3. Retry, stall detection, and escalation — P0

The retry loop exists, but its counters and policies do not yet express reliable
failure recovery.

- Failures use capped exponential backoff
  (`elixir/lib/symphony_elixir/orchestrator.ex:1204-1246, 1389-1400`), but there
  is no jitter, maximum attempt count, retry budget, dead-letter state, or
  terminal operator-visible failure.
- All failure types are treated similarly: startup/response timeout, turn
  failure, hook failure, tracker error, process crash, and stall. Permanent auth
  or configuration failures can retry forever.
- A normal worker completion always schedules another active-state check after
  one second (`elixir/lib/symphony_elixir/orchestrator.ex:214-240`). There is no
  durable delivery outcome deciding whether continuation is useful.
- When a retry cannot obtain a slot, `handle_active_retry/4` increments the
  attempt (`elixir/lib/symphony_elixir/orchestrator.ex:1337-1357`). Capacity
  contention therefore counts as model failure.
- `Config.codex_model_for_issue/2` escalates every attempt `>= 2` to Sol
  (`elixir/lib/symphony_elixir/config.ex:65-84`). A successful Luna turn followed
  by queue contention can therefore escalate without any Luna failure.
- Attempts and retry timers are in-memory only. Restart resets model history and
  loses scheduled retry intent.
- `AppServer.receive_loop/6` resets its `turn_timeout_ms` receive timeout after
  every message (`elixir/lib/symphony_elixir/codex/app_server.ex:365-397`). This
  is an inactivity timeout, not an absolute deadline; a runaway stream can live
  indefinitely.
- Orchestrator stall detection also treats any Codex event as activity
  (`elixir/lib/symphony_elixir/orchestrator.ex:634-696`). Text-delta noise can
  mask a worker making no semantic progress.
- Tests prove a single stall/backoff transition and retry snapshot shape
  (`elixir/test/symphony_elixir/orchestrator_status_test.exs:835, 1019`), but not
  multi-attempt classification, jitter, restart persistence, rare escalation,
  de-escalation, exhaustion, or recovery to a merged PR.

Required direction:

- Persist an attempt ledger with failure class, fingerprint, model, timestamps,
  progress checkpoint, resource outcome, and retry decision.
- Separate `capacity_deferral_count` from `failure_attempt`.
- Classify retryable, permanent, policy, auth, infrastructure, code/CI, and
  operator-cancelled outcomes.
- Add bounded exponential backoff with jitter, per-class budgets, a total retry
  budget, and a visible exhausted state.
- Escalate only after repeated equivalent failures or an explicit label/policy;
  record why the escalation happened. A queue wait must never escalate a model.
- Track both liveness heartbeat and semantic progress. Support long-running work
  without a short false timeout, while enforcing configurable no-progress and
  maximum wall-clock policies.
- Prove the entire Luna retry → Sol escalation → successful delivery path in an
  integration test and in the soak run.

### 4. PR, CI, merge, and cleanup lifecycle — P0

PR delivery is currently a prompt convention, not an orchestrator capability.

- GitHub ingestion normalizes linked PR counts and merge-state hints
  (`elixir/lib/symphony_elixir/github/client.ex:1235-1343`). It does not ingest
  required check runs, review decisions, merge queue state, branch SHA, or full
  stack topology.
- The orchestrator deliberately does not terminate an issue from merged-PR
  metadata alone; the corresponding test codifies that behavior
  (`elixir/test/symphony_elixir/orchestrator_github_reconcile_test.exs:789`).
- There is no production controller for commit/push, PR creation, CI watch,
  failed-check wakeup, same-thread resume, conflict repair, auto-merge, merge
  confirmation, or post-merge cleanup.
- `WORKFLOW.md` asks a model to run `gh pr create`, inspect feedback, apply a
  label, use a local `land` skill, and eventually merge
  (`elixir/WORKFLOW.md:124-144, 242-323`). These are useful worker instructions,
  but prompt compliance is not an idempotent state machine.
- The only injected dynamic tool is raw `github_graphql`
  (`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:8-64`). The live logs show
  models attempting invalid GraphQL comment mutations. Typed operations are
  needed for deterministic state changes.
- Cleanup happens when tracker state is terminal, either during reconciliation
  or a one-shot startup query
  (`elixir/lib/symphony_elixir/orchestrator.ex:532-550, 1266-1330`). There is no
  proof that commits were pushed, a PR was merged, artifacts were retained, or
  cleanup succeeded. Cleanup errors are largely ignored.
- No GitHub end-to-end test opens a real PR, observes a failing check, resumes a
  worker, turns checks green, auto-merges, updates the issue, and removes the
  workspace. The existing live E2E test is Linear-focused
  (`elixir/test/symphony_elixir/live_e2e_test.exs:124-129`).

Required direction:

- Add a durable delivery controller independent of the agent turn.
- Let the harness verify/produce the final commit, push with idempotency, create
  or find the PR by run/branch metadata, and persist PR/head SHA association.
- Consume GitHub webhooks with polling fallback for checks, reviews, merge queue,
  synchronize, close, and merge events.
- On red CI, classify the failure and resume the same Codex thread/workspace when
  possible; requeue with escalating policy only after repeated failed repairs.
- Define stack reconciliation as a first-class graph with ordered green gates,
  conflict handling, merge policy, and one auditable reconciler lease.
- Auto-merge only when required checks, approvals, branch freshness, issue/stack
  dependencies, and explicit policy are satisfied.
- Mark tracker state terminal and clean the workspace only after GitHub confirms
  the expected head SHA merged. Make cleanup retryable, observable, and safe to
  replay.

### 5. Pause, drain, stop, and resume — P0

There is no control state in `Orchestrator.State`
(`elixir/lib/symphony_elixir/orchestrator.ex:26-44`), no dispatch gate for an
operator mode, and no dashboard controls. The only control endpoint queues a
refresh (`elixir/lib/symphony_elixir_web/router.ex:36-43` and
`elixir/lib/symphony_elixir/orchestrator.ex:1675-1688`).

Required semantics:

- `running`: normal admission.
- `pausing`: reject new poll dispatches and due retries immediately; existing
  workers and delivery controllers continue.
- `draining`: same admission gate, plus a durable drain target and progress
  (`active_workers`, `pending_delivery`, `pending_cleanup`). When all reach zero,
  atomically become `paused`.
- `paused`: no worker or reconciler admission; webhook and tracker observations
  continue so state remains current.
- `resuming`: reconcile persisted work, leases, workspaces, PRs, and timers before
  returning to `running`.
- `stopping`: graceful cancellation deadline followed by a scoped hard stop.

Control requests need authentication, authorization, idempotency keys, audit
events, reason/operator fields, optimistic version checks, and visible errors.
Pause state must survive process and machine restart. A due retry may remain
scheduled but must not bypass the admission gate.

### 6. Resource limits and noisy-neighbor isolation — P1

The Patches service now has a useful outer cgroup and a raised descriptor limit,
but configuration implies stronger isolation than it provides.

- `scripts/launch-patches.sh:119-148` places the whole daemon tree under one
  800% CPU / 10 GiB / 2,048-task cgroup. Live cgroup counters showed no OOM or
  throttling during this audit.
- `Config.worker_resource_command/2` can create per-command transient scopes
  (`elixir/lib/symphony_elixir/config.ex:123-149`). In shared app-server mode,
  however, `AppServer.start_port/2` launches only a proxy and the shared daemon
  (`elixir/lib/symphony_elixir/codex/app_server.ex:191-219, 323-338`). Agent tool
  subprocesses inherit the shared daemon's outer service cgroup, not a per-thread
  worker cgroup.
- Live process cgroups confirmed the BEAM, shared Codex daemon, and proxies all
  belonged to `polyphony-orchestrator.service`.
- Six worker definitions each advertising 10 GiB is not six-way isolation; the
  parent 10 GiB cap is the effective shared ceiling. One build can still evict or
  starve every other run.
- Concurrency is a fixed count. There is no admission feedback from available
  memory, CPU pressure, IO pressure, descriptor usage, disk free space, cgroup
  events, or GitHub/Codex rate limits.
- There is no workspace/TMP disk quota or aging policy.

Required direction:

- Define a hierarchy: daemon control plane, shared model service, and per-run
  execution/build scopes with explicit CPU weight/quota, memory high/max, task,
  descriptor, IO, and disk controls.
- If one shared app server cannot place tool subprocesses into per-run cgroups,
  add an execution broker/container boundary or use a supported process-launch
  hook; do not claim per-worker cgroups until the kernel membership proves it.
- Add adaptive admission using host reserve targets and pressure signals, while
  preserving a configured hard maximum.
- Emit resource-pressure events and distinguish resource kills from model/code
  failures for retry policy.
- Add bounded TMP/workspace storage and garbage collection that cannot traverse
  outside managed roots.

### 7. Auth, configuration, and network security — P1

- Auth selection supports tracker token, GitHub App installation token, and a
  separate OAuth token for user-owned Projects
  (`elixir/lib/symphony_elixir/github/auth.ex:9-58`). That is a good foundation.
- The Patches launcher has workstation-specific token precedence and copies
  secrets into transient service environment properties
  (`scripts/launch-patches.sh:42-110`). `GITHUB_PAT` is launcher knowledge, not a
  typed credential source. `GITHUB_TOKEN`, `GH_TOKEN`, and
  `GITHUB_OAUTH_TOKEN` can also come from different credentials.
- Startup validation checks that a token string exists, not that it has repo,
  Project, PR, checks, merge, and webhook capabilities
  (`elixir/lib/symphony_elixir/config.ex:253-304`).
- OAuth callback stores the token only in application memory
  (`elixir/lib/symphony_elixir_web/controllers/github_auth_controller.ex:35-44`),
  so restart loses it unless also supplied externally.
- Workflow hot reload keeps the last known good parse
  (`elixir/lib/symphony_elixir/workflow_store.ex:61-151`), but does not version
  config decisions per run or distinguish hot-safe fields from restart-required
  fields.
- The endpoint sets `check_origin: false`
  (`elixir/config/config.exs:5-16`). Dashboard, state, OAuth status, and refresh
  endpoints have no authentication middleware
  (`elixir/lib/symphony_elixir_web/router.ex:24-45`). Binding to `0.0.0.0` exposes
  issue IDs, session IDs, workspace paths, usage, and a state-changing refresh
  endpoint to the reachable network.
- API timeout responses do not use operationally meaningful HTTP status codes.

Required direction:

- Introduce explicit credential providers with one resolved identity/capability
  report, rotation, expiration, and redaction. Use systemd credentials, a keyring,
  or secret files with strict permissions instead of command-line environment
  properties where possible.
- Run a non-destructive capability preflight before dispatch and fail closed with
  exact missing permissions.
- Store project config separately from prompt policy and secrets; persist a
  redacted config hash/version on every run.
- Validate model/profile names and routing policy at startup.
- Require authentication for non-loopback dashboard/API binds. Add authorization
  for read, prioritize, pause/drain, stop, and transcript access; restore origin
  checks and define trusted proxy/TLS behavior.

### 8. Observability and operability — P1

- Rotating logs exist (`elixir/lib/symphony_elixir/log_file.ex:23-78`) and many
  lifecycle lines contain issue/session fields. This is a useful base.
- Logs are unstructured single-line text and debug-log every Codex notification.
  High-volume deltas consume IO and bury transitions.
- There is no stable `run_id`/`attempt_id` joining scheduler, Codex thread, GitHub
  PR/head SHA, cgroup, workspace, and cleanup.
- The issue API exposes only the latest event and an always-empty
  `codex_session_logs` list
  (`elixir/lib/symphony_elixir_web/presenter.ex:63-84, 170-179`). There is no
  transcript store, pagination, retention, or redaction policy.
- There are no `/livez`, `/readyz`, metrics, traces, mailbox-length gauges,
  scheduler-lag histograms, event-drop/coalesce counters, cgroup pressure
  metrics, or delivery SLOs.
- Runtime logs and test logs can share the same default file rooted at the
  current directory, making production diagnosis ambiguous.
- Supervisor/process health does not prove tracker, auth, app-server, scheduler,
  PR controller, or storage readiness.

Required direction:

- Emit structured events with schema version and correlation IDs; set per-class
  log levels and sample/coalesce delta events.
- Persist a bounded, redacted event/transcript journal separate from scheduler
  memory. Provide cursor pagination and live subscriptions.
- Add liveness and dependency-aware readiness endpoints plus Prometheus/OpenTelemetry
  metrics for scheduler lag, queue depth, run states, retries, escalation,
  delivery time, check failures, resource pressure, and cleanup debt.
- Expose build SHA, uptime, config hash, state schema, queue versions, and last
  successful tracker/app-server observations.
- Define alerts/SLOs: snapshot p99, lifecycle-message lag, stuck/no-progress
  runs, exhausted retries, PR age, cleanup age, queue growth, and resource headroom.

### 9. Portability and daemon packaging — P1

- `scripts/launch-patches.sh` is hard-coded to Patches, systemd, Linuxbrew
  OpenSSL, `mise`, local paths, and one service name.
- `elixir/WORKFLOW.md` contains one machine/project's repo, board, model, cgroup,
  and prompt policy.
- The escript is version `0.1.0`, and the CLI still describes the project as an
  engineering preview (`elixir/mix.exs:4-9` and
  `elixir/lib/symphony_elixir/cli.ex:117-148`).
- There is no OTP release, migration command, durable state directory contract,
  install/uninstall/upgrade path, service unit template, container image, Helm
  chart, or multi-project daemon registry.
- `elixir/README.md:147-203` is already stale relative to the checked-in Patches
  limits and bootstrap behavior, demonstrating configuration/documentation drift.

Required direction:

- Build a versioned OTP release with explicit config, data, cache, workspace,
  log, and runtime directories following XDG/platform conventions.
- Support project-local `.polyphony.toml` (or equivalent), user defaults, and
  secret references with deterministic precedence and a `config validate/explain`
  command.
- Package a systemd instance unit (`polyphony@project`) and a container image;
  keep platform-specific resource backends behind a capability interface.
- Allow multiple projects with unique state/workspace/port identities and either
  separate pools or an explicit shared resource broker/dashboard.
- Add safe upgrade/migration/rollback, backup, and stale-instance detection.

### 10. Test strategy and release proof — P0 gate / P1 implementation

- Unit coverage is broad, but `mix.exs:10-40` excludes most production-critical
  modules from the nominal 100% coverage threshold, including Orchestrator,
  AgentRunner, AppServer, Workspace, CLI, dashboard, HTTP server, and presenter.
- Existing dashboard tests validate functional timeout and PubSub behavior
  (`elixir/test/symphony_elixir/extensions_test.exs:531-667`) but not saturation.
- Existing stall tests validate a single synthetic transition, not real Codex
  process cleanup and recovery.
- There is no chaos or soak suite for process crash, daemon restart, network
  partition, GitHub 429/5xx, token expiration, app-server death, full disk,
  cgroup OOM, CI failure, merge conflict, webhook duplication/reordering, or
  pause during retries.
- There is no end-to-end delivery assertion from issue selection to merged PR and
  cleaned workspace.

Release proof must include:

- Six concurrent synthetic workers producing worse-than-real event bursts while
  snapshot p99 remains within SLO and scheduler lifecycle lag stays bounded.
- A real/sandbox GitHub issue that produces a PR, intentionally fails CI,
  resumes the same run, becomes green, auto-merges, marks the issue done, and
  cleans its workspace.
- A retry scenario that remains Luna on capacity deferral, retries Luna on the
  first classified failure, escalates to Sol only at policy threshold, and
  records the escalation reason.
- Orchestrator and machine restart during running, retrying, CI-waiting, merging,
  and draining states with no duplicate workers, PRs, merges, or cleanup.
- Pause under full concurrency: no new starts after acknowledgement, active work
  and delivery finish, drain reaches paused, restart preserves paused state, and
  resume continues unfinished work.
- At least one uninterrupted, fault-injected run longer than one hour with
  bounded mailbox, memory, descriptors, process count, disk, logs, and retry debt.

## Prioritized implementation plan

### Dependency order

```text
P0-A Workspace safety ───────────────┐
                                     ├─> P0-E Delivery controller ─> P0-K Soak/release gate
P0-B Bounded event/read model ─┐     │             ▲
                               ├─> P0-C Durable state/leases ─┬─> P0-D Retry/escalation
                               │                              └─> P0-F Pause/drain
                               │
P1-G Resource isolation ───────┼─────────────────────────────────> P0-K
P1-H Auth/config security ─────┼─────────────────────────────────> P0-E / P0-K
P1-I Observability ────────────┼─────────────────────────────────> P0-K
P1-J Packaging/portability ────┘─────────────────────────────────> P0-K
```

Order rationale:

1. Workspace safety is first because another run can mutate the source checkout.
2. Event/read-model separation is first because the scheduler and dashboard
   cannot be trusted under ordinary six-worker output.
3. Durable state and leases come before richer retries or controls; otherwise
   every new state disappears on restart and can duplicate work.
4. Retry/escalation and pause/drain can proceed in parallel once they share the
   durable state machine and admission gate.
5. Delivery automation depends on safe workspaces and durable run identity.
6. Resource, auth, observability, and packaging tracks can overlap after the P0
   interfaces stabilize, but all feed the release gate.
7. The one-hour soak is a release criterion, not a substitute for the preceding
   invariants.

## Proposed GitHub issues

### P0-A — Enforce atomic, repository-isolated workspace bootstrap

**Proposed title:** `P0: make workspace bootstrap atomic and prevent parent-repository escape`

**Proposed body:**

Polyphony currently accepts any existing directory beneath `workspace.root` and
runs `after_create` only for newly-created paths. If bootstrap leaves a partial
directory, later attempts skip initialization; Git may walk upward into a parent
checkout. A live Patches run changed the parent branch to `agent/polyphony-` and
its origin to `git@github.com:/.git`.

Implement a structured workspace bootstrap transaction:

- create in a staging directory and atomically promote only after validation;
- pass run/issue/repo/base/branch as structured values, avoiding nested shell
  expansion through `systemd-run`;
- set a Git ceiling and require canonical Git top-level to equal the workspace;
- validate expected remote repository, fetched base SHA, unique branch, and a
  run sentinel;
- quarantine invalid pre-existing directories and expose the reason;
- refuse worker start if any invariant fails;
- ensure rollback and cleanup cannot traverse outside the managed root.

Acceptance criteria:

- A partial directory, empty directory, parent `.git`, malformed remote, stale
  branch, interrupted clone, and duplicate branch all fail safely.
- No test can mutate a repository above `workspace.root`.
- Bootstrap/reuse/recovery are idempotent across process restart.
- An integration test proves six workspaces have distinct Git top-levels and
  expected remotes/branches.
- Startup reports existing invalid workspaces before dispatch.

Dependencies: none. Blocks P0-E and the release gate.

### P0-B — Split telemetry ingestion from scheduler state and serve bounded snapshots

**Proposed title:** `P0: isolate scheduler control traffic from Codex event floods`

**Proposed body:**

Raw Codex deltas currently enter the Orchestrator GenServer, trigger one PubSub
broadcast each, and cause every LiveView to synchronously call the same
GenServer for a full snapshot. Under six workers the API returns
`snapshot_timeout` while the daemon remains alive.

Introduce a bounded event plane and materialized read model:

- send lifecycle events through a non-droppable path;
- coalesce replaceable text/token/rate-limit events per run;
- keep latest snapshots in ETS or a dedicated read-model process;
- version snapshot/diff broadcasts and cap publish frequency;
- make dashboard/API reads independent of scheduler mailbox latency;
- report stale/unavailable data with correct HTTP status and age;
- instrument dropped/coalesced counts, mailbox depth, and scheduler lag.

Acceptance criteria:

- Six workers at a synthetic high-water event rate keep scheduler lifecycle p99
  and snapshot p99 within documented SLOs.
- Queue sizes are bounded and lifecycle events are never lost.
- Ten simultaneous dashboard clients do not multiply scheduler calls.
- Timeout/unavailable/not-found have distinct 504/503/404 responses.
- Reconnect and version-gap tests prove full resynchronization.

Dependencies: none. Blocks P0-C, P0-F, P1-I, dashboard transcript work, and the
release gate.

### P0-C — Persist runs, leases, timers, and recovery state

**Proposed title:** `P0: add a durable orchestration state machine with fenced worker leases`

**Proposed body:**

Running workers, claims, completed IDs, retry timers, model attempts, and control
mode live only in `Orchestrator.State`. A GenServer or machine restart can forget
monitors while TaskSupervisor children continue and can redispatch duplicate
work.

Add a transactional durable store and explicit run state machine covering
selected, preparing, running, waiting-for-CI, retry-wait, reconciling, merging,
cleaning, completed, exhausted, and cancelled. Persist issue/run/attempt IDs,
lease owner/generation, workspace, Codex thread, model, tracker revision, PR/head
SHA, timers, and control mode. Use fencing tokens and idempotency keys for all
external side effects. On startup, enter recovery before admission and reconcile
store, tracker, OS processes, workspaces, Codex threads, and GitHub.

Acceptance criteria:

- Killing/restarting Orchestrator cannot duplicate a worker, branch, PR, merge,
  timer, or cleanup.
- Surviving workers are safely adopted or fenced and terminated.
- Retry/drain/PR-watch state survives machine reboot.
- Schema migrations and corruption/backup behavior are documented and tested.
- Every transition records actor, reason, prior version, and timestamp.

Dependencies: P0-B for the read-model boundary. Blocks P0-D, P0-E, and P0-F.

### P0-D — Classify retries and make escalation rare, bounded, and provable

**Proposed title:** `P0: implement classified retry budgets and evidence-based model escalation`

**Proposed body:**

Current retries have exponential backoff but no jitter, maximum attempts,
dead-letter state, persistence, or error classes. Waiting for capacity increments
the attempt and can route a successful task to Sol because model selection uses
`attempt >= 2`.

Implement a retry decision engine with durable failure fingerprints, retryable
versus permanent classes, jittered per-class budgets, a total budget, and an
exhausted state. Capacity deferrals must not increment model attempts. Define
model escalation thresholds by repeated equivalent failures and/or explicit
policy; record the decision and allow de-escalation after demonstrated progress.
Track heartbeat, semantic progress, inactivity, and maximum wall time separately.

Acceptance criteria:

- Capacity pressure never triggers Sol.
- A first retry remains on the configured default policy unless the failure class
  explicitly requires escalation.
- Repeated equivalent failures escalate exactly once at the configured threshold.
- Permanent auth/config failures stop without token-burning loops.
- Exhaustion is visible and requires an explicit retry/reset action.
- Restart preserves attempts, backoff deadline, and model history.
- Integration tests prove retry success, escalation success, and exhaustion.

Dependencies: P0-C. Blocks P0-E repair policy and the release gate.

### P0-E — Add an idempotent PR/CI/merge/cleanup delivery controller

**Proposed title:** `P0: promote PR, CI, merge, and cleanup into a durable delivery controller`

**Proposed body:**

Today PR creation, check polling, review handling, stack merge, and issue
completion are prompt instructions. Completed Codex turns can end without a
commit or PR, and cleanup follows tracker terminal state without proving the
expected commit merged.

Build a typed delivery controller that:

- verifies or creates the final commit and pushes an idempotent run branch;
- finds/creates one PR associated with run ID and expected head SHA;
- ingests checks/reviews/merge queue/branch events via webhook with polling
  fallback;
- resumes the same workspace/Codex thread for red CI when viable;
- applies classified repair retry/escalation policy;
- reconciles stacks in dependency order with one fenced reconciler;
- enables/executes merge only after policy gates are green;
- confirms expected SHA merged before tracker terminal transition;
- retries safe cleanup and retains audit/evidence records.

Acceptance criteria:

- A sandbox GitHub E2E goes issue → branch → PR → red CI → resumed repair → green
  CI → auto-merge → Done → workspace removed.
- Duplicate/reordered webhooks and restarts cause no duplicate PR or merge.
- Closed-unmerged, superseded-head, conflict, review-requested, and merge-queue
  cases are deterministic.
- Stack merge order and all-green gating are tested.
- Cleanup never runs for unpushed work or an unconfirmed merge.

Dependencies: P0-A, P0-C, and P0-D. Blocks the release gate.

### P0-F — Implement authenticated pause, drain, stop, and recovery-safe resume

**Proposed title:** `P0: add durable pause/drain/resume controls and dashboard actions`

**Proposed body:**

Add a versioned runtime control state and one admission gate shared by poll
dispatch, retries, reviewers, and reconcilers. `pause` must stop all new starts
without interrupting active workers. `drain` must allow active execution,
delivery, merge, and cleanup to finish and then become paused. `resume` must run
recovery reconciliation before admitting work. `stop` needs graceful and scoped
hard-stop modes.

Expose authenticated API and dashboard controls with idempotency keys, reason,
operator, optimistic state version, and audit log.

Acceptance criteria:

- After pause acknowledgement, no new worker/retry/reconciler starts.
- Active workers keep running and their PR delivery continues.
- Drain progress separately reports active workers, pending CI/merge, and cleanup.
- Paused/draining state survives daemon and machine restart.
- Resume reconciles unfinished issues/workspaces/PRs before dispatch.
- Hard stop terminates only the selected project's managed process/cgroup tree.
- Concurrency and retry race tests prove no admission slips through.

Dependencies: P0-B and P0-C. Blocks the release gate.

### P1-G — Enforce real per-run resource isolation and adaptive admission

**Proposed title:** `P1: add hierarchical cgroups, disk bounds, and pressure-aware concurrency`

**Proposed body:**

The current outer cgroup protects the host, but shared app-server workers all
inhabit the same service cgroup. Implement measurable per-run execution
isolation or an execution broker/container boundary, plus explicit limits for
the control plane and shared app server. Add CPU/memory/IO/task/FD/disk/tmp
budgets, host reserve targets, pressure-aware admission, and resource outcome
classification.

Acceptance criteria:

- Kernel cgroup membership proves each build/test process belongs to its run.
- One adversarial worker cannot starve snapshots or kill unrelated workers.
- Concurrency scales down/up from pressure without exceeding the hard maximum.
- OOM, task, descriptor, disk, and timeout failures are distinguishable in retry
  policy and dashboard.
- Resource tests run on supported Linux and container backends.

Dependencies: P0-C for run identity; coordinates with P1-I and P1-J.

### P1-H — Harden credential/config handling and secure non-loopback access

**Proposed title:** `P1: add credential providers, capability preflight, and dashboard authorization`

**Proposed body:**

Replace launcher-specific token aliases with typed credential providers and one
resolved GitHub identity. Add capability preflight for repository, Project,
checks, PR, merge, and webhook operations; expiration/rotation; redacted config
explain; and persistent OAuth storage through a secure provider. Separate
project config, prompt policy, and secrets. Require authn/authz for non-loopback
dashboard/API access, restore origin checks, and define trusted proxy/TLS policy.

Acceptance criteria:

- Startup fails closed with exact missing capabilities before dispatch.
- Tokens are absent from logs, API payloads, process arguments, and ordinary
  service-property inspection.
- Token rotation does not require losing run state.
- Read/control/transcript roles are distinct and audited.
- Tailscale/LAN and loopback deployment tests cover origin, CSRF, and control API
  authorization.
- Every run records redacted config/profile/version provenance.

Dependencies: P0-C for persisted provenance; blocks P0-E production enablement
and the release gate.

### P1-I — Add structured observability, transcripts, health, metrics, and alerts

**Proposed title:** `P1: make daemon health and run delivery observable end to end`

**Proposed body:**

Add versioned structured lifecycle events correlated by project, issue, run,
attempt, Codex thread/turn, workspace, cgroup, PR, and head SHA. Persist bounded,
redacted transcripts with pagination and live subscription. Add liveness,
dependency-aware readiness, build/config identity, metrics/traces, and SLO alerts
for scheduler lag, queues, retries, PR age, cleanup debt, and resource pressure.

Acceptance criteria:

- A single run can be traced from selection through merge and cleanup without
  parsing free-form strings.
- `/livez` remains cheap under load; `/readyz` identifies the failing dependency.
- Metrics expose mailbox/event lag, coalescing, state counts, retries/escalation,
  CI/merge latency, and resource headroom.
- Transcript retention/redaction/access policies are tested.
- Test and production logs cannot share a destination accidentally.
- Alert tests cover snapshot starvation, stuck progress, exhausted retry, stale
  PR, cleanup debt, and pressure thresholds.

Dependencies: P0-B and P0-C. Blocks the release gate.

### P1-J — Package Polyphony as a versioned, multi-project daemon

**Proposed title:** `P1: ship an OTP release with instance services and portable project config`

**Proposed body:**

Create a versioned OTP release and supported installation lifecycle. Define XDG
state/cache/config/log/workspace roots; project-local `.polyphony.toml` with user
defaults and secret references; `config validate/explain`; systemd instance
units; a container image; platform capability checks; migrations; upgrades and
rollback. Support multiple projects with unique instance IDs, ports, state, and
resource pools, plus an optional aggregate read-only dashboard.

Acceptance criteria:

- Fresh install, start, upgrade, rollback, and uninstall are documented and
  tested without `mise` or a source checkout.
- Two projects run concurrently without state/workspace/port/cgroup collisions.
- Linux systemd and container deployments pass the same conformance suite.
- Unsupported resource features fail clearly or use an explicit documented
  backend; there is no silent loss of containment.
- Config schema/version migration and backup/restore are tested.

Dependencies: P0-C; coordinates with P1-G/H/I. Blocks the release gate.

### P0-K — Add a fault-injected GitHub delivery soak and release gate

**Proposed title:** `P0: require a one-hour fault-injected autonomous delivery soak`

**Proposed body:**

Build a deterministic harness that exercises the production release with at
least six concurrent workers and a sandbox GitHub repository/project. Include
high-volume Codex events, one intentionally red CI run repaired by the same
agent context, retry and Sol escalation, PR auto-merge, workspace cleanup,
orchestrator restart, app-server failure, webhook replay/reordering, GitHub
rate-limit/transient failures, resource pressure, and pause/drain/restart/resume.

The gate passes only after an uninterrupted run longer than one hour shows:

- bounded scheduler/event queues and resources;
- no duplicate worker, branch, PR, merge, or cleanup;
- all selected deliverable issues end merged/Done or in an explicit exhausted
  state;
- retry and escalation decisions match policy;
- pause admits no new work, drain completes, and resume recovers;
- every workspace is valid while active and removed only after confirmed merge;
- dashboards/API remain responsive within SLO throughout.

Publish machine-readable results and a human-readable timeline with build SHA,
config hash, injected faults, state transitions, PR URLs, resource maxima, and
assertions.

Dependencies: P0-A through P0-F and production portions of P1-G through P1-J.
This is the final production-readiness gate.

## Suggested milestone grouping

1. **Milestone 0 — Containment:** P0-A and P0-B. No unattended Patches launch
   should be considered valid before both pass.
2. **Milestone 1 — Recoverable control plane:** P0-C, P0-D, and P0-F.
3. **Milestone 2 — Autonomous delivery:** P0-E with sandbox GitHub E2E.
4. **Milestone 3 — Operations:** P1-G, P1-H, P1-I, and P1-J, implemented in
   parallel where interfaces permit.
5. **Milestone 4 — Production proof:** P0-K one-hour fault-injected soak.

## Immediate operational conclusion

The service was active at the final observation, but this particular run is not
a valid autonomous Patches run because snapshots were repeatedly starved under
event load despite later recovery, workspace Git isolation is violated, the
parent Patches checkout was mutated, and no Polyphony PR exists.
The safest next engineering action is P0-A, followed immediately by P0-B. This
document intentionally does not perform that repair or interrupt the live
service.

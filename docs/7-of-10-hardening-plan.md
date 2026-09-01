# Polyphony 7/10 hardening plan

Date: 2026-08-29

## Objective

Before another multi-worker Patches run, make every major runtime facet at
least operationally reliable (7/10): no provider hammering, no parent-checkout
mutation, no false success at Codex turn completion, bounded resource use,
durable pause/recovery, and one proven issue-to-merged-PR lifecycle.

The production service stays stopped until the one-worker acceptance run.

## Non-negotiable invariants

1. Every GitHub request passes through one supervised provider gateway.
2. When the provider circuit is open, no caller reaches GitHub and no worker is
   failed or escalated because provider state is unavailable.
3. Webhooks update a durable local projection and targeted ready queue. They do
   not trigger a full-board crawl.
4. Safety reconciliation is single-flight, bounded, jittered, budgeted, and
   normally measured in minutes rather than seconds.
5. A workspace is runnable only when its canonical Git top-level is exactly the
   workspace path, its repository identity is correct, and its branch is unique.
6. Codex workers do not own delivery. The harness owns commit verification,
   push, PR creation/update, auto-merge policy, CI observation, merge, and
   cleanup.
7. A completed Codex turn transitions to delivery; it is not terminal success.
8. Red CI or merge conflict parks the run without consuming a slot. When a slot
   is available, the same workspace and thread resume with failure context.
9. Equivalent classified failures consume a retry budget. Model escalation is
   rare, explicit, and never caused by capacity, provider outages, or queue wait.
10. Pause stops admission immediately; drain allows active execution/delivery to
    finish; hard stop is scoped to one project cgroup; resume reconciles first.

## Target architecture

### Provider plane

`GitHubGateway` is the only network boundary. It owns:

- a global circuit state with reset time, Retry-After, exponential fallback,
  and single-flight recovery probe;
- separate REST/GraphQL budgets and response-header accounting;
- bounded concurrency and request queues;
- typed errors (`rate_limited`, `auth`, `permanent`, `transient`, `schema`);
- cached reads and targeted batch reads;
- metrics exposed to the runtime snapshot.

No tracker adapter, worker, retry timer, dashboard request, startup cleanup, or
delivery controller may call `Req` directly.

### Event and projection plane

The signed webhook receiver acknowledges quickly and persists a delivery
record keyed by `X-GitHub-Delivery`. An event consumer:

- deduplicates and tolerates out-of-order delivery;
- normalizes issue/project/PR/review/check/workflow/push events;
- updates local issue, dependency, PR, and check projections;
- marks only affected issues/stacks dirty;
- wakes targeted admission or delivery reconciliation.

A slow safety sweep runs only if webhook freshness is degraded. It is
single-flight and cannot overlap worker completion refreshes.

### Scheduler plane

The scheduler consumes a local ready queue. It never scans GitHub to fill a
slot. Admission checks local dependency, priority, control state, host budget,
workspace validity, and provider/delivery constraints.

Suggested durable run states:

`queued -> preparing -> executing -> delivering -> waiting_ci -> waiting_merge
-> merged -> cleaning -> complete`

Side paths:

- `waiting_ci(red) -> retry_ready -> executing`
- `waiting_provider -> prior state`
- `paused` / `draining` admission gates
- `failed_permanent` / `retry_exhausted` operator-visible terminals

### Worker and delivery plane

Workers receive scoped repository access and a validated isolated workspace.
They may edit/test/commit locally, but the harness validates the resulting
commit and owns push/PR/automerge operations. A waiting run consumes no model
turn and no execution slot. CI failure wakes the same thread if available;
otherwise it resumes from the durable workpad/workspace.

### Read/observability plane

Transcript deltas are coalesced into a bounded telemetry projection. Lifecycle
events are non-droppable. Dashboard snapshots read from a projection process or
ETS, never synchronously from the scheduler mailbox. The web process can be
rebuilt/restarted independently from active workers.

## 7/10 acceptance scorecard

### Provider safety

- 100 concurrent callers after one synthetic rate-limit response produce at
  most one recovery probe and zero additional provider requests before reset.
- Retry-After/reset headers are honored; malformed metadata uses a conservative
  fallback.
- Provider outages park work without incrementing model failure attempts.
- A one-worker end-to-end run consumes a measured, bounded GitHub request budget.

### Webhooks and reconciliation

- Duplicate delivery IDs have no duplicate effect.
- Issue/PR/check events update only affected projections.
- A missed event is repaired by one bounded safety sweep.
- Normal slot filling performs no board crawl.

### Workspace and permissions

- Partial, nested, wrong-remote, wrong-branch, or parent-discovering directories
  are quarantined/refused before Codex starts.
- Bootstrap is staging-plus-atomic-rename.
- A worker cannot mutate the Patches source checkout or sibling workspaces.
- Runtime and worker cgroups retain host reserve and descriptor limits.

### Delivery and quality

- One sandbox issue produces an isolated commit, pushed branch, PR, observed CI,
  auto-merge, tracker completion, and safe workspace cleanup.
- A forced red check resumes the same run and succeeds on a later slot.
- Delivery remains waiting, not successful, if no PR or merge proof exists.

### Retry and escalation

- Capacity and provider waits do not increment failure attempts.
- Equivalent code/CI failures retry with jitter and a finite budget.
- Luna remains default; Terra review/worker is policy-driven; Sol escalation
  occurs only after repeated classified failure and records its reason.

### Control and recovery

- Pause acknowledgement prevents all new worker/retry/reviewer starts.
- Drain reaches paused after active delivery/cleanup finishes.
- Restart preserves control, ready queue, attempts, PR watches, and cleanup work.
- Hard stop affects only the selected project service/cgroup.

### Observability and testability

- API reports build SHA, config hash, start time, control state, provider
  circuits, webhook freshness, lifecycle state, transcript/session identity,
  resources, and next action.
- Snapshot p99 remains bounded under six simulated delta streams.
- Unit/integration tests require no live GitHub/model quota.

## Implementation sequence

1. Provider gateway contract and deterministic fake; move every call site.
2. Durable event/projection store and webhook ingestion/deduplication.
3. Ready queue and bounded reconciliation; remove hot board polling.
4. Atomic workspace validation and scoped worker execution.
5. Durable run/delivery controller with PR/CI/merge/cleanup adapters.
6. Classified retry ledger, parked waits, and escalation policy.
7. Pause/drain/resume and independent read projection/web process boundary.
8. Fault-injected tests, then one-worker live acceptance run.

## Relaunch gate

Do not launch a production Patches pool until provider-gate, webhook dedupe,
workspace-isolation, and delivery-state tests pass. The first live run uses
`max_concurrent_agents: 1`, records GitHub requests and model turns, and stops
automatically if any budget, isolation, or lifecycle invariant is violated.

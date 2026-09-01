---
tracker:
  kind: github
  api_key: "$GITHUB_TOKEN"
  project_slug: "$GITHUB_PROJECT_NUMBER"
  repo_owner: "$GITHUB_REPO_OWNER"
  repo_name: "$GITHUB_REPO_NAME"
  project_owner_type: "$GITHUB_PROJECT_OWNER_TYPE"
  project_owner_login: "$GITHUB_PROJECT_OWNER_LOGIN"
  project_title: "$GITHUB_PROJECT_TITLE"
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Closed
    - Canceled
  status_map:
    Todo:
      state: open
    In Progress:
      state: open
    Human Review:
      state: open
    Rework:
      state: open
    Merging:
      state: open
    Done:
      state: closed
      state_reason: completed
    Canceled:
      state: closed
      state_reason: not_planned
polling:
  # Webhooks and targeted completion refreshes are the normal event path.
  # This is only a missed-event safety sweep.
  interval_ms: 900000
workspace:
  root: ~/develop/patches/.polyphony/workspaces
hooks:
  after_create: |
    issue_id="$(basename "$PWD")"
    repo_owner="${GITHUB_REPO_OWNER:-alliecatowo}"
    repo_name="${GITHUB_REPO_NAME:-patches}"
    repo_url="${GITHUB_REPO_URL:-git@github.com:${repo_owner}/${repo_name}.git}"
    if [ ! -d .git ]; then
      git clone --quiet "$repo_url" .
    else
      git remote set-url origin "$repo_url"
    fi
    git fetch origin main --quiet || true
    base_ref="origin/main"
    git rev-parse --verify "$base_ref" >/dev/null 2>&1 || base_ref=HEAD
    git switch --create "agent/polyphony-${issue_id}" "$base_ref"
  before_run: |
    issue_id="$(basename "$PWD")"
    # Older worker attempts injected a temporary .codex/config.toml. Clean up
    # only that harness-owned path before a retry so Codex never spends a turn
    # repairing runtime scaffolding. Current workers use the isolated CODEX_HOME
    # profile and leave the project checkout untouched.
    if git diff --quiet -- .codex/config.toml; then
      true
    else
      git restore --source=HEAD -- .codex/config.toml
    fi
    mkdir -p "docs/issues/${issue_id}/logs" "docs/issues/${issue_id}/evidence" "docs/issues/${issue_id}/decisions" "docs/issues/${issue_id}/spikes"
    printf '%s phase=before_run workspace=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" >> "docs/issues/${issue_id}/run-log.md"
  after_run: |
    issue_id="$(basename "$PWD")"
    printf '%s phase=after_run workspace=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" >> "docs/issues/${issue_id}/run-log.md"
  before_remove: |
    true
worker:
  # Model profiles are selected per Codex thread below. Polyphony itself runs locally.
  ssh_hosts: []
  max_concurrent_agents_per_host: 3
  # Hard limits are applied to each Codex process tree with systemd-run --user.
  # Leave headroom on this workstation's 14 GiB RAM / 16 CPU threads while
  # allowing concurrent builds and test suites.
  cpu_quota_percent: 600
  memory_max_mb: 6144
  tasks_max: 1536
  cgroup_required: true
agent:
  # Validate the bounded harness one worker at a time before scaling the pool
  # back up. The systemd/cgroup limits remain the hard safety bound.
  max_concurrent_agents: 1
  # One execution turn owns the slot. The harness then delivers and parks on
  # CI/merge webhooks; a red result resumes the same workspace/session.
  max_turns: 1
  # Luna gets the first repair, Terra gets the second, Sol gets the final
  # escalation. Further retries are persisted as failed instead of consuming
  # the worker pool indefinitely.
  max_delivery_retry_attempts: 3
codex:
  # Workers run in isolated app-server processes. Keep the inherited shell
  # environment for the project toolchain, but do not pass ad-hoc MCP table
  # overrides here: malformed project MCP entries make Codex exit before a
  # worker can start. Browser MCP is disabled by the worker workspace config
  # when it is not needed.
  command: /home/allie/develop/polyphony/scripts/codex-worker-app-server.sh --disable apps --config shell_environment_policy.inherit=all app-server
  # Do not attach workers to the user's interactive app-server daemon. That
  # daemon can carry the active VS Code/Codex conversation into every thread,
  # multiplying input tokens and leaking unrelated instructions. Each worker
  # gets a clean local app-server process under Polyphony's isolated CODEX_HOME.
  shared_app_server: false
  read_timeout_ms: 30000
  models:
    default: gpt-5.6-luna
    review: gpt-5.6-terra
    # Premium Sol is selected only by an explicit `escalate: sol` issue
    # marker or an equivalent explicit runtime signal; retries never select it.
    escalation: gpt-5.6-sol
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
  # Bound one model turn so a pathological context/tool loop cannot consume
  # the whole account allowance. The harness preserves the workspace and
  # retries/escalates after the worker exits.
  # Keep one pathological turn below the Luna context cliff. Retries preserve
  # the workspace and delivery evidence instead of replaying an unbounded
  # transcript.
  max_total_tokens: 250000
server:
  host: "127.0.0.1"
  port: 4000
---

You are working on a GitHub issue `{{ issue.identifier }}`

Repository artifact convention:

- Use `docs/issues/<issue-id>/` for all per-issue artifacts.
- Keep `plan.md`, `run-log.md`, and `handoff.md` updated for each run.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Resume the same coherent local slice, but return to the harness after local validation; do not wait on remote systems.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

## Worker/harness ownership boundary (highest priority)

- The worker owns investigation, implementation, local validation, and concise handoff notes only.
- Polyphony's harness owns `git commit`, `git push`, pull-request creation/update, auto-merge, CI observation, retries, escalation, and workspace cleanup. Never perform those harness operations from this turn.
- Never wait for or poll CI, deployments, reviews, mergeability, or a human decision. Query remote state once when needed for context; after local validation, return control immediately so the token-free harness can observe events.
- If an issue already has a PR and there is actionable feedback, make and validate the required local correction. If it is merely waiting for CI/review/merge or its branch is not the provided workspace branch, record that state and return immediately without repeated remote queries.
- One turn should complete one coherent local slice. An active tracker state is not a reason to keep the model alive after the slice is locally validated or externally blocked.
- Context budget is a hard production constraint. Never `cat` or otherwise dump `tasks.md`, lockfiles, generated output, dependency directories, full logs, or a full repository diff. Use `rg` for targeted discovery and `sed -n` or `git diff -- <path>` for focused excerpts, keeping each excerpt under 200 lines. Bound command output with `head`/`tail`, do not repeat an unchanged command, and summarize results in the issue workpad instead of replaying them in later turns.
- Do not use a browser login or other interactive external-auth flow. Record the exact access blocker and return control.

## Slice and stacked-PR policy

- Treat the board as a dependency graph, not a FIFO list. The injected Board context is a compact planning hint; verify the live Project fields, blockers, parent/sub-issues, and linked PRs before editing.
- Prefer a coherent vertical slice: work on a parent issue and its disjoint leaves together when the board has an explicit parent/sub-issue relationship or shared `slice:` label. Keep heavy CI at the slice boundary and avoid duplicating full-suite runs for every leaf.
- Normal implementation workers may prepare one logical change or stack layer, but must not merge. Keep branches in the Patches repository and preserve the repository's existing `gh-stack` skill.
- A worker assigned an issue labelled `stack`, `stacked-pr`, `stack-reconcile`, or `stack/reconcile` is the Terra stack reconciler. It must inspect the complete stack with `gh stack view --json`, synchronize/rebase with `gh stack sync` and `gh stack rebase` as needed, wait for all required checks, and use `gh stack merge --yes` only when every stack PR is green and no human hold is present. Reconcile issue statuses and workpads for the whole stack afterward.
- When a normal worker finishes a coherent stacked slice and has opened/updated its PRs, it must add `stack-reconcile` to the slice's lead issue and leave the lead issue active. This is the handoff signal that causes the next poll to dispatch Terra for whole-stack reconciliation.
- Do not invent a stack or merge a single PR merely because one issue is complete. If the stack is ambiguous, leave it in review and record the exact blocker.

Work only in the provided repository copy. Do not touch any other path.

## Required worker handoff

Unless the issue is genuinely blocked or already waiting on remote state,
finish the smallest coherent implementation and its local validation. Leave
the resulting workspace changes for the harness to commit and publish. Keep
generated workpads under `docs/issues/<issue-id>/` and include validation or
the evidence-backed blocker in the handoff.

## Prerequisite: GitHub MCP or `github_graphql` tool is available

The agent should be able to talk to GitHub, either via a configured GitHub MCP server or injected `github_graphql` tool. If none are present, stop and ask the user to configure GitHub.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent GitHub comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate GitHub issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `github`: interact with GitHub.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- Do not invoke `commit`, `push`, or `land` from a normal implementation worker; Polyphony invokes delivery and reconciliation separately.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Human Review`).
- `In Progress` -> implementation actively underway.
- `Human Review` -> inspect attached PR state once and return immediately.
- `Merging` -> approved by human; execute the `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Human Review` -> inspect once for actionable feedback, then return immediately.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/polyphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from GitHub issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> Human Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before handoff.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Run the required local validation for your scope; if it fails, address issues and rerun until green.
8.  Do not commit, push, create/update a PR, merge, or wait for CI. Preserve the validated workspace for Polyphony's delivery harness.
9.  Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
10. If an attached PR had actionable feedback at kickoff, inspect that feedback once:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Address feedback already present, but never wait for checks or new comments; the harness owns subsequent events.
11. Return control immediately after the local handoff is complete. The harness performs delivery and status transitions.

## Step 3: Human Review and merge handling

1. When the issue is in `Human Review`, do not code or change ticket content.
2. Inspect current review state once. Never poll; return control to the harness if no actionable feedback is present.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, human moves the issue to `Merging`.
5. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before Human Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`polyphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, address already-present actionable feedback or return immediately; never wait or poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````

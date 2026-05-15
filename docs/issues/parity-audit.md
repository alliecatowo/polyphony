# GitHub vs Linear Parity Audit (Research Worker C)

Date: 2026-05-15
Scope: `main` branch runtime parity for milestones, parent/child, labels, project fields, PR lifecycle, and `docs/issues` artifacts.

## Current Status

- Targeted tests pass:
  - `elixir/test/symphony_elixir/github_client_integration_test.exs`
  - `elixir/test/symphony_elixir/orchestrator_github_reconcile_test.exs`
- Existing parity coverage is solid for:
  - labels/milestone/assignees/dependencies reconciliation
  - project custom-field write helpers (number/date/iteration/text/single-select)
  - project-status-driven issue state projection
  - linked PR signal normalization and blocker-state-aware dispatch gating
  - `docs/issues/<issue-id>/` artifact convention in docs/spec

## Highest-Priority Gaps

1. Parent/child relationship writes are not in the orchestrator reconciliation path.
- Why priority: hierarchy is a first-class primitive requirement and currently only available as low-level client/adapter functions.
- Evidence:
  - Parent/sub mutations exist:
    - `elixir/lib/symphony_elixir/github/client.ex:645`
    - `elixir/lib/symphony_elixir/github/client.ex:654`
    - `elixir/lib/symphony_elixir/github/client.ex:663`
    - `elixir/lib/symphony_elixir/github/adapter.ex:46`
  - Tracker reconciliation does not call any hierarchy reconcile hook:
    - `elixir/lib/symphony_elixir/tracker.ex:120`
    - `elixir/lib/symphony_elixir/tracker.ex:149`
- TODO:
  - Add desired hierarchy extraction in tracker (`parent_issue_id`, `sub_issue_ids`, optional order).
  - Add adapter/client hook (e.g. `reconcile_issue_hierarchy/2`) that diffs and applies `add/remove/reprioritize_sub_issue`.
  - Add orchestration tests for invocation + failure tolerance in `orchestrator_github_reconcile_test.exs`.

2. Project bootstrap only guarantees `Points` and `Progress`; required `Status` options are not enforced.
- Why priority: status is now canonical for workflow state; missing/incorrect options can break state projection.
- Evidence:
  - Default required fields only:
    - `elixir/lib/symphony_elixir/github/client.ex:2004`
  - Tracker config defaults required fields to empty:
    - `elixir/lib/symphony_elixir/config/schema.ex:73`
  - Status map exists, but no bootstrap linkage to ensure matching project options:
    - `elixir/lib/symphony_elixir/config/schema.ex:47`
- TODO:
  - Extend project bootstrap to ensure a `Status` single-select field exists with options derived from config (`active_states`, `terminal_states`, and/or `status_map` keys).
  - Add validation that configured `status_map` references realizable project status options.
  - Add integration tests in `github_client_integration_test.exs` for project creation + status option provisioning.

3. PR lifecycle hooks are read-driven but not concretely implemented for lifecycle actions.
- Why priority: parity expectation includes PR lifecycle influence, but current hooks can silently no-op.
- Evidence:
  - Tracker invokes optional lifecycle hooks:
    - `elixir/lib/symphony_elixir/tracker.ex:125`
    - `elixir/lib/symphony_elixir/tracker.ex:133`
  - No corresponding functions are defined in GitHub adapter/client.
- TODO:
  - Implement explicit GitHub adapter/client handlers:
    - `react_to_merged_linked_prs/1`
    - `mark_closed_pr_rework_redispatch_ready/1`
  - Decide policy (comment-only, status transition, project-field update, or combination) and test it.

4. `docs/issues` artifact lifecycle is documented, but runtime validation/enforcement tests are still thin.
- Why priority: this is the new canonical artifact surface and should be deterministic under automation.
- Evidence:
  - Convention documented in README/SPEC/WORKFLOW, but no focused ExUnit coverage for script behavior in current targeted suites.
- TODO:
  - Add deterministic script tests for path creation/fallback behavior (prefer `docs/issues`, legacy fallback compatibility).
  - Validate that issue IDs are normalized safely and directories are always created under repo root.

## Lower-Priority Gap

5. Milestone/assignee/label policy modes (required/optional/ignored) remain implicit.
- Why lower: reconciliation works today; this is policy control, not base capability.
- TODO:
  - Add config-driven policy layer to selectively enforce primitives by repo/workflow.


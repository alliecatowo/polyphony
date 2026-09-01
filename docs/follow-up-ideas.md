# Polyphony follow-up backlog

These ideas are intentionally separate from the basic Patches runtime batch.
They should be implemented on a development branch and scheduled only after
the core dispatch path is stable.

## MCP control and observation

Expose Symphony through an authenticated MCP channel so Claude or another
agent can monitor the swarm live, subscribe to state, completion, failure,
stall, health, and resource events, request issue or slice prioritization, and
pause/drain, resume, or hard-stop the runtime. Define permission boundaries,
event schemas, backpressure, and idempotent controls on top of the API.

## Live API and transcripts

Expand the API with live subscriptions, correlated issue/session lifecycle
events, app-server health, resource usage, searchable paginated transcripts,
redaction, and dashboard transcript views with clear failure diagnostics.

## Reviewers and stack reconcilers

Dispatch one reviewer/reconciler per PR stack when review-ready counts,
milestones, stack completion, or accumulated points justify it. Review the
whole stack, repair or rebase failing PRs, and auto-merge only when checks,
approvals, dependency order, and policy allow it. Integrate `gh-stack` when
enabled and keep merge actions auditable.

## Shared design system

Extract the OpenAI small styling into documented tokens, typography, spacing,
colors, controls, status/event states, responsive layout, and accessible
patterns before expanding the dashboard, controls, worker views, or transcript
UI.

# Polyphony Elixir

This directory contains the Elixir/OTP reference implementation for Polyphony, aligned with
[`SPEC.md`](../SPEC.md).

> [!WARNING]
> This is prototype software for trusted environments.

## Scope

- This is the Elixir reference implementation of the Symphony spec on GitHub.
- Orchestrator semantics follow the Polyphony spec contract (`SPEC.md`).
- Tracker semantics are implemented with GitHub Issues/Projects primitives.
- Existing runtime module names and binaries remain unchanged for compatibility.

## How it works

1. Polls tracker work items
2. Creates one workspace per issue
3. Runs Codex App Server in each delegated workspace
4. Applies workflow policy from `WORKFLOW.md`
5. Stops/cleans up when items become terminal

Per-issue run artifacts are written under `docs/issues/<issue-id>/`.

## Why GitHub-first

GitHub-native planning avoids external tracker limits and keeps issues, project metadata, PRs,
checks, and history in one durable system tied to repository history.

This keeps orchestration behavior and delivery evidence in one system:

- issues and project fields for planning/state
- pull requests, reviews, and checks for execution/quality
- repository history for long-term traceability

The result is a practical, no-extra-SaaS path for teams that want Symphony-style agent orchestration
without leaving GitHub.

## Run

```bash
git clone https://github.com/your-org/polyphony
cd polyphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## GitHub App Webhook (Local)

If you run a private GitHub App with a local tunnel/Funnel, start the webhook receiver with:

```bash
cd elixir
mise run webhook
```

Expose it publicly with Tailscale Funnel:

```bash
cd elixir
mise run funnel
```

Turn Funnel back off:

```bash
cd elixir
mise run funnel-stop
```

This exposes:

- `POST /github/webhook`

Required environment variable:

- `GITHUB_WEBHOOK_SECRET`

The `webhook` task auto-loads `../.env` when present.

## GitHub OAuth For User-Owned Projects

When `tracker.project_owner_type` is `user`, Project v2 GraphQL operations run as the signed-in
user (OAuth token), while issue/PR/repo automation continues to use app identity.

1. Set callback URL in your GitHub App:
   - Local: `http://127.0.0.1:4000/auth/github/callback`
   - Funnel: `https://<your-funnel-host>/auth/github/callback`
2. Ensure `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` are in `elixir/.env`.
3. Start Polyphony (`mise run webhook`) and open:
   - `http://127.0.0.1:4000/auth/github/start`
4. Complete GitHub auth; callback stores token in runtime memory.

Current auth note:

- Webhook verification uses `GITHUB_WEBHOOK_SECRET`.
- Tracker API auth selection for GitHub (`tracker.kind: github`) is:
  1. `tracker.api_key` from `WORKFLOW.md` (including `$GITHUB_TOKEN` resolution), if present.
  2. Otherwise, `GITHUB_APP_ID` + `GITHUB_PRIVATE_KEY`: Polyphony mints an app JWT, discovers the installation for
     `tracker.repo_owner`/`tracker.repo_name`, then mints and caches an installation access token.
- `GITHUB_INSTALLATION_ID` is not required.

## Configuration

`WORKFLOW.md` provides YAML front matter plus prompt body. Example shape:

```md
---
tracker:
  kind: github
workspace:
  root: ~/code/workspaces
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a GitHub issue {{ issue.identifier }}.
```

## Testing

```bash
mise exec -- mix test
```

## License

This project is licensed under the [Apache License 2.0](../LICENSE).

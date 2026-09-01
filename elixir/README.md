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

### Required `elixir/.env` (User-Owned Projects)

- `GITHUB_APP_ID`
- `GITHUB_PRIVATE_KEY`
- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `GITHUB_WEBHOOK_SECRET`
- `GITHUB_REPO_OWNER`
- `GITHUB_REPO_NAME`
- `GITHUB_PROJECT_OWNER_TYPE=user`
- `GITHUB_PROJECT_OWNER_LOGIN`
- `GITHUB_PROJECT_NUMBER` (for URL like `/users/<login>/projects/<number>`)
- `GITHUB_PROJECT_TITLE`

### One-Pass Flow

1. `cd elixir && mise run webhook`
2. `cd elixir && mise run oauth-start`
3. `cd elixir && mise run funnel` (optional for remote callback/webhooks)

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

### Patches worker profile

The checked-in `WORKFLOW.md` is configured for the GitHub Patches project at
`alliecatowo/patches` (user Project 5). It uses one local Codex app-server daemon and selects
`gpt-5.6-luna` for normal issues, `gpt-5.6-terra` for review/stack work, and `gpt-5.6-sol` for
escalation/audit or retry attempt 2+.

The profile uses isolated workspace clones under `~/develop/patches/.polyphony/workspaces`, made
from the local Patches checkout at `~/develop/patches`.

Each worker process tree is launched in a required per-run cgroup on the selected host: 600% CPU,
6 GiB memory, and 1536 tasks. The current workstation-safe profile allows two workers total;
the per-worker limits are deliberately generous for builds and tests while the admission cap
prevents both workers from exhausting the machine simultaneously. A local systemd cgroup
preflight passes on the development machine.

The board planner consumes Project v2 Priority, Area, Kind, Status, parent/sub-issue, dependency,
and linked-PR signals. It sends each worker a compact top-of-board context so workers can preserve
dependency order. For true multi-issue slices, use explicit parent/sub-issue relationships or a
shared `slice:` label. A `stack-reconcile` or `stack/reconcile` label routes the work to Terra and
instructs that worker to use the installed `gh stack` skill to review/rebase/merge the complete
stack only after all checks are green.

For a local run, keep credentials in the ignored `elixir/.env`, load them, and start from the
Elixir directory:

```bash
cd elixir
set -a; . ./.env; set +a
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

The recommended Patches launcher performs the local cgroup preflight first:

```bash
/home/allie/develop/polyphony/scripts/launch-patches.sh
```

It refuses to start if the local user cgroup cannot be created.

For an unattended machine run, install the persistent user services once:

```bash
/home/allie/develop/polyphony/scripts/install-patches-unattended.sh
```

This enables user lingering and installs the orchestrator and health watchdog
under the user systemd manager. The services start with the user manager,
survive logout, and restart automatically after a process failure or machine
reboot. The same cgroup limits and GitHub/Codex credential bootstrap used by
the launcher remain in effect.

Preflight without starting the poller:

```bash
cd elixir
set -a; . ./.env; set +a
mise exec -- mix run --no-start -e 'IO.puts(SymphonyElixir.Config.validate!())'
systemd-run --user --scope --quiet --collect --unit=polyphony-preflight \
  --property=CPUQuota=250% --property=MemoryMax=3072M --property=TasksMax=384 \
  --property=KillMode=control-group -- true
```

On this Fedora workstation, `.env` also supplies the Homebrew OpenSSL library path required by
the locally compiled Erlang runtime.

The dashboard is served at `http://127.0.0.1:4000/` by default, or on the configured bind host.
Codex uses the existing ChatGPT login from
`~/.codex`; no OpenAI API key is required by Polyphony.

## Testing

```bash
mise exec -- mix test
```

## License

This project is licensed under the [Apache License 2.0](../LICENSE).

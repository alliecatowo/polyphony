# Polyphony Elixir

This directory contains the Elixir/OTP reference implementation for Polyphony, aligned with
[`SPEC.md`](../SPEC.md).

> [!WARNING]
> This is prototype software for trusted environments.

## Scope

- Orchestrator semantics follow the Polyphony spec contract (`SPEC.md`).
- Tracker semantics are documented as GitHub Issues/Projects primitives.
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

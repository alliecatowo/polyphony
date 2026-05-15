# Polyphony Elixir

This directory contains the Elixir orchestration service. Keep implementation behavior aligned with
[`../SPEC.md`](../SPEC.md): Symphony orchestration semantics mapped onto GitHub Issues/Projects
primitives.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`
- Install deps: `mix setup`
- Quality gate: `make all`

## Conventions

- Load runtime config from `WORKFLOW.md` front matter via existing config modules.
- Preserve workspace isolation and safety boundaries.
- Keep orchestrator retry/reconciliation behavior stable.
- Keep changes narrowly scoped and avoid unrelated refactors.
- Do not rename runtime modules/binaries in docs-only changes.

## Validation

```bash
make all
mix specs.check
```

## PR Description

Use [`../.github/pull_request_template.md`](../.github/pull_request_template.md).

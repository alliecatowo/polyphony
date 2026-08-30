#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
elixir_root="$repo_root/elixir"
workflow="$elixir_root/WORKFLOW.md"

if [[ ! -f "$elixir_root/.env" ]]; then
  echo "Polyphony Patches launch refused: $elixir_root/.env is missing" >&2
  exit 1
fi

if ! command -v systemd-run >/dev/null 2>&1; then
  echo "Polyphony Patches launch refused: systemd-run is required for worker cgroups" >&2
  exit 1
fi

systemd-run --user --scope --quiet --collect \
  --unit="polyphony-preflight-$$" \
  --property=CPUQuota=250% \
  --property=MemoryMax=3072M \
  --property=TasksMax=384 \
  --property=KillMode=control-group \
  -- true >/dev/null

cd "$elixir_root"

if command -v brew >/dev/null 2>&1; then
  if openssl_prefix="$(brew --prefix openssl@3 2>/dev/null)"; then
    openssl_lib="$openssl_prefix/lib"
    if [[ -d "$openssl_lib" ]]; then
      export LD_LIBRARY_PATH="$openssl_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
  fi
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

host_args=()
if [[ -n "${POLYPHONY_HOST:-}" ]]; then
  host_args=(--host "$POLYPHONY_HOST")
fi
public_host_args=()
if [[ -n "${POLYPHONY_PUBLIC_HOST:-}" ]]; then
  public_host_args=(--public-host "$POLYPHONY_PUBLIC_HOST")
fi

exec systemd-run --user --scope --quiet --collect \
  --unit="polyphony-orchestrator" \
  --property=CPUQuota=250% \
  --property=MemoryMax=3072M \
  --property=TasksMax=384 \
  --property=OOMPolicy=kill \
  --property=KillMode=control-group \
  -- mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "${host_args[@]}" \
  "${public_host_args[@]}" \
  "$workflow"

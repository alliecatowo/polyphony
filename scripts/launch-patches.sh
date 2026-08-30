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

# Raise the inherited descriptor limit before launching the scope. Some user
# systemd installations reject LimitNOFILE as a transient property.
ulimit -n 16384

systemd-run --user --scope --quiet --collect \
  --unit="polyphony-preflight-$$" \
  --property=CPUQuota=800% \
  --property=MemoryMax=10240M \
  --property=TasksMax=2048 \
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

# Board schema/item maintenance is an explicit bootstrap action, not part of
# the hot polling path. This keeps candidate discovery responsive.
export POLYPHONY_SKIP_BOARD_BOOTSTRAP=1
export POLYPHONY_SKIP_BOARD_ENRICHMENT=1

# Keep Codex sandboxes and transient files out of shared /tmp pressure, and
# give the shared app-server enough descriptors for six workers.
runtime_tmp="$repo_root/.runtime-tmp"
mkdir -p "$runtime_tmp"
export TMPDIR="$runtime_tmp"

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
  --property=CPUQuota=800% \
  --property=MemoryMax=10240M \
  --property=TasksMax=2048 \
  --property=OOMPolicy=kill \
  --property=KillMode=control-group \
  -- mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  "${host_args[@]}" \
  "${public_host_args[@]}" \
  "$workflow"

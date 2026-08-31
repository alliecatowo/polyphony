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

# Use the credential already authenticated in GitHub CLI when available. This
# keeps the GraphQL project API and gh/git children on the same working token.
if command -v gh >/dev/null 2>&1; then
  gh_token="$(gh auth token 2>/dev/null || true)"
  if [[ -n "$gh_token" ]]; then
    export GITHUB_TOKEN="$gh_token"
    export GITHUB_OAUTH_TOKEN="$gh_token"
    export GH_TOKEN="$gh_token"
  fi
fi

# GITHUB_PAT is the verified credential on this workstation. Prefer it for
# both the tracker client and gh/git child processes when present, because an
# older GITHUB_TOKEN may still be exported by the user's shell.
if [[ -n "${GITHUB_PAT:-}" ]]; then
  export GITHUB_TOKEN="$GITHUB_PAT"
  export GITHUB_OAUTH_TOKEN="$GITHUB_PAT"
  export GH_TOKEN="$GITHUB_PAT"
fi

# Board schema/item maintenance is an explicit bootstrap action, not part of
# the hot polling path. This keeps candidate discovery responsive.
export POLYPHONY_SKIP_BOARD_BOOTSTRAP=1
export POLYPHONY_SKIP_BOARD_ENRICHMENT=1
export POLYPHONY_RUNTIME_STATE_DIR="$elixir_root/.polyphony/runtime"
export POLYPHONY_PROJECT_ID="${POLYPHONY_PROJECT_ID:-patches}"
export POLYPHONY_PROJECT_CGROUP="${POLYPHONY_PROJECT_CGROUP:-polyphony-patches.service}"

# Keep Codex sandboxes and transient files out of shared /tmp pressure, and
# give the shared app-server enough descriptors for six workers.
runtime_tmp="$repo_root/.runtime-tmp"
mkdir -p "$runtime_tmp"
export TMPDIR="$runtime_tmp"

# The daemon executes the checked-in escript, which loads the compiled
# application. Always refresh that artifact before a launch so a restart after
# a source update cannot silently run an older build. Set POLYPHONY_SKIP_BUILD
# only for an emergency restart where preserving the current artifact is
# intentional.
if [[ "${POLYPHONY_SKIP_BUILD:-0}" != "1" ]]; then
  mise exec -- mix build
fi

host_args=()
if [[ -n "${POLYPHONY_HOST:-}" ]]; then
  host_args=(--host "$POLYPHONY_HOST")
fi
public_host_args=()
if [[ -n "${POLYPHONY_PUBLIC_HOST:-}" ]]; then
  public_host_args=(--public-host "$POLYPHONY_PUBLIC_HOST")
fi
library_args=()
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  library_args=(--setenv="LD_LIBRARY_PATH=$LD_LIBRARY_PATH")
fi
auth_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_args+=(
    --setenv="GITHUB_TOKEN=$GITHUB_TOKEN"
    --setenv="GITHUB_OAUTH_TOKEN=${GITHUB_OAUTH_TOKEN:-$GITHUB_TOKEN}"
    --setenv="GH_TOKEN=${GH_TOKEN:-$GITHUB_TOKEN}"
  )
fi
for config_var in \
  GITHUB_OAUTH_TOKEN \
  GITHUB_REPO_OWNER \
  GITHUB_REPO_NAME \
  GITHUB_REPO_URL \
  GITHUB_PROJECT_NUMBER \
  GITHUB_PROJECT_OWNER_TYPE \
  GITHUB_PROJECT_OWNER_LOGIN \
  GITHUB_PROJECT_TITLE \
  GITHUB_ASSIGNEE \
  GITHUB_WEBHOOK_SECRET \
  POLYPHONY_SKIP_BOARD_BOOTSTRAP \
  POLYPHONY_SKIP_BOARD_ENRICHMENT \
  POLYPHONY_RUNTIME_STATE_DIR \
  POLYPHONY_PROJECT_ID \
  POLYPHONY_PROJECT_CGROUP; do
  if [[ -n "${!config_var:-}" ]]; then
    auth_args+=(--setenv="$config_var=${!config_var}")
  fi
done

polyphony_args=(
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
  "${host_args[@]}"
  "${public_host_args[@]}"
  "$workflow"
)

if [[ "${POLYPHONY_FOREGROUND:-0}" == "1" ]]; then
  exec systemd-run --user --scope --quiet --collect \
    --working-directory="$elixir_root" \
    "${library_args[@]}" \
    "${auth_args[@]}" \
    --unit="polyphony-orchestrator" \
    --property=CPUQuota=800% \
    --property=MemoryMax=10240M \
    --property=TasksMax=2048 \
    --property=OOMPolicy=kill \
    --property=KillMode=control-group \
    -- bash -lc 'ulimit -n 16384; exec mise exec -- ./bin/symphony "$@"' bash \
    "${polyphony_args[@]}"
else
  # A detached service is required for nohup/background launches: a scope is
  # owned by its invoking shell and can leave only orphaned children behind.
  if ! systemctl --user is-active --quiet polyphony-orchestrator-watchdog.service; then
    systemd-run --user --quiet --collect --no-block \
      --unit="polyphony-orchestrator-watchdog.service" \
      --property=Restart=always \
      --property=RestartSec=5s \
      --property=CPUQuota=1% \
      --property=MemoryMax=64M \
      --property=TasksMax=32 \
      -- bash "$repo_root/scripts/watch-patches.sh"
  fi

  # Keep an unattended batch alive even if the BEAM exits cleanly after an
  # unexpected application shutdown. An explicit systemctl stop still
  # remains a stop and is not restarted by systemd.
  exec systemd-run --user --quiet --collect --no-block \
    --working-directory="$elixir_root" \
    "${library_args[@]}" \
    "${auth_args[@]}" \
    --unit="polyphony-orchestrator.service" \
    --property=Restart=always \
    --property=RestartSec=5s \
    --property=CPUQuota=800% \
    --property=MemoryMax=10240M \
    --property=TasksMax=2048 \
    --property=OOMPolicy=kill \
    --property=KillMode=control-group \
    -- bash -lc 'ulimit -n 16384; exec mise exec -- ./bin/symphony "$@"' bash \
    "${polyphony_args[@]}"
fi

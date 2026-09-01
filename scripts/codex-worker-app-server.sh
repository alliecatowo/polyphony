#!/usr/bin/env bash

set -euo pipefail

# Each worker gets its own mutable Codex config. Sharing CODEX_HOME lets one
# trusted workspace re-enable project MCP servers for every later worker.
# Authentication, packages, and the session store remain shared explicitly.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_home="${CODEX_HOME:-$repo_root/.runtime-codex}"
worker_root="$base_home/worker-homes"
worker_home="$worker_root/worker-$$"

mkdir -p "$worker_home"
mkdir -p "$worker_home/app-server-control"
cp "$repo_root/scripts/worker-codex-config.toml" "$worker_home/config.toml"

for shared_name in auth.json packages sessions; do
  if [[ -e "$base_home/$shared_name" ]]; then
    ln -s "$base_home/$shared_name" "$worker_home/$shared_name"
  fi
done

cleanup() {
  rm -rf -- "$worker_home"
}
trap cleanup EXIT HUP INT TERM

export CODEX_HOME="$worker_home"
export CODEX_APP_SERVER_SOCKET="$worker_home/app-server-control/app-server-control.sock"
codex "$@"

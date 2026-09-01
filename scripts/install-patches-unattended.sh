#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
user_name="$(id -un)"

if ! command -v systemctl >/dev/null 2>&1 || ! command -v loginctl >/dev/null 2>&1; then
  echo "Polyphony unattended install refused: user systemd and loginctl are required" >&2
  exit 1
fi

loginctl enable-linger "$user_name"

systemctl --user stop polyphony-orchestrator.service polyphony-orchestrator-watchdog.service 2>/dev/null || true
systemctl --user link --force \
  "$repo_root/systemd/polyphony-orchestrator.service" \
  "$repo_root/systemd/polyphony-orchestrator-watchdog.service"
systemctl --user daemon-reload
systemctl --user enable polyphony-orchestrator.service polyphony-orchestrator-watchdog.service
systemctl --user start polyphony-orchestrator-watchdog.service polyphony-orchestrator.service

echo "Installed persistent Polyphony Patches user services."

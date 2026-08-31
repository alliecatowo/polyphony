#!/usr/bin/env bash

set -euo pipefail

service="polyphony-orchestrator.service"
health_url="${POLYPHONY_HEALTH_URL:-http://127.0.0.1:4000/api/v1/health}"
interval_seconds="${POLYPHONY_WATCHDOG_INTERVAL_SECONDS:-15}"
failure_limit="${POLYPHONY_WATCHDOG_FAILURE_LIMIT:-3}"
failures=0

while :; do
  if curl --max-time 5 --silent --show-error --fail "$health_url" >/dev/null 2>&1; then
    failures=0
  else
    failures=$((failures + 1))
    if (( failures >= failure_limit )); then
      if systemctl --user is-active --quiet "$service"; then
        logger -t polyphony-watchdog "health check failed $failures times; restarting $service"
        systemctl --user restart "$service" || true
      fi
      failures=0
    fi
  fi

  sleep "$interval_seconds"
done

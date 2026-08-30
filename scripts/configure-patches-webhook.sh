#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$repo_root/elixir/.env"

if [[ ! -f "$env_file" ]]; then
  echo "Webhook setup refused: $env_file is missing" >&2
  exit 1
fi

for command in tailscale gh jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Webhook setup refused: $command is required" >&2
    exit 1
  fi
done

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

if [[ -z "${GITHUB_WEBHOOK_SECRET:-}" ]]; then
  echo "Webhook setup refused: GITHUB_WEBHOOK_SECRET is missing" >&2
  exit 1
fi

if [[ -z "${GITHUB_REPO_OWNER:-}" || -z "${GITHUB_REPO_NAME:-}" ]]; then
  echo "Webhook setup refused: repository owner/name are missing" >&2
  exit 1
fi

gh_token="$(gh auth token 2>/dev/null || true)"
if [[ -z "$gh_token" ]]; then
  echo "Webhook setup refused: GitHub CLI is not authenticated" >&2
  exit 1
fi

export GH_TOKEN="$gh_token"

dns_name="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/[.]$//')"
if [[ -z "$dns_name" ]]; then
  echo "Webhook setup refused: this Tailscale node has no DNS name" >&2
  exit 1
fi

callback_url="https://$dns_name/github/webhook"
backend_url="http://127.0.0.1:4000"

# The dashboard remains tailnet-only at the root mount. Only the signed
# webhook path is marked public through Funnel.
tailscale serve --bg --yes "$backend_url" >/dev/null
tailscale funnel --bg --yes --set-path=/github/webhook "$backend_url/github/webhook" >/dev/null

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
payload_file="$temporary_dir/webhook.json"

export POLYPHONY_WEBHOOK_CALLBACK_URL="$callback_url"
jq -n '{
  name: "web",
  active: true,
  config: {
    url: env.POLYPHONY_WEBHOOK_CALLBACK_URL,
    content_type: "json",
    insecure_ssl: "0",
    secret: env.GITHUB_WEBHOOK_SECRET
  },
  events: [
    "issues",
    "pull_request",
    "check_run",
    "check_suite",
    "workflow_run",
    "workflow_job",
    "push"
  ]
}' >"$payload_file"

hook_id="$(
  gh api --paginate "repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME/hooks" \
    --jq ".[] | select(.config.url == \"$callback_url\") | .id" \
    | head -n 1
)"

if [[ -n "$hook_id" ]]; then
  gh api --method PATCH "repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME/hooks/$hook_id" \
    --input "$payload_file" >/dev/null
  action="updated"
else
  gh api --method POST "repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME/hooks" \
    --input "$payload_file" >/dev/null
  action="created"
fi

echo "GitHub webhook $action: $callback_url"
echo "Dashboard (tailnet only): https://$dns_name/"

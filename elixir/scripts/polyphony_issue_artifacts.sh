#!/usr/bin/env sh
set -eu

PHASE="${1:-before_run}"
ISSUE_ID="$(basename "$PWD")"
ROOT_DIR="docs/issues/${ISSUE_ID}"
LEGACY_ROOT_DIR="polyphony/issues/${ISSUE_ID}"
UTC_NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$ROOT_DIR" "$ROOT_DIR/spikes" "$ROOT_DIR/evidence" "$ROOT_DIR/decisions" "$ROOT_DIR/logs"

# Backward-friendly migration: preserve old location if it already exists.
if [ -d "$LEGACY_ROOT_DIR" ]; then
  mkdir -p "$LEGACY_ROOT_DIR" "$LEGACY_ROOT_DIR/spikes" "$LEGACY_ROOT_DIR/evidence" "$LEGACY_ROOT_DIR/decisions" "$LEGACY_ROOT_DIR/logs"
fi

if [ ! -f .polyphony ]; then
  cat > .polyphony <<'POLYPHONY'
Polyphony repository metadata

- Issue artifacts live under `docs/issues/<issue-id>/`.
- Each issue directory should contain planning, decisions, evidence, and final handoff notes.
- Keep files append-only when possible to preserve deterministic run history.
POLYPHONY
fi

if [ ! -f "$ROOT_DIR/README.md" ]; then
  cat > "$ROOT_DIR/README.md" <<README
# ${ISSUE_ID}

- Created: ${UTC_NOW}
- Purpose: Per-issue artifact ledger for Polyphony agent runs.

## Layout
- \`plan.md\`: execution checklist and evolving implementation plan
- \`run-log.md\`: chronological run notes and milestone updates
- \`decisions/\`: ADR-style decision notes
- \`spikes/\`: exploratory investigation docs
- \`evidence/\`: validation evidence and references
- \`handoff.md\`: concise completion summary + blockers
README
fi

for path in "$ROOT_DIR/plan.md" "$ROOT_DIR/run-log.md" "$ROOT_DIR/handoff.md"; do
  if [ ! -f "$path" ]; then
    printf "# %s\n\n" "$(basename "$path" .md | tr '-' ' ' | tr '[:lower:]' '[:upper:]')" > "$path"
  fi
done

printf -- "- %s phase=%s workspace=%s\n" "$UTC_NOW" "$PHASE" "$PWD" >> "$ROOT_DIR/run-log.md"

if [ -d "$LEGACY_ROOT_DIR" ]; then
  for path in "$LEGACY_ROOT_DIR/plan.md" "$LEGACY_ROOT_DIR/run-log.md" "$LEGACY_ROOT_DIR/handoff.md"; do
    if [ ! -f "$path" ]; then
      printf "# %s\n\n" "$(basename "$path" .md | tr '-' ' ' | tr '[:lower:]' '[:upper:]')" > "$path"
    fi
  done

  printf -- "- %s phase=%s workspace=%s\n" "$UTC_NOW" "$PHASE" "$PWD" >> "$LEGACY_ROOT_DIR/run-log.md"
fi

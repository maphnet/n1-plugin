#!/usr/bin/env bash
# Enforces byte budgets on the n1-start standard and investigation instruction paths.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/n1-start"

# Standard path — enumerated statically; adding a new file breaks this test until
# the developer consciously adds it to this list and re-checks the budget.
STANDARD_PATH_FILES=(
  "$SKILL_DIR/SKILL.md"
  "$SKILL_DIR/procedures/telemetry.md"
  "$SKILL_DIR/procedures/input-parsing.md"
  "$SKILL_DIR/procedures/resume.md"
  "$SKILL_DIR/procedures/workspace-isolation.md"
  "$SKILL_DIR/steps/ticket.md"
  "$SKILL_DIR/steps/analysis.md"
  "$SKILL_DIR/steps/brainstorm.md"
  "$SKILL_DIR/steps/estimation.md"
  "$SKILL_DIR/steps/plan.md"
  "$SKILL_DIR/steps/plan-review.md"
  "$SKILL_DIR/steps/implementation.md"
  "$SKILL_DIR/steps/qa.md"
  "$SKILL_DIR/steps/review.md"
  "$SKILL_DIR/review-core.md"
  "$SKILL_DIR/ledger.md"
  "$SKILL_DIR/steps/fix.md"
  "$SKILL_DIR/steps/pr.md"
  "$SKILL_DIR/steps/ci.md"
  "$SKILL_DIR/steps/finish.md"
  "$SKILL_DIR/procedures/output-gates.md"
  "$SKILL_DIR/procedures/cross-repo.md"
  "$SKILL_DIR/procedures/error-recovery.md"
  "$SKILL_DIR/procedures/rules-injection.md"
  "$SKILL_DIR/procedures/finalize.md"
)

MAX_STANDARD_BYTES=81920   # 80 KB

# Investigation path extends the standard path with one additional step file.
INVESTIGATION_PATH_FILES=(
  "${STANDARD_PATH_FILES[@]}"
  "$SKILL_DIR/steps/investigation-deliverable.md"
)
MAX_INVESTIGATION_BYTES=122880  # 120 KB

check_budget() {
  local label="$1" limit="$2"
  shift 2
  local total=0 missing=() large=()
  for f in "$@"; do
    if [ ! -f "$f" ]; then
      missing+=("$f")
      continue
    fi
    local sz
    sz=$(wc -c < "$f")
    total=$((total + sz))
    if [ "$sz" -gt 32768 ]; then   # flag individual files over 32 KB
      large+=("  $f ($sz bytes)")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'FAIL: %s — missing files:\n' "$label"
    printf '  %s\n' "${missing[@]}"
    exit 1
  fi
  if [ "$total" -gt "$limit" ]; then
    printf 'FAIL: %s payload %d bytes > %d limit\n' "$label" "$total" "$limit"
    if [ "${#large[@]}" -gt 0 ]; then
      printf 'Large files (>32 KB):\n'
      printf '%s\n' "${large[@]}"
    fi
    exit 1
  fi
  printf 'PASS: %s %d / %d bytes\n' "$label" "$total" "$limit"
}

check_budget "standard-path"     "$MAX_STANDARD_BYTES"     "${STANDARD_PATH_FILES[@]}"
check_budget "investigation-path" "$MAX_INVESTIGATION_BYTES" "${INVESTIGATION_PATH_FILES[@]}"

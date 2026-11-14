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

MAX_STANDARD_BYTES=95926  #80 KB + 692 bytes for n1-start assign-to-creator guard (NP-190) + 284 bytes for duplicate-check reference (NP-217) + 173 bytes for [plan] tag ledger docs (NP-203) + 318 bytes already over on main before NP-231 + 87 bytes for desc-hash-chain pointers (NP-231) + 336 bytes for orchestrator-only fork scope clause (NP-232) + 965 bytes for ID-reuse check + stale-branch archive (NP-235) + 182 bytes for PR-authorization sentence net of config-read trims (N1-57) + 147 bytes for scoped PR-authorization sentence rewrite (N1-57 review fix) + 249 bytes for the fullAuto chain branch in finish.md (N1-146) + 19 bytes for moving the chain after FINALIZE MEMORY (N1-146) + 134 bytes for chain moved into finalize.md and conditional tell-the-user (N1-146) + 34 bytes for PR-outcome guard on the chain (N1-146 CR-6) + 49 bytes for In Progress move to ticket step and step-order directive (N1-182) + 939 bytes for step begin/end helpers on every step exit path (N1-29) + 314 bytes for local-testing/qa/ticket end-path fixes (N1-29 review CR-1..CR-4) + 52 bytes for empty-run-id guards on the two raw envelope writers (N1-32 CR-1) + 1185 bytes for the workspace decision table, Adopt Checkout and handoff pointers (N1-224) + 234 bytes for splitting the ticket-step block around the workspace step (N1-224 CR-2) + 33 bytes for running the Adopt Checkout card sync inside the adopted checkout (N1-224 Codex fix) + 328 bytes for the Merge path line and no-ask finish hint (N1-240) + 390 bytes for the blocker-check pointer (N1-231) + 148 bytes for the queue-child env-read snippet in ticket.md (N1-231 review fix) + 259 bytes for cycle>=1 soft-pass deferral in review.md and fix.md (N1-261) + 1457 bytes for the fix-step gate rule, fix-cap audit wiring and ledger-row pinning (N1-260) + 1430 bytes for SEC Low deferral at every cycle and pre-existing SEC routing incl. its review fixes (N1-257) + 66 bytes for downgraded pre-existing SEC wording (N1-257 Codex fix) + 575 bytes for the Wait Contract nested-notice resume rule + 99 bytes for the final-status clause in the Wait Contract nested-notice rule (N1-300 review fix) + 9 bytes for current_step in the step-marker line (N1-299); N1-232: lowered from 93013 to 88057 by splitting ticket/analysis/review rare branches into on-demand procedures; +42 bytes for tree-freeze ordering of the pre-existing pointer (N1-232 Codex fix) + 1639 bytes for the resumed-escalated re-ask branch in resume.md (N1-271) + 485 bytes for review-pin head recording in review.md, fix.md and telemetry.md (N1-184) + 237 bytes for question-format pointers in analysis.md and fix.md (N1-216) + 161 bytes for owner-check reaction wording net of busy-guard deletions (N1-308) + 111 bytes for the no-recommendation sentence on the owner stop-or-continue question (N1-308 review fix) + 939 bytes for story-child base reads (N1-291) + 786 bytes for story-child base reads (N1-291) + 177 bytes for branch-point re-anchor on adopt (N1-291 CR-2) + 81 bytes for the N1-404 PreCompact resume text and N1-405 pre-push Codex post-condition already on main + 2671 bytes for the pre-PR moved-HEAD gate in pr.md and its local-testing pointer (N1-439) + 159 bytes for the FAIL-verdict hold in the pre-PR gate (N1-439 SEC-1) + 381 bytes for the intake brief line and output-gates carve-out (N1-445)

# Investigation path extends the standard path with one additional step file.
INVESTIGATION_PATH_FILES=(
  "${STANDARD_PATH_FILES[@]}"
  "$SKILL_DIR/steps/investigation-deliverable.md"
  "$SKILL_DIR/procedures/spike.md"
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

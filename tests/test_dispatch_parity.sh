#!/usr/bin/env bash
# NP-152: implementation routing and injected host routing preserve one shared workflow.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO_ROOT/skills/n1-start/steps/implementation.md"
ROUTING="$REPO_ROOT/references/host-routing.md"
SESSION_START="$REPO_ROOT/hooks/session-start.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
has() { grep -Fq -- "$2" "$1"; }
need() { if has "$2" "$3"; then pass "$1"; else fail "$1 (missing: $3)"; fi; }
need_re() { if grep -Eq -- "$2" "$3"; then pass "$1"; else fail "$1 (missing pattern: $2)"; fi; }
forbid() { if has "$2" "$3"; then fail "$1 (unexpected: $3)"; else pass "$1"; fi; }

# The pipeline chooses personas from planning need, not from the current host.
need "simple route dispatches one developer on every host" "$IMPL" \
  '**Simplicity gate PASS** (all: `TIER==simple`, `BLAST==low`, `FILES_CHANGED<3`): dispatch **developer** persona'
need "direct route dispatches one developer on every host" "$IMPL" \
  '`PLANNING_NEED=direct` → dispatch **developer** persona'
need "planned route dispatches the shared implementer controller" "$IMPL" \
  '**Plan path:** dispatch **implementer** persona'
forbid "implementation step has no Codex-only controller route" "$IMPL" 'Codex headless dispatch'
forbid "implementation step does not select the route by IS_CODEX" "$IMPL" 'IS_CODEX='
forbid "implementation step does not turn direct work into n1-implement" "$IMPL" 'headless dispatch pattern above'

# A timed wait is not a reason to create another worker. The adapter must use only
# continuation capabilities that the active host actually exposes.
need "routing preserves the dispatched worker after a timed wait" "$ROUTING" \
  'wait again for the same worker; never dispatch a replacement because a wait timed out'
need_re "routing selects continuation by actual capability" \
  'followup_task.*send_message.*otherwise dispatch a fresh persona' "$ROUTING"
need_re "routing permits send_input only when exposed" \
  'send_input.*actually exposed' "$ROUTING"

# Agent schemas differ across Codex runtimes. A native profile is preferred only
# when its field is advertised; the generic route receives all of the persona data.
need_re "routing inspects the active dispatch schema" \
  'Inspect.*spawn_agent.*schema.*dispatch' "$ROUTING"
need_re "resolved model and effort remain authoritative" \
  'tab-separated model/effort result is authoritative' "$ROUTING"
need_re "routing gates native persona type on capability" \
  'agent_type.*(field )?supported' "$ROUTING"
need_re "routing has a complete generic persona fallback" \
  'agents/<name>\.md.*complete instructions.*resolved model/effort.*fork-none message' "$ROUTING"

# Interactive availability is likewise runtime capability, not host folklore.
need "routing asks through a question tool only when present" "$ROUTING" \
  'Use an available question tool within its advertised constraints'
need "routing falls back to a plain question" "$ROUTING" \
  'otherwise end the turn with numbered plain-text options'
need "routing treats deferred tools as capability dependent" "$ROUTING" \
  'Use a tool-discovery facility only when it is available'
need "blocking permits queued native completion" "$ROUTING" \
  'A dispatch may return queued or running; wait for its mailbox/result completion before proceeding.'

# The session-start injection is the runtime copy of this contract, so it must
# not reintroduce assumptions that the reference table has removed.
need_re "session injection inspects dispatch capabilities" \
  'spawn_agent schema at dispatch time.*agent_type only if supported' "$SESSION_START"
need_re "session injection keeps the resolved pair authoritative" \
  'tab-separated model/effort result is authoritative' "$SESSION_START"
need_re "session injection has generic persona fallback" \
  'agents/<name>\.md.*complete instructions.*resolved model/effort.*fork-none message' "$SESSION_START"
need_re "session injection waits for queued completion" \
  'queued or running.*mailbox/result completion before proceeding' "$SESSION_START"

# The host adapter is transport only: the persona profile and complete prompt are
# retained, while model/effort and a workspace/brief file reach headless children.
need "routing carries the complete persona prompt and result contract" "$ROUTING" \
  'complete prompt (persona brief, workspace, constraints, and result contract)'
need "routing documents headless effort and brief parameters" "$ROUTING" \
  '[effort] [brief-file]'

# Fork prohibition: Claude Code block must explicitly forbid fork subagents.
need_re "session injection prohibits fork subagent type" \
  'never.*fork' "$SESSION_START"
need "host-routing table documents fork prohibition" "$ROUTING" \
  'Never use subagent_type "fork"'

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

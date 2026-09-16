<!-- n1:step-snippet-exception: FAIL/PASS branching: separate asked/auto-decided telemetry, PASS-only counter and step_end -->

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"; source "$N1_ROOT/lib/frontmatter.sh"
n1_step_begin "fix" 10
REVIEW_FIX_CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
[[ "$REVIEW_FIX_CYCLE" =~ ^[0-9]+$ ]] || REVIEW_FIX_CYCLE=0
FIX_ASTRA_CONTEXT=""
# failed-fix-escalation is legal only when review_fix_cycle >= 2; the counter is
# incremented after each completed failed-review repair, so this is attempt three.
if [ "$REVIEW_FIX_CYCLE" -ge 2 ]; then FIX_ASTRA_CONTEXT=failed-fix-escalation; fi
IFS=$'\t' read -r DEVELOPER_MODEL DEVELOPER_EFFORT < <(n1_resolve_agent developer fix "$FIX_ASTRA_CONTEXT")
QE=$(n1_autonomy_val 'qualityEscalations')
```

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"; N1_HOME=$(n1_home)
PRE_FIX_SHA=$(git rev-parse HEAD)
echo "$PRE_FIX_SHA" > "$N1_HOME/memory/$ID/pre-fix-sha"
```

Run **Ensure Dependencies(`<ID>`)** before spawning.

**FAIL:** spawn developer with `$DEVELOPER_MODEL` and `$DEVELOPER_EFFORT`; pass Critical+High findings, affected files, "Record under `## Fix Cycle <N>` in implementation.md (idempotent). Return: commit SHAs, `Findings fixed: N/M`."

**Security findings** (`[SEC-N]`/CVE): append "Fix the entire CLASS — search all variants and fix in one pass."

After developer returns:
```bash
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"
```

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"; N1_HOME=$(n1_home)
PRE_FIX_SHA=$(cat "$N1_HOME/memory/$ID/pre-fix-sha" 2>/dev/null || echo "HEAD~1")
FIX_CHANGED=$(git diff --name-only "$PRE_FIX_SHA" HEAD)
echo "$FIX_CHANGED" > "$N1_HOME/memory/$ID/fix-changed-files"
```
Emit: `<ID> · review fix cycle <N>/<MAX>`. Return to Step 7. Bound: `review.maxFixAttempts` (default 2).

**Escalation:** `QE==auto-accept`+non-security/architecture/public-API: take recommended, A-tier `[auto]` ledger. Otherwise: resolution ladder (codebase→web→command→prior decisions). Fail all: emit `n1_emit_question_event ... "fix" "quality" "asked" "codebase|web|command|prior-decisions"`. Preamble: `"{Title}: {Core Ask}."` Bug: prepend root-cause. Ask: "{PREAMBLE} Ambiguity: [...]. 1.<recommended> 2.<alt> 3.Decide for me." "Decide for me"→web+apply, emit `"auto-decided"`.

**PASS verdict:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/frontmatter.sh"; n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "clean_passes"
```
`clean_passes < MIN_CLEAN` (default 1) → back to Step 7. `clean_passes >= MIN_CLEAN` → proceed.

**Full-suite regression check** (once at PASS): detect `package.json`, `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod`, `Makefile` (first match). None→skip. Found:
```bash
FULL_SUITE_OUTPUT=$(<discovered-test-command> 2>&1); FULL_SUITE_EXIT=$?
FULL_SUITE_LINES=$(echo "$FULL_SUITE_OUTPUT" | wc -l); [ "$FULL_SUITE_LINES" -gt 100 ] && FULL_SUITE_OUTPUT="[truncated: showing last 100 of $FULL_SUITE_LINES lines]
$(echo "$FULL_SUITE_OUTPUT" | tail -n 100)"
```
Append to `## Fix Cycle <N>`: `**Full-suite:** exit <FULL_SUITE_EXIT> — PASS|FAIL`. When spawning developer for regression fix, pass `$FULL_SUITE_OUTPUT` (already capped) as the failure output. Exit 0: proceed. Non-zero: `MP=$(n1_autonomy_val 'mechanicalPrompts')`. `MP==auto` + first attempt: spawn developer to fix, re-run once. Else: ask "Fix regression or proceed?"

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; n1_step_end "fix" 10 "success"
```

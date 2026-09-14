<!-- n1:step-snippet-exception: FAIL/PASS branching: separate asked/auto-decided telemetry, PASS-only counter and step_end -->

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"
n1_step_begin "fix" 10; DEVELOPER_MODEL=$(n1_resolve_model developer fix); QE=$(n1_autonomy_val 'qualityEscalations')
```

Run **Ensure Dependencies(`<ID>`)** before spawning.

**FAIL:** spawn developer `$DEVELOPER_MODEL`; pass Critical+High findings, affected files, "Record under `## Fix Cycle <N>` in implementation.md (idempotent). Return: commit SHAs, `Findings fixed: N/M`."

**Security findings** (`[SEC-N]` or security CVE title): append "Fix the entire CLASS — search all variants and fix in one pass."

After developer returns:
```bash
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"
```
Emit: `<ID> · review fix cycle <N>/<MAX>`. Return to Step 7. Bound: `review.maxFixAttempts` (default 3).

**Escalation:** `QE==auto-accept` AND not security/architecture/public-API: take recommended action, append Decision Ledger row `| fix | quality | A | [auto] | <ambiguity> | Accept developer resolution, proceed | Ask, Abort | qualityEscalations=auto-accept | --- |`. Otherwise: resolution ladder (codebase→web→command+default→prior decisions). If all fail:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "fix" "quality" "asked" "codebase|web|command|prior-decisions"
```
**Preamble:** `"{Title}: {Core Ask}."` Bug+root-cause: prepend. Ask: "{PREAMBLE} Ambiguity: [details]. 1. <recommended> (Recommended) 2. <alt> 3. Decide for me"

"Decide for me": web search, apply, then:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "fix" "quality" "auto-decided" "codebase|web|command|prior-decisions"
```

**PASS verdict:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/frontmatter.sh"; n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "clean_passes"
```
`clean_passes < MIN_CLEAN` (default 1) → back to Step 7. `clean_passes >= MIN_CLEAN` → proceed.

**Full-suite regression check** (once at PASS): detect: `package.json scripts.test`, `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod`, `Makefile test`. First match wins; none → "Full-suite check skipped." Found:
```bash
<discovered-test-command> 2>&1; FULL_SUITE_EXIT=$?
```
Append to `## Fix Cycle <N>`: `**Full-suite:** exit <FULL_SUITE_EXIT> — PASS|FAIL`. Exit 0: proceed. Non-zero: `MP=$(n1_autonomy_val 'mechanicalPrompts')`. `MP==auto` + first attempt: spawn developer to fix, re-run once. Else: ask "Fix regression or proceed?"

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; n1_step_end "fix" 10 "success"
```

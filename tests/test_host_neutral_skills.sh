#!/usr/bin/env bash
# Skill and agent text must not hard-code values that helpers own (plugin root, worktree root,
# headless transport, config reads). Tool vocabulary stays host-neutral by convention.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
check() { # <label> <extended-regex>
    local hits
    hits=$(grep -rnE "$2" skills agents 2>/dev/null || true)
    if [ -n "$hits" ]; then echo "FAIL: $1"; echo "$hits" | head -20; FAIL=1; else echo "PASS: $1"; fi
}
check "plugin root literal" '\$\{CLAUDE_PLUGIN_ROOT\}'
check "superpowers: prefix" 'superpowers:'
# NP-192: N1_ROOT is never resolved inline; snippets source the hook-generated ~/.n1/preamble.sh shim.
check "inline N1_ROOT resolution (use: source ~/.n1/preamble.sh)" 'N1_ROOT="\$\{CLAUDE_PLUGIN_ROOT|source "\$N1_ROOT/lib/preamble\.sh"|~/\.n1/root'

# Every fenced bash block that uses $N1_ROOT or the preamble must start with the preamble
# (each snippet is its own fresh shell).
python3 - <<'PY' || FAIL=1
import re, sys, pathlib
PRE = 'source ~/.n1/preamble.sh'
bad = []
for path in list(pathlib.Path("skills").rglob("*.md")) + list(pathlib.Path("agents").glob("*.md")):
    text = path.read_text(encoding="utf-8")
    for m in re.finditer(r"```(?:bash|sh)\n(.*?)```", text, re.S):
        body = m.group(1)
        if ("$N1_ROOT" in body or "preamble.sh" in body) and not body.lstrip().startswith(PRE):
            bad.append(f"{path}:{text[:m.start()].count(chr(10)) + 2}")
if bad:
    print("FAIL: bash snippets using $N1_ROOT/preamble without starting with: " + PRE); print("\n".join(bad)); sys.exit(1)
print("PASS: every $N1_ROOT snippet starts with " + PRE)
PY

check "headless claude -p literal" 'claude -p'
check "worktree directory literal" '\.claude/worktrees'
# N1-224: workspace-manager calls live in lib/host.sh (n1_orca_* helpers); skill text never names the CLI.
check "workspace manager CLI literal (use n1_orca_* helpers)" '(^|[^A-Za-z0-9_])[Oo]rca([^A-Za-z0-9_]|$)|ORCA_CLI_COMMAND'
check "manifest version read through plugin root" 'N1_ROOT/\.claude-plugin/plugin\.json|N1_ROOT>/\.claude-plugin'

# NP-229: json_val is not defined anywhere in lib/; the real helper is n1_config_val.
check "json_val is undefined (use n1_config_val)" '(^|[^a-zA-Z_])json_val([^a-zA-Z_]|$)'

# N1-57: config is read key-by-key via n1_*_val helpers; dumping the whole file put dead keys
# (escalation.checkpoints) in context and the model invented a push/PR confirmation gate.
check "full config.json read (use n1_*_val helpers)" 'cat[[:space:]]+"?\$\{?N1_HOME\}?/config\.json'

# Fork prohibition (moved from test_dispatch_parity.sh, N1-63): the injected routing block and
# the n1-start dispatcher both forbid fork subagents.
if grep -qiE 'never.*fork' hooks/session-start.sh; then echo "PASS: session injection prohibits fork subagents"; else echo "FAIL: session injection prohibits fork subagents"; FAIL=1; fi
if grep -qiE 'never.*fork' skills/n1-start/SKILL.md; then echo "PASS: n1-start dispatcher prohibits fork subagents"; else echo "FAIL: n1-start dispatcher prohibits fork subagents"; FAIL=1; fi

# N1-62: a piped source runs in a subshell and loses N1_HOME; the "not configured" check prints
# N1_NOT_CONFIGURED in the same call as the source, and rules key off that marker.
check "preamble is never piped" 'preamble\.sh[^|;&]*\|[^|]'
check "not-configured rule keyed to \$N1_HOME (use N1_NOT_CONFIGURED)" 'N1_HOME.? (is )?empty'
for s in start ticket story refine queue run review review-response clean release telemetry ci pr finish; do
    # first ```bash fence containing the preamble source must itself print the marker
    if awk '/^```bash/{b="";i=1;next} /^```/{if(i&&b~/source ~\/\.n1\/preamble\.sh/){r=(b~/N1_NOT_CONFIGURED/)?0:1; done=1; exit} i=0} i{b=b $0 "\n"} END{exit done?r:1}' "skills/n1-$s/SKILL.md"; then echo "PASS: n1-$s prints N1_NOT_CONFIGURED"; else echo "FAIL: n1-$s prints N1_NOT_CONFIGURED"; FAIL=1; fi
done
if grep -q 'never pipe the preamble' hooks/session-start.sh; then echo "PASS: session injection forbids piping the preamble"; else echo "FAIL: session injection forbids piping the preamble"; FAIL=1; fi

exit $FAIL

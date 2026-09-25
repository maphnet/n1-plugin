#!/usr/bin/env bash
# tests/test_hooks.sh — behavioral tests for enforce-agent-policy, session-start throttle.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_HOST CODEX_THREAD_ID CODEX_SESSION_ID CLAUDE_CODE_SESSION_ID N1_SESSION_ID
export N1_HOME="$T/home" N1_STATE_DIR="$T/state" N1_HOST_FILE="$T/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
mkdir -p "$N1_HOME"
cat > "$N1_HOME/config.json" <<'EOF'
{"planReview":{"requirePlanApproval":true},"autonomy":{"brainstorm":"auto","acceptanceGate":"auto"}}
EOF

# enforce-agent-policy: no python → systemMessage once
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
for c in bash jq grep sed cat dirname basename printf head tr awk mv rm mkdir date; do p=$(command -v $c) && ln -sf "$p" "$FAKEBIN/$c"; done
INPUT='{"session_id":"s1","tool_name":"Agent","tool_input":{"subagent_type":"n1:developer"}}'
OUT1=$(echo "$INPUT" | PATH="$FAKEBIN" bash "$REPO_ROOT/hooks/enforce-agent-policy.sh")
OUT2=$(echo "$INPUT" | PATH="$FAKEBIN" bash "$REPO_ROOT/hooks/enforce-agent-policy.sh")
assert_eq "warns once when python missing" "N1: agent model enforcement skipped (no Python interpreter)" "$(echo "$OUT1" | jq -r .systemMessage)"
assert_eq "second call silent" "" "$OUT2"

# session-start throttle: last_checked untouched when gh fails
mkdir -p "$T/ghbin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/ghbin/gh"; chmod +x "$T/ghbin/gh"
MEM2="$N1_HOME/memory/T-10"; mkdir -p "$MEM2"
printf -- '---\nstep: pr\nawaiting: merge\npr: 42\ncreated: 2099-01-01T00:00:00Z\nlast_checked: 2026-01-01T00:00:00Z\n---\n' > "$MEM2/overview.md"
echo '{"session_id":"s-throttle","source":"startup"}' | N1_HOST=claude-code PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "last_checked unchanged on gh failure" "last_checked: 2026-01-01T00:00:00Z" "$(grep '^last_checked:' "$MEM2/overview.md")"
printf '#!/usr/bin/env bash\necho MERGED\n' > "$T/ghbin/gh"
echo '{"session_id":"s-throttle","source":"startup"}' | N1_HOST=claude-code PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
[ "$(grep '^last_checked:' "$MEM2/overview.md")" != "last_checked: 2026-01-01T00:00:00Z" ] && { echo "PASS: last_checked advanced on success"; PASS=$((PASS+1)); } || { echo "FAIL: last_checked advanced on success"; FAIL=$((FAIL+1)); }

# --- enforce-agent-policy (both hosts) -------------------------------------
FX="$REPO_ROOT/tests/fixtures/hooks"
cat > "$N1_HOME/config.json" <<'EOF'
{"models":{"developer":{"claude-code":"opus","codex":"gpt-6-astra"}}}
EOF
POLICY="$REPO_ROOT/hooks/enforce-agent-policy.sh"
OUT=$(N1_HOST=claude-code bash "$POLICY" < "$FX/claude/pretooluse-spawn.json")
assert_eq "claude spawn override model" "opus" "$(echo "$OUT" | jq -r .hookSpecificOutput.updatedInput.model)"
OUT=$(N1_HOST=codex bash "$POLICY" < "$FX/codex/pretooluse-spawn.json")
assert_eq "codex resolver-selected model passes through Astra config" "" "$OUT"
case "$OUT" in *gpt-6-astra*) assert_eq "codex hook never injects Astra" absent "$OUT";; *) assert_eq "codex hook never injects Astra" absent absent;; esac
set +e
N1_HOST=claude-code bash "$POLICY" < "$FX/claude/pretooluse-persona-denied.json" 2>"$T/err"; RC=$?
set -e
assert_eq "claude persona denial exit 2" "2" "$RC"
assert_eq "claude persona denial reason" "N1: persona code-reviewer may not use tool Edit (allowed: Glob, Grep, Read)" "$(cat "$T/err")"
set +e
N1_HOST=codex bash "$POLICY" < "$FX/codex/pretooluse-persona-denied.json" 2>"$T/err"; RC=$?
set -e
assert_eq "codex persona denial exit 2" "2" "$RC"
assert_eq "codex apply_patch denied for read-only persona" "N1: persona code-reviewer may not use tool apply_patch (allowed: Glob, Grep, Read)" "$(cat "$T/err")"
OUT=$(N1_HOST=codex bash "$POLICY" < "$FX/codex/pretooluse-persona-allowed.json"); RC=$?
assert_eq "codex exec_command allowed for read-only persona" "0:" "$RC:$OUT"
OUT=$(N1_HOST=claude-code bash "$POLICY" < "$FX/claude/pretooluse-persona-allowed.json"); RC=$?
assert_eq "claude Grep allowed for read-only persona" "0:" "$RC:$OUT"
OUT=$(echo '{"tool_name":"Read","agent_type":"general-purpose","tool_input":{}}' | N1_HOST=claude-code bash "$POLICY"); RC=$?
assert_eq "foreign agent passthrough" "0:" "$RC:$OUT"

# --- enforce-agent-policy Case 3: queue merge gate (NP-212) -----------------
GR="$T/gitrepo"; mkdir -p "$GR"
git -C "$GR" init -q
git -C "$GR" symbolic-ref HEAD refs/heads/main
git -C "$GR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$GR" branch feature
git -C "$GR" worktree add -q "$T/wt" feature
WT="$T/wt"
gate() { # gate <host> <queue-run-id> <cwd> <command> -> exit code of the hook
    local payload rc
    if [ "$1" = codex ]; then
        payload=$(jq -cn --arg c "$4" --arg d "$3" '{session_id:"s",cwd:$d,hook_event_name:"PreToolUse",tool_name:"exec_command",tool_input:{cmd:$c}}')
    else
        payload=$(jq -cn --arg c "$4" --arg d "$3" '{session_id:"s",cwd:$d,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
    fi
    set +e
    printf '%s' "$payload" | N1_HOST="$1" N1_QUEUE_RUN_ID="$2" bash "$POLICY" >/dev/null 2>"$T/gate.err"; rc=$?
    set -e
    echo "$rc"
}
# queue.mergeOnFinish absent + interactive auto-merge on: the exact incident config
echo '{"git":{"defaultBranch":"main"},"finishWork":{"enabled":true,"mergeOnFinish":true}}' > "$N1_HOME/config.json"
assert_eq "queue: gh pr merge denied"               2 "$(gate claude-code RUN1 "$WT" 'gh pr merge 12 --squash')"
case "$(cat "$T/gate.err")" in *"queue.mergeOnFinish is not true"*) assert_eq "queue: deny reason names the key" ok ok;; *) assert_eq "queue: deny reason names the key" ok "$(cat "$T/gate.err")";; esac
assert_eq "queue: chained gh pr merge denied"       2 "$(gate claude-code RUN1 "$WT" 'cd /tmp && gh pr merge 12 --auto --squash --delete-branch')"
assert_eq "queue: unspaced chain denied"            2 "$(gate claude-code RUN1 "$WT" 'true;gh pr merge 12')"
assert_eq "queue: gh api REST merge denied"         2 "$(gate claude-code RUN1 "$WT" 'gh api -X PUT repos/o/r/pulls/12/merge')"
assert_eq "queue: gh api graphql merge denied"      2 "$(gate claude-code RUN1 "$WT" "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'")"
assert_eq "queue: gh api graphql auto-merge denied" 2 "$(gate claude-code RUN1 "$WT" "gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"x\"}){clientMutationId}}'")"
assert_eq "queue: push HEAD:main denied"            2 "$(gate claude-code RUN1 "$WT" 'git push origin HEAD:main')"
assert_eq "queue: bare push on main denied"         2 "$(gate claude-code RUN1 "$GR" 'git push 2>&1')"
assert_eq "queue: git -C main merge denied"         2 "$(gate claude-code RUN1 "$WT" "git -C $GR merge --squash feature")"
assert_eq "queue: cd main && git merge denied"      2 "$(gate claude-code RUN1 "$WT" "cd $GR && git merge --no-ff feature")"
assert_eq "queue: feature push allowed"             0 "$(gate claude-code RUN1 "$WT" 'git push -u origin feature')"
assert_eq "queue: bare push on feature allowed"     0 "$(gate claude-code RUN1 "$WT" 'git push')"
assert_eq "queue: merging main into feature allowed" 0 "$(gate claude-code RUN1 "$WT" 'git merge main')"
assert_eq "queue: merge --abort on main allowed"    0 "$(gate claude-code RUN1 "$GR" 'git merge --abort')"
assert_eq "queue: gh pr view allowed"               0 "$(gate claude-code RUN1 "$WT" 'gh pr view 12 --json state,mergeCommit')"
assert_eq "queue: gh --repo global flag merge denied" 2 "$(gate claude-code RUN1 "$WT" 'gh --repo o/r pr merge 12')"
assert_eq "queue: gh --repo global flag view allowed" 0 "$(gate claude-code RUN1 "$WT" 'gh --repo o/r pr view 12')"
assert_eq "queue: gh -R attached flag merge denied"   2 "$(gate claude-code RUN1 "$WT" 'gh -Rowner/repo pr merge 123')"
assert_eq "queue: gh --repo= attached flag merge denied" 2 "$(gate claude-code RUN1 "$WT" 'gh --repo=owner/repo pr merge 123')"
assert_eq "queue: gh -R attached flag view allowed"   0 "$(gate claude-code RUN1 "$WT" 'gh -Rowner/repo pr view 123')"
assert_eq "codex queue: gh pr merge denied"         2 "$(gate codex RUN1 "$WT" 'gh pr merge 12 --squash')"
assert_eq "codex queue: bash -lc nested merge denied" 2 "$(gate codex RUN1 "$WT" "bash -lc 'cd x; gh pr merge 12'")"
assert_eq "codex queue: push to main denied"        2 "$(gate codex RUN1 "$WT" 'git push origin feature:main')"
assert_eq "interactive: hook does not gate merges"  0 "$(gate claude-code "" "$GR" 'gh pr merge 12 --squash')"
assert_eq "interactive codex: hook does not gate"   0 "$(gate codex "" "$GR" 'git push origin HEAD:main')"
echo '{"queue":{"mergeOnFinish":true}}' > "$N1_HOME/config.json"
assert_eq "queue merge on: gh pr merge allowed"     0 "$(gate claude-code RUN1 "$WT" 'gh pr merge 12 --squash')"
assert_eq "queue merge on: codex push main allowed" 0 "$(gate codex RUN1 "$GR" 'git push origin main')"
echo '{' > "$N1_HOME/config.json"
assert_eq "queue: broken config fails closed"       2 "$(gate claude-code RUN1 "$WT" 'gh pr merge 12')"
echo '{"git":{"defaultBranch":"main"}}' > "$N1_HOME/config.json"
# SEC-1: newline is a command separator, not whitespace -- the ordinary shape of every N1
# skill snippet (source ~/.n1/preamble.sh on its own line, command below).
assert_eq "queue: multi-line command denied"        2 "$(gate claude-code RUN1 "$WT" "$(printf 'source ~/.n1/preamble.sh\ngh pr merge 12')")"
assert_eq "queue: cd-then-newline-merge denied"     2 "$(gate claude-code RUN1 "$WT" "$(printf 'cd /tmp\ngh pr merge 12')")"
# SEC-2: shell keywords and wrapper commands no longer hide gh/git past position 0.
assert_eq "queue: until-wrapped merge denied"       2 "$(gate claude-code RUN1 "$WT" 'until gh pr merge 12 --squash; do sleep 30; done')"
assert_eq "queue: if-wrapped merge denied"          2 "$(gate claude-code RUN1 "$WT" 'if gh pr checks 12; then gh pr merge 12; fi')"
assert_eq "queue: timeout-wrapped merge denied"     2 "$(gate claude-code RUN1 "$WT" 'timeout 60 gh pr merge 12')"
# SEC-13: unparseable commands (shlex ValueError) now deny outright in queue runs instead of
# falling back to a second, regex-based parser over the raw text.
assert_eq "queue: unparseable command denies outright" 2 "$(gate claude-code RUN1 "$WT" "echo 'unterminated")"
# SEC-5: gh -R/--repo attached to the pr command group (between pr and merge), not just before it.
assert_eq "queue: gh pr -R merge denied"            2 "$(gate claude-code RUN1 "$WT" 'gh pr -R o/r merge 12')"
assert_eq "queue: gh pr --repo= merge denied"       2 "$(gate claude-code RUN1 "$WT" 'gh pr --repo=o/r merge 12')"
# CR-8: heredoc bodies are stripped before tokenizing -- prose containing "git push origin main"
# in a heredoc body (with an odd apostrophe count, routine English) must not deny. This is the
# solution-architect's required analysis.md-write pattern.
assert_eq "queue: heredoc body prose allowed" 0 "$(gate claude-code RUN1 "$WT" "$(printf "cat > x.md <<'EOF'\n- Run git push origin main to publish, it's done\nEOF")")"
# CR-8 companion: a real command chained on the heredoc marker line is still checked, and a
# real merge on the line right after the heredoc closes is still checked.
assert_eq "queue: command after heredoc closes denied" 2 "$(gate claude-code RUN1 "$WT" "$(printf "cat > x.md <<'EOF'\nsome body text\nEOF\ngh pr merge 12")")"
# CR-9/SEC-11: a real (non-comment) merge line after a preceding comment with an apostrophe
# must still be denied -- the comment strip must not swallow the merge line via commenters="".
assert_eq "queue: merge after apostrophe comment denied" 2 "$(gate claude-code RUN1 "$WT" "$(printf "# Don't wait for review\ngh pr merge 12 --squash --admin\n# PR's merged")")"
# CR-10: "2>&1" tokenizes as "2", ">&", "1" -- must be handled as a duplication redirect
# (pop the fd, skip the target) before the control-operator check ends the segment early.
assert_eq "queue: push with 2>&1 redirect on default branch denied" 2 "$(gate claude-code RUN1 "$GR" 'git push origin 2>&1')"
# SEC-12: a wrapper token with no -c to recurse into must not stop the scan of the rest of the
# segment -- "sh" here is env's flag value, not the program.
assert_eq "queue: wrapper flag value not mistaken for -c stop" 2 "$(gate claude-code RUN1 "$WT" 'env -u sh gh pr merge 12')"
rm -f "$N1_HOME/config.json"

# --- telemetry hooks accept the Codex persona prefix -----------------------
MEM3="$N1_HOME/memory/T-20/telemetry"; mkdir -p "$MEM3"
mkdir -p "$MEM3/locks"
echo '{"run_id":"n1-run-codex","n1_version":"3.0.0","host":"codex","session_id":"01a094f8"}' > "$MEM3/locks/n1-run-codex.json"
N1_HOST=codex bash "$REPO_ROOT/hooks/telemetry-agent-start.sh" < "$FX/codex/subagent-start.json"
assert_eq "codex agent start recorded" "n1-developer" "$(jq -r .agent_type "$MEM3/raw/agents/n1-run-codex.jsonl")"
env -u N1_HOST bash "$REPO_ROOT/hooks/telemetry-agent-start.sh" < "$FX/codex/subagent-start.json"
assert_eq "identity-less hook does not claim Codex lock" "1" "$(wc -l < "$MEM3/raw/agents/n1-run-codex.jsonl")"
echo '{"run_id":"n1-run-claude","n1_version":"3.0.0","host":"claude-code","session_id":"s-claude-1"}' > "$MEM3/locks/n1-run-claude.json"
N1_HOST=claude-code bash "$REPO_ROOT/hooks/telemetry-agent-start.sh" < "$FX/claude/subagent-start.json"
assert_eq "claude agent start recorded" "n1:developer" "$(jq -r .agent_type "$MEM3/raw/agents/n1-run-claude.jsonl")"

# --- session-start: host.json, routing block, codex TOML generation --------
export N1_HOST_FILE="$T/host.json"
rm -f "$N1_HOST_FILE"; rm -f "$N1_HOME/config.json"
OUT=$(N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
assert_eq "host.json written (claude)" "claude-code" "$(jq -r .host "$N1_HOST_FILE")"
assert_eq "host.json pluginRoot" "$REPO_ROOT" "$(jq -r .pluginRoot "$N1_HOST_FILE")"
TRAMPOLINE="source $N1_STATE_DIR/sessions/\"\${N1_SESSION_ID:-\${CLAUDE_CODE_SESSION_ID:-\${CODEX_THREAD_ID:?N1: no session id in env; restart the session}}}.preamble.sh\""
assert_eq "constant trampoline written next to host.json" "$TRAMPOLINE" "$(cat "$T/preamble.sh" 2>/dev/null)"
assert_eq "per-session preamble written for the payload session id" "N1_ROOT=$REPO_ROOT
source \"\$N1_ROOT/lib/preamble.sh\"" "$(cat "$N1_STATE_DIR/sessions/s-claude-1.preamble.sh" 2>/dev/null)"
case "$CTX" in *"N1 PLUGIN ROOT: $REPO_ROOT"*) assert_eq "unconfigured branch carries plugin root" ok ok;; *) assert_eq "unconfigured branch carries plugin root" ok "$CTX";; esac
case "$CTX" in *"HOST ROUTING (host: claude-code"*"subagent_type"*) assert_eq "claude routing block" ok ok;; *) assert_eq "claude routing block" ok "$CTX";; esac
echo '{"telemetry":{"enabled":false}}' > "$N1_HOME/config.json"
PROJ="$T/proj"; mkdir -p "$PROJ"
PAYLOAD=$(jq -c --arg cwd "$PROJ" '.cwd = $cwd' "$FX/codex/session-start.json")
OUT=$(echo "$PAYLOAD" | N1_HOST=codex CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CODEX_HOME="$T/codexhome" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
assert_eq "host.json written (codex)" "codex" "$(jq -r .host "$N1_HOST_FILE")"
case "$CTX" in *"HOST ROUTING (host: codex"*"spawn_agent schema"*"agent_type only if supported"*) assert_eq "codex routing block" ok ok;; *) assert_eq "codex routing block" ok "$CTX";; esac
assert_eq "codex persona TOMLs generated in cwd" "10" "$(ls "$PROJ/.codex/agents"/n1-*.toml | wc -l | tr -d ' ')"
# compaction restore fires on source=compact
cat > "$N1_HOME/active-run.json" <<'AREOF'
{"ticketId":"T-30","runId":"n1-run-c","worktreePath":null,"branch":"T-30"}
AREOF
mkdir -p "$N1_HOME/memory/T-30"; printf -- '---\nstep: review\ntype: task\n---\n## Context\nctx line\n' > "$N1_HOME/memory/T-30/overview.md"
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact"}' | N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"ORCHESTRATOR STATE"*"Active ticket: T-30"*"Current step: review"*) assert_eq "compaction state restore on source=compact" ok ok;; *) assert_eq "compaction state restore on source=compact" ok "$CTX";; esac
rm -f "$N1_HOME/active-run.json"
# compaction restore reads this session's keyed pointer, not another session's (NP-206)
echo '{"ticketId":"T-31","runId":"n1-run-o","worktreePath":null,"branch":"T-31"}' > "$N1_HOME/active-run.json"
echo '{"ticketId":"T-30","runId":"n1-run-c","worktreePath":null,"branch":"T-30"}' > "$N1_HOME/active-run.s1.json"
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact"}' | N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"Active ticket: T-30"*) assert_eq "compaction restore uses session-keyed active-run" ok ok;; *) assert_eq "compaction restore uses session-keyed active-run" ok "$CTX";; esac
rm -f "$N1_HOME/active-run.json" "$N1_HOME/active-run.s1.json"
# --- session-start: prMode "skip" is a valid value and is not migrated (NP-202) ---
echo '{"telemetry":{"enabled":false},"git":{"prMode":"skip"}}' > "$N1_HOME/config.json"
echo '{"session_id":"s-prmode","source":"startup"}' | N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "session-start keeps prMode skip" "skip" "$(jq -r .git.prMode "$N1_HOME/config.json")"
unset N1_HOST_FILE

# --- session-start: plugin-root preamble shim generation (NP-192) ------------
RL="$T/rootlink"; mkdir -p "$RL"
SP="$N1_STATE_DIR/sessions/s-root.preamble.sh"
echo '{"session_id":"s-root","source":"startup"}' | N1_HOST_FILE="$RL/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim written for first root" "N1_ROOT=$REPO_ROOT" "$(head -1 "$SP" 2>/dev/null)"
TRAMP1=$(cat "$RL/preamble.sh")
OTHER_ROOT="$T/otherroot"; mkdir -p "$OTHER_ROOT/lib"
echo '{"session_id":"s-root","source":"startup"}' | N1_HOST_FILE="$RL/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$OTHER_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim rewritten for a different plugin root" "N1_ROOT=$OTHER_ROOT" "$(head -1 "$SP" 2>/dev/null)"
assert_eq "trampoline byte-identical across roots" "$TRAMP1" "$(cat "$RL/preamble.sh")"
assert_eq "no shim tmp files left behind" "" "$(ls "$RL"/*.tmp "$N1_STATE_DIR/sessions"/*.tmp 2>/dev/null)"
RO="$T/rodir"; mkdir -p "$RO"; chmod 555 "$RO"
RC=0; echo '{"session_id":"s-root","source":"startup"}' | N1_HOST_FILE="$RO/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || RC=$?
chmod 755 "$RO"
assert_eq "hook exits 0 when shim dir is unwritable" "0" "$RC"
CYGDIR="$T/cygbin"; mkdir -p "$CYGDIR"
cat > "$CYGDIR/cygpath" <<'CYGEOF'
#!/usr/bin/env bash
[ "$1" = "-u" ] && echo "/c/fake/root"
CYGEOF
chmod +x "$CYGDIR/cygpath"
echo '{"session_id":"s-root","source":"startup"}' | PATH="$CYGDIR:$PATH" N1_HOST_FILE="$RL/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim uses cygpath-converted POSIX root when cygpath is present" "N1_ROOT=/c/fake/root" "$(head -1 "$SP" 2>/dev/null)"

# --- session-start: shim round-trip for a plugin root with special characters (NP-192/CR-1,TQ-1) ---
SPECIAL_ROOT="$T/it's a \$root dir"; mkdir -p "$SPECIAL_ROOT/lib"
printf '#!/usr/bin/env bash\n# minimal stub — no-op, real N1_ROOT resolution already done by the shim\n' > "$SPECIAL_ROOT/lib/preamble.sh"
SPECIAL_HOST_DIR="$T/specialhost"; mkdir -p "$SPECIAL_HOST_DIR"
echo '{"session_id":"s-special","source":"startup"}' | N1_HOST_FILE="$SPECIAL_HOST_DIR/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
RESOLVED=$(CLAUDE_CODE_SESSION_ID=s-special bash -c "source \"$SPECIAL_HOST_DIR/preamble.sh\"; printf '%s' \"\$N1_ROOT\"" 2>/dev/null)
assert_eq "shim resolves special-character root exactly" "$SPECIAL_ROOT" "$RESOLVED"

# cygpath exits 0 with empty output must leave the shim containing the original root (CR-1)
EMPTYCYG="$T/emptycygbin"; mkdir -p "$EMPTYCYG"
cat > "$EMPTYCYG/cygpath" <<'CYGEOF2'
#!/usr/bin/env bash
exit 0
CYGEOF2
chmod +x "$EMPTYCYG/cygpath"
echo '{"session_id":"s-root","source":"startup"}' | PATH="$EMPTYCYG:$PATH" N1_HOST_FILE="$RL/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim falls back to original root when cygpath outputs nothing" "N1_ROOT=$REPO_ROOT" "$(head -1 "$SP" 2>/dev/null)"

# --- session-start: concurrent sessions keep their own root and host (NP-204) ---
# A (claude-code, root R1) starts, B (codex, root R2) starts, A compacts: each still resolves its own.
CS="$T/concurrent"; mkdir -p "$CS"; R2="$T/root2"; mkdir -p "$R2/lib"
printf 'N1_R2_MARK=1\n' > "$R2/lib/preamble.sh"
resolve() { # <env assignments...> — source the trampoline like a snippet would
    env "$@" bash -c "source \"$CS/preamble.sh\" && printf '%s' \"\$N1_ROOT\"" 2>/dev/null
}
echo '{"session_id":"s-a","source":"startup"}' | N1_HOST_FILE="$CS/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
echo '{"session_id":"s-b","source":"startup"}' | N1_HOST_FILE="$CS/host.json" N1_HOST=codex CODEX_THREAD_ID=s-b CLAUDE_PLUGIN_ROOT="$R2" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "session A resolves its own root after B started" "$REPO_ROOT" "$(resolve CLAUDE_CODE_SESSION_ID=s-a)"
assert_eq "session B (codex) resolves its own root" "$R2" "$(resolve CODEX_THREAD_ID=s-b)"
echo '{"session_id":"s-a","source":"compact"}' | N1_HOST_FILE="$CS/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "session B unaffected by A's compact" "$R2" "$(resolve CODEX_THREAD_ID=s-b)"
assert_eq "explicit N1_SESSION_ID wins over the harness id" "$R2" "$(resolve N1_SESSION_ID=s-b CLAUDE_CODE_SESSION_ID=s-a)"
assert_eq "session B host recorded per session" "codex" "$(jq -r .host "$N1_STATE_DIR/sessions/s-b.json")"
assert_eq "session A host recorded per session" "claude-code" "$(jq -r .host "$N1_STATE_DIR/sessions/s-a.json")"
RC=0; ERR=$(bash -c "source \"$CS/preamble.sh\"" 2>&1) || RC=$?
assert_eq "no session id in env fails loudly" "127" "$RC"
case "$ERR" in *"N1: no session id"*) assert_eq "no-session-id message" ok ok;; *) assert_eq "no-session-id message" ok "$ERR";; esac
RC=0; bash -c "CLAUDE_CODE_SESSION_ID=s-nope source \"$CS/preamble.sh\"" 2>/dev/null || RC=$?
assert_eq "unknown session id fails instead of using another root" "1" "$RC"
# stale session files are pruned after 7 days; fresh ones survive
touch -d '10 days ago' "$N1_STATE_DIR/sessions/s-old.json" "$N1_STATE_DIR/sessions/s-old.preamble.sh"
echo '{"session_id":"s-a","source":"resume"}' | N1_HOST_FILE="$CS/host.json" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "stale session files pruned" "" "$(ls "$N1_STATE_DIR/sessions"/s-old.* 2>/dev/null)"
assert_eq "fresh session files kept" "2" "$(ls "$N1_STATE_DIR/sessions"/s-b.* 2>/dev/null | wc -l | tr -d ' ')"

# --- session-start: TRACKER ROUTING includes versionMcp when configured ----
export N1_HOST_FILE="$T/host2.json"
cat > "$N1_HOME/config.json" <<'EOF'
{"tracker":{"type":"jira","mcp":"plugin_atlassian_atlassian","versionMcp":"publius-jc-mcp","operations":{"getJiraIssue":"getIssue"}}}
EOF
OUT=$(N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"publius-jc-mcp"*) assert_eq "versionMcp appears in TRACKER ROUTING" ok ok;; *) assert_eq "versionMcp appears in TRACKER ROUTING" ok "$CTX";; esac
case "$CTX" in *"mcp__publius-jc-mcp__"*) assert_eq "versionMcp prefix in TRACKER ROUTING" ok ok;; *) assert_eq "versionMcp prefix in TRACKER ROUTING" ok "$CTX";; esac
# without versionMcp the old NEVER directive is still present
cat > "$N1_HOME/config.json" <<'EOF'
{"tracker":{"type":"jira","mcp":"plugin_atlassian_atlassian","operations":{"getJiraIssue":"getIssue"}}}
EOF
OUT=$(N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"NEVER use any other MCP server"*) assert_eq "no versionMcp keeps NEVER directive" ok ok;; *) assert_eq "no versionMcp keeps NEVER directive" ok "$CTX";; esac
export N1_HOST_FILE="$T/host.json"

# --- session-stop: writes abandon envelope_close when lock exists ----------
STOP_TICK="T-STOP"
STOP_MEM="$N1_HOME/memory/$STOP_TICK"
STOP_TELEM="$STOP_MEM/telemetry"
mkdir -p "$STOP_TELEM/raw/steps" "$STOP_TELEM/runs"
mkdir -p "$STOP_TELEM/locks"
echo '{"run_id":"run-stop-test","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop"}' > "$STOP_TELEM/locks/run-stop-test.json"
echo '{"run_id":"run-stop-test","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop"}' > "$STOP_TELEM/telemetry.lock"
printf -- '---\ntype: task\ntier: standard\nstep: implementation\n---\n' > "$STOP_MEM/overview.md"
echo '{"session_id":"s-stop","transcript_path":"/tmp/stop.jsonl"}' | N1_HOST=claude-code N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
STOP_LINE=$(grep '"envelope_close"' "$STOP_TELEM/raw/steps/run-stop-test.jsonl" 2>/dev/null | tail -1)
assert_eq "stop hook writes envelope_close" "envelope_close" "$(echo "$STOP_LINE" | jq -r .layer 2>/dev/null)"
assert_eq "stop hook final_outcome abandoned" "abandoned" "$(echo "$STOP_LINE" | jq -r .final_outcome 2>/dev/null)"
assert_eq "stop hook type from overview" "task" "$(echo "$STOP_LINE" | jq -r .type 2>/dev/null)"
assert_eq "stop hook tier from overview" "standard" "$(echo "$STOP_LINE" | jq -r .estimated_tier 2>/dev/null)"
assert_eq "stop hook removes lock after merge" "false" "$([ -f "$STOP_TELEM/telemetry.lock" ] && echo true || echo false)"

# session-stop: no lock -> silent exit, no crash
NO_LOCK_MEM="$N1_HOME/memory/T-NOLOCK"
mkdir -p "$NO_LOCK_MEM"
echo '{"session_id":"s-no-lock"}' | N1_HOST=claude-code N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null
assert_eq "stop hook no lock exits clean" "0" "$?"

# --- session-start: queue digest line (NP-194) --------------------------------
QD="$N1_HOME/queue/hq"; mkdir -p "$QD"; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","queue":"hq","run_id":"R1","event":"ticket_finished","ticket":"T-1","outcome":"pr","pr":"","session":"","duration_s":5,"reason":""}\n{"ts":"%s","queue":"hq","run_id":"R1","event":"escalated","ticket":"T-2","outcome":"","pr":"","session":"","duration_s":null,"reason":""}\n' "$NOW" "$NOW" > "$QD/events.jsonl"
OUT=$(N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
assert_eq "session-start: queue digest line" "1" \
    "$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext | grep -c '^N1 QUEUE STATUS: Queue hq: 1 PR, 1 needs you (T-2)$' || true)"
printf 'garbage\n' > "$QD/events.jsonl"
OUT=$(N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
assert_eq "session-start: corrupt events -> no digest, valid JSON" "0" \
    "$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext | grep -c 'N1 QUEUE STATUS' || true)"
rm -rf "$N1_HOME/queue"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]

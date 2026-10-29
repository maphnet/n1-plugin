#!/usr/bin/env bash
# tests/test_hooks.sh — behavioral tests for enforce-agent-policy, session-start throttle.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID N1_TRANSCRIPT_PATH N1_PARENT_SESSION_ID N1_SESSION_ID CLAUDE_CODE_SESSION_ID
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
assert_eq "warns once when python missing" "N1: agent policy (model enforcement, merge deny and pipe-mask check) skipped -- no Python interpreter" "$(echo "$OUT1" | jq -r .systemMessage)"
assert_eq "second call silent" "" "$OUT2"

# session-start throttle: last_checked untouched when gh fails
mkdir -p "$T/ghbin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/ghbin/gh"; chmod +x "$T/ghbin/gh"
MEM2="$N1_HOME/memory/T-10"; mkdir -p "$MEM2"
printf -- '---\nstep: pr\nawaiting: merge\npr: 42\ncreated: 2099-01-01T00:00:00Z\nlast_checked: 2026-01-01T00:00:00Z\n---\n' > "$MEM2/overview.md"
echo '{"session_id":"s-throttle","source":"startup"}' | PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "last_checked unchanged on gh failure" "last_checked: 2026-01-01T00:00:00Z" "$(grep '^last_checked:' "$MEM2/overview.md")"
printf '#!/usr/bin/env bash\necho MERGED\n' > "$T/ghbin/gh"
echo '{"session_id":"s-throttle","source":"startup"}' | PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
[ "$(grep '^last_checked:' "$MEM2/overview.md")" != "last_checked: 2026-01-01T00:00:00Z" ] && { echo "PASS: last_checked advanced on success"; PASS=$((PASS+1)); } || { echo "FAIL: last_checked advanced on success"; FAIL=$((FAIL+1)); }

# session-start: archived <ID>-old memory is excluded from the pending-merge scan (NP-235)
MEMOLD="$N1_HOME/memory/T-12-old"; mkdir -p "$MEMOLD"
printf -- '---\nstep: pr\nawaiting: merge\npr: 43\ncreated: 2099-01-01T00:00:00Z\nlast_checked: 2026-01-01T00:00:00Z\n---\n' > "$MEMOLD/overview.md"
echo '{"session_id":"s-archived","source":"startup"}' | PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "archived -old memory skipped by pending-merge scan" "last_checked: 2026-01-01T00:00:00Z" "$(grep '^last_checked:' "$MEMOLD/overview.md")"
rm -rf "$MEMOLD"

# session-start: awaiting-merge overview with missing created/pr/last_checked fields must not crash the hook (NP-232)
MEM3="$N1_HOME/memory/T-11"; mkdir -p "$MEM3"
printf -- '---\nstep: pr\nawaiting: merge\n---\n' > "$MEM3/overview.md"
set +e
OUT3=$(echo '{"session_id":"s-missing-fields","source":"startup"}' | PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" 2>"$T/err3")
RC3=$?
set -e
assert_eq "hook exits 0 with missing pending-merge fields" "0" "$RC3"
CTX3=$(echo "$OUT3" | jq -e -r '.hookSpecificOutput.additionalContext' 2>/dev/null) || CTX3=""
assert_eq "additionalContext non-empty with missing fields" "present" "$([ -n "$CTX3" ] && echo present || echo missing)"
case "$CTX3" in *"never use subagent_type"*) assert_eq "fork prohibition text present" present present;; *) assert_eq "fork prohibition text present" present missing;; esac
case "$CTX3" in *"COMMIT ATTRIBUTION"*) assert_eq "commit attribution text present" present present;; *) assert_eq "commit attribution text present" present missing;; esac
rm -rf "$MEM3"

# --- enforce-agent-policy ---------------------------------------------------
FX="$REPO_ROOT/tests/fixtures/hooks"
cat > "$N1_HOME/config.json" <<'EOF'
{"models":{"developer":{"claude-code":"opus"}}}
EOF
POLICY="$REPO_ROOT/hooks/enforce-agent-policy.sh"
OUT=$(bash "$POLICY" < "$FX/claude/pretooluse-spawn.json")
assert_eq "claude spawn override model" "opus" "$(echo "$OUT" | jq -r .hookSpecificOutput.updatedInput.model)"
set +e
bash "$POLICY" < "$FX/claude/pretooluse-persona-denied.json" 2>"$T/err"; RC=$?
set -e
assert_eq "claude persona denial exit 2" "2" "$RC"
assert_eq "claude persona denial reason" "N1: persona code-reviewer may not use tool Edit (allowed: Glob, Grep, Read, Write)" "$(cat "$T/err")"
OUT=$(bash "$POLICY" < "$FX/claude/pretooluse-persona-allowed.json"); RC=$?
assert_eq "claude Grep allowed for read-only persona" "0:" "$RC:$OUT"
OUT=$(echo '{"tool_name":"Read","agent_type":"general-purpose","tool_input":{}}' | bash "$POLICY"); RC=$?
assert_eq "foreign agent passthrough" "0:" "$RC:$OUT"

# reviewer Write is scoped to memory/<ID>/review-(cr|sec).md under the N1 home (SEC-1)
mkdir -p "$N1_HOME/memory/T-9" "$N1_HOME/memory/T-8" "$T/wt"; ln -sf "$T/wt/f.txt" "$N1_HOME/memory/T-9/review-sec.md"
echo '{"ticketId":"T-8"}' > "$N1_HOME/active-run.s-rev.json"
rev_write_rc() {  # rev_write_rc <persona> <tool> <file_path>
    local rc=0; jq -cn --arg a "n1:$1" --arg t "$2" --arg f "$3" '{agent_type:$a,tool_name:$t,session_id:"s-rev",tool_input:{file_path:$f}}' | bash "$POLICY" >/dev/null 2>&1 || rc=$?; echo "$rc"
}
for P in code-reviewer security-reviewer; do
    OWN=cr; OTHER=sec; [ "$P" = security-reviewer ] && { OWN=sec; OTHER=cr; }
    assert_eq "$P Write to own review-$OWN.md allowed" 0 "$(rev_write_rc $P Write "$N1_HOME/memory/T-8/review-$OWN.md")"
    assert_eq "$P Write to other persona review-$OTHER.md denied" 2 "$(rev_write_rc $P Write "$N1_HOME/memory/T-8/review-$OTHER.md")"
    assert_eq "$P Write to another ticket's review-$OWN.md denied" 2 "$(rev_write_rc $P Write "$N1_HOME/memory/T-9/review-$OWN.md")"
    assert_eq "$P Write to ~/.n1/preamble.sh denied" 2 "$(rev_write_rc $P Write "$HOME/.n1/preamble.sh")"
    assert_eq "$P Write to worktree file denied" 2 "$(rev_write_rc $P Write "$T/wt/f.txt")"
    assert_eq "$P Write to other memory file denied" 2 "$(rev_write_rc $P Write "$N1_HOME/memory/T-9/config.json")"
    assert_eq "$P Write via review-sec.md symlink denied" 2 "$(rev_write_rc $P Write "$N1_HOME/memory/T-9/review-sec.md")"
    assert_eq "$P Write via .. traversal denied" 2 "$(rev_write_rc $P Write "$N1_HOME/memory/T-9/../../config.json")"
    assert_eq "$P Write without file_path denied" 2 "$(rev_write_rc $P Write "")"
    assert_eq "$P Edit still denied" 2 "$(rev_write_rc $P Edit "$N1_HOME/memory/T-9/review-cr.md")"
    assert_eq "$P NotebookEdit still denied" 2 "$(rev_write_rc $P NotebookEdit "$N1_HOME/memory/T-9/review-cr.md")"
done
# production root ~/.n1/<slug> with N1_HOME unset (TQ-2); config-dir root (CR-7)
rev_write_env_rc() {  # rev_write_env_rc <cwd> <file_path> <env...>
    local cwd=$1 f=$2; shift 2; local rc=0
    jq -cn --arg c "$cwd" --arg f "$f" '{agent_type:"n1:code-reviewer",tool_name:"Write",session_id:"s-rev",cwd:$c,tool_input:{file_path:$f}}' | env "$@" bash "$POLICY" >/dev/null 2>&1 || rc=$?; echo "$rc"
}
mkdir -p "$T/h/.n1/slug/memory/T-9" "$T/alt/memory/T-9" "$T/h/.n1/other/memory/T-9"
echo '{"ticketId":"T-9"}' > "$T/h/.n1/slug/active-run.s-rev.json"; echo '{"ticketId":"T-9"}' > "$T/alt/active-run.s-rev.json"
mkdir -p "$T/slug"; git -C "$T/slug" init -q
assert_eq "N1_HOME unset: ~/.n1/<slug> review-cr.md allowed" 0 "$(cd "$T/slug" && rev_write_env_rc "$T" "$T/h/.n1/slug/memory/T-9/review-cr.md" -u N1_HOME HOME="$T/h")"
assert_eq "N1_HOME unset: ~/.n1/preamble.sh denied" 2 "$(rev_write_env_rc "$T" "$T/h/.n1/preamble.sh" -u N1_HOME HOME="$T/h")"
py_write_rc() {  # py_write_rc <config_file_arg> <cwd> <file_path>: call the hook script directly
    local rc=0; jq -cn --arg c "$2" --arg f "$3" '{agent_type:"n1:code-reviewer",tool_name:"Write",session_id:"s-rev",cwd:$c,tool_input:{file_path:$f}}' | env -u N1_HOME HOME="$T/h" python3 "$REPO_ROOT/hooks/enforce-agent-policy.py" "$1" "$REPO_ROOT" >/dev/null 2>&1 || rc=$?; echo "$rc"
}
assert_eq "another slug's memory dir denied" 2 "$(py_write_rc "$T/h/.n1/slug/config.json" "$T" "$T/h/.n1/other/memory/T-9/review-cr.md")"
rm -f "$T/alt/active-run.s-rev.json"
assert_eq "missing active-run file denied" 2 "$(py_write_rc "$T/alt/config.json" "$T" "$T/alt/memory/T-9/review-cr.md")"
echo '{"ticketId":"../x"}' > "$T/alt/active-run.s-rev.json"
assert_eq "invalid ticketId denied" 2 "$(py_write_rc "$T/alt/config.json" "$T" "$T/alt/memory/T-9/review-cr.md")"
echo '{"ticketId":"T-9"}' > "$T/alt/active-run.s-rev.json"
assert_eq "config-dir root allowed (absolute)" 0 "$(py_write_rc "$T/alt/config.json" "$T" "$T/alt/memory/T-9/review-cr.md")"
assert_eq "config-dir root allowed (relative, payload cwd)" 0 "$(py_write_rc "alt/config.json" "$T" "$T/alt/memory/T-9/review-cr.md")"
assert_eq "config-dir root: non-findings file denied" 2 "$(py_write_rc "$T/alt/config.json" "$T" "$T/alt/config.json")"
assert_eq "no config file: alt dir denied" 2 "$(py_write_rc "" "$T" "$T/alt/memory/T-9/review-cr.md")"
assert_eq "developer Write unscoped" 0 "$(rev_write_rc developer Write "$T/wt/f.txt")"
# live-captured reviewer Write payload (N1-137): the real CC field set still scopes the Write
RW="$FX/claude/pretooluse-reviewer-write.json"
fx_write_rc() {  # fx_write_rc <file_path> [jq-filter]: captured payload with file_path (and optionally more) overridden
    local rc=0; jq -c --arg f "$1" ".tool_input.file_path=\$f | ${2:-.}" "$RW" | bash "$POLICY" >/dev/null 2>&1 || rc=$?; echo "$rc"
}
assert_eq "captured payload: in-scope review-cr.md allowed" 0 "$(fx_write_rc "$N1_HOME/memory/T-8/review-cr.md")"
assert_eq "captured payload: off-scope Write denied" 2 "$(fx_write_rc "$N1_HOME/memory/T-8/off-scope.md")"
assert_eq "captured payload: unknown session_id denied" 2 "$(fx_write_rc "$N1_HOME/memory/T-8/review-cr.md" '.session_id="s-none"')"
assert_eq "captured payload: other persona denied review-cr.md" 2 "$(fx_write_rc "$N1_HOME/memory/T-8/review-cr.md" '.agent_type="n1:security-reviewer"')"

# N1-174 (N1-135): a reviewer Write the hook cannot evaluate (no Python, script crash, malformed payload) is denied
# in every session; other payloads keep their old outcome and the no-Python warning text is unchanged
raw_rc() {  # raw_rc <payload> [env-assignments...]: raw stdin through the wrapper; stdout -> $T/raw-out, stderr -> $T/raw-err
    local p=$1; shift; local rc=0
    printf '%s' "$p" | env "$@" bash "$POLICY" >"$T/raw-out" 2>"$T/raw-err" || rc=$?; echo "$rc"
}
pyraw_rc() {  # pyraw_rc <payload>: raw stdin straight into the hook script
    local rc=0; printf '%s' "$1" | python3 "$REPO_ROOT/hooks/enforce-agent-policy.py" "" "$REPO_ROOT" >/dev/null 2>&1 || rc=$?; echo "$rc"
}
DENY_MSG="N1: reviewer Write denied -- the agent policy hook could not evaluate it (no Python interpreter or hook error)"
NOPY_WARN="N1: agent policy (model enforcement, merge deny and pipe-mask check) skipped -- no Python interpreter"
for P in code-reviewer security-reviewer; do
    PAYLOAD=$(jq -c --arg a "n1:$P" --arg s "s-nopy-$P" '.agent_type=$a | .session_id=$s' "$RW")
    assert_eq "no python: $P Write denied" 2 "$(raw_rc "$PAYLOAD" PATH="$FAKEBIN")"
    assert_eq "no python: $P Write denial names the cause" 1 "$(grep -cxF "$DENY_MSG" "$T/raw-err" || true)"
    assert_eq "no python: $P Write leaves no warn-once marker" absent "$([ -e "$N1_HOME/.enforce-warned-s-nopy-$P" ] && echo present || echo absent)"
done
DEVW=$(jq -c '.agent_type="n1:developer" | .session_id="s-nopy-dev"' "$RW")
assert_eq "no python: developer Write allowed" 0 "$(raw_rc "$DEVW" PATH="$FAKEBIN")"
assert_eq "no python: developer Write keeps the warning" "$NOPY_WARN" "$(jq -r .systemMessage "$T/raw-out")"
SPAWN='{"session_id":"s-nopy-spawn","tool_name":"Agent","tool_input":{"subagent_type":"n1:code-reviewer","agent_type":"n1:code-reviewer"}}'
assert_eq "no python: reviewer spawn (tool_input.agent_type) allowed" 0 "$(raw_rc "$SPAWN" PATH="$FAKEBIN")"
NULW=$(jq -c --arg f "$N1_HOME/memory/T-8/review-cr.md" '.tool_input.file_path=($f+"\u0000x")' "$RW")
assert_eq "python crash (NUL in file_path): reviewer Write denied" 2 "$(raw_rc "$NULW")"
assert_eq "python crash: denial names the cause" 1 "$(grep -cxF "$DENY_MSG" "$T/raw-err" || true)"
assert_eq "malformed JSON: code-reviewer Write denied" 2 "$(raw_rc '{"agent_type":"n1:code-reviewer","tool_name":"Write","tool_input":{"file_path":')"
assert_eq "malformed JSON: security-reviewer Write (spaced) denied" 2 "$(raw_rc '{"agent_type": "n1:security-reviewer", "tool_name": "Write", ')"
assert_eq "malformed JSON: reviewer Read allowed" 0 "$(raw_rc '{"agent_type":"n1:code-reviewer","tool_name":"Read",')"
assert_eq "malformed JSON: developer Write allowed" 0 "$(raw_rc '{"agent_type":"n1:developer","tool_name":"Write",')"
assert_eq "malformed JSON: escaped reviewer text in a value allowed" 0 \
    "$(raw_rc '{"agent_type":"n1:developer","tool_name":"Write","tool_input":{"content":"\"agent_type\":\"n1:code-reviewer\"",')"
assert_eq "py: malformed JSON exits 3" 3 "$(pyraw_rc '{"agent_type":')"
assert_eq "py: non-object JSON exits 3" 3 "$(pyraw_rc '[]')"
# N1-174 SEC-1: stdin is parsed as bytes, so a non-ASCII payload under a C locale is not mistaken for malformed JSON
NA=$(jq -c --arg f "$N1_HOME/memory/T-8/review-cr.md" '.tool_input.file_path=$f | .tool_input.content="caf\u00e9 \u2713"' "$RW")
assert_eq "C locale: non-ASCII reviewer Write to its findings path allowed" 0 "$(raw_rc "$NA" LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 PYTHONIOENCODING=ascii)"
# N1-174 SEC-2: the findings-path scope applies even when the persona file yields no tool list (missing persona file)
pyroot_rc() {  # pyroot_rc <file_path>: reviewer Write straight into the hook with a plugin root that has no agents dir
    local rc=0; jq -cn --arg c "$T" --arg f "$1" '{agent_type:"n1:code-reviewer",tool_name:"Write",session_id:"s-rev",cwd:$c,tool_input:{file_path:$f}}' | env -u N1_HOME HOME="$T/h" python3 "$REPO_ROOT/hooks/enforce-agent-policy.py" "$T/alt/config.json" "$T/noroot" >/dev/null 2>"$T/root-err" || rc=$?; echo "$rc"
}
assert_eq "missing persona file: reviewer Write outside findings path denied" 2 "$(pyroot_rc "$T/alt/config.json")"
assert_eq "missing persona file: reviewer Write to findings path allowed" 0 "$(pyroot_rc "$T/alt/memory/T-9/review-cr.md")"

# --- enforce-agent-policy: merge deny (N1-146; N1-167: only unattended sessions and active N1 runs, unless n1_merge_authorized) ---
policy_rc() {  # policy_rc <env-assignments...> -- <command>; prints the hook exit code
    local envs=() cmd
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done; cmd=$2
    local p; p=$(jq -cn --arg c "$cmd" --arg cwd "$T" '{session_id:"s",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
    local rc=0; printf '%s' "$p" | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS "${envs[@]}" bash "$POLICY" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
Q=(N1_QUEUE_RUN_ID=RUN1 N1_HEADLESS=1)
# N1-167: interactive sessions are gated only inside an N1 run (session "s" keyed active-run file)
ar_on() { echo '{"ticketId":"N1-1"}' > "$N1_HOME/active-run.s.json"; }
ar_off() { rm -f "$N1_HOME/active-run.s.json"; }
ar_on
DENY_CMDS=(
    "gh pr merge 12" "gh pr merge --auto --squash 12" "gh -R x/y pr merge 12" "gh pr -R x/y merge 12"
    "g''h pr m''erge 12" "/usr/bin/gh pr merge 12" "cd /tmp && gh pr merge 12" "echo \$(gh pr merge 12)"
    "gh api graphql -f query='mutation { mergePullRequest(input:{}) { clientMutationId } }'"
    "gh api graphql -F query=@- <<< 'mutation { enablePullRequestAutoMerge(input:{}) { x } }'"
    "gh api -X PUT repos/o/r/pulls/12/merge"
    "git push origin main" "git push origin HEAD:main" "git push origin HEAD:refs/heads/main"
    "git -C dir push origin main" "git push -u origin +main" "git push --all origin" "git push origin feature:main"
    "gh.exe pr merge 1" "git --config-env k=V push origin main" "env A=1 timeout 5 gh pr merge 1"
    "bash -c 'gh pr merge 1'" "echo 1 | xargs gh pr merge" "(gh pr merge 1)"
    "gh api -X POST repos/o/r/merges -f base=main -f head=x" "curl -X PUT https://api.github.com/repos/o/r/pulls/1/merge"
    "gh api graphql -f query='mutation { enqueuePullRequest(input:{}) { x } }'"
    "gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=x"
    "git push --mir origin" "git push --al origin" "git push --branches origin" "git push origin 'refs/heads/*:refs/heads/*'"
    "git push origin :" "git push origin \$(git rev-parse HEAD):main" "git push origin HEAD@{0}:main" "gh -R {owner}/{repo} pr merge 1"
    "git push --repo=origin HEAD:main" "git push --repo origin HEAD:main" "git push --repo=origin main"
    ">/tmp/merge.log gh pr merge 12" "> /tmp/m gh pr merge 12" "2>/tmp/e gh pr merge 12" ">>/tmp/m gh pr merge 12"
    "</dev/null gh pr merge 12" "&>/tmp/m gh pr merge 12" "2>&1 gh pr merge 12" ">\$HOME/m git push origin main"
    "echo x >/tmp/f; >/tmp/m gh pr merge 1" "echo >\$(gh pr merge 1)"
    "env --chdir=/tmp/nice -u FOO gh pr merge 1" "env -C/tmp/nice -u FOO git push origin main" "sudo --chdir=/x/env -u x gh pr merge 1"
    "env -u FOO git push origin main" "env --unset FOO git push origin main" "env --unse FOO git push origin main"
    "env --u FOO git push origin main" "env -C /x git push origin main" "env --chdir /x gh pr merge 1"
    "env -u FOO FOO2=1 git push origin main" "env -iu FOO git push origin main" "env -a x gh pr merge 1"
    "env -u git gh pr merge 1" "env -S 'git push origin main'" "env --unset=FOO git push origin main" "env -i git push origin main"
    "sudo -u x gh pr merge 1" "sudo -g x gh pr merge 1" "sudo --user x gh pr merge 1" "sudo -nu x gh pr merge 1"
    "sudo -u x -g y gh pr merge 1" "sudo -ux gh pr merge 1" "doas -u x gh pr merge 1" "sudo env -u FOO git push origin main"
    "timeout -s KILL 5 gh pr merge 1" "timeout --signal KILL -k 5 10 gh pr merge 1"
    "xargs -I X gh pr merge X" "xargs -n 1 gh pr merge" "xargs -d x gh pr merge" "exec -a n gh pr merge 1"
    "bash -o pipefail -c 'gh pr merge 1'" "bash --rcfile f -c 'gh pr merge 1'"
    "nice -n 5 gh pr merge 1" "nice -5 gh pr merge 1" "ionice -c idle gh pr merge 1" "stdbuf -o L gh pr merge 1"
    "setsid gh pr merge 1" "chroot /r gh pr merge 1" "chroot --userspec x:y /r gh pr merge 1"
    "sudo -au git push origin main" "sudo -cu gh pr merge 1" "sudo -a x gh pr merge 1" "sudo --login-class x gh pr merge 1"
    "bash -oc pipefail 'gh pr merge 1'" "bash -Oc extglob 'gh pr merge 1'" "bash -oO a b -c 'gh pr merge 1'" "sh +o posix -c 'gh pr merge 1'"
    "chroot /srv/gh git push origin main" "chroot /x/git gh pr merge 1"
    "/usr/bin/time -o t gh pr merge 1" "time --format x gh pr merge 1" "xargs --process-slot-var V gh pr merge 1"
    "xargs -I {} gh pr merge {}" "xargs --eof gh pr merge 1" "xargs --max-lines gh pr merge 1" "xargs -iI git push origin main"
    "sudo --login gh pr merge 1" "sudo --login git push origin main" "sudo --list --login-c x gh pr merge 1"
    "doas -au git push origin main" "chroot +r git push origin main" "chroot -- -r git push origin main"
    "sudo -Zu git push origin main" "env -u git push origin main" "sh --rcfile f -c 'gh pr merge 1'"
    "sudo --login -u x gh pr merge 1" "doas -a x git push origin main" "chroot +r env -u x git push origin main"
    "chroot -- -r env -u x git push origin main"
    "env -u gh -R git pr merge 1"
)
for c in "${DENY_CMDS[@]}"; do
    assert_eq "queue headless: denied: $c" 2 "$(policy_rc "${Q[@]}" -- "$c")"
    assert_eq "interactive: denied: $c" 2 "$(policy_rc -- "$c")"
done
for c in "git merge-base HEAD origin/main" "git merge origin/main" "git push origin maphskiy/feature" \
         "git push -u origin HEAD" "gh pr view 12" "gh pr create --title 'merge main into x'" "gh api repos/o/r/pulls/12" \
         'grep -rn "gh pr merge" skills/' 'git commit -m "Drop gh pr merge from finish"' \
         'git commit -m "document git push origin main"' "git push gh feature" "grep -rn mergePullRequest lib/" \
         "git push origin \$(git branch --show-current)" "git push origin refs/heads/main-x:refs/heads/main-x" \
         "git push --repo=origin feature" "git push --repo origin HEAD:feature" "echo x >/tmp/f" \
         "echo x 2>&1 >/tmp/f" ">/tmp/f echo gh pr merge" "gh pr view 1 >/tmp/f 2>&1" \
         "env -u FOO git status" "env -u FOO git push origin feature" "sudo -u x gh pr view 1" \
         "env --chdir=/tmp/nice -u FOO gh pr view 1" \
         "sudo -nu x git push origin feature" "timeout -s KILL 5 gh pr view 1" "nice -n 5 gh pr view 1" \
         "xargs -I X echo gh pr merge X" "sudo -u x echo gh pr merge 1" "env -u FOO" "env -S 'git status'" \
         "bash -o pipefail -c 'git status'" "chroot --userspec x:y /r git status" \
         "sudo --login git status" "sudo -u git git push origin feature" "doas -au git status" \
         "chroot +r git status" "chroot -- -r gh pr view 1" "sudo -Zu git status"; do
    assert_eq "queue headless: allowed: $c" 0 "$(policy_rc "${Q[@]}" -- "$c")"
    assert_eq "interactive: allowed: $c" 0 "$(policy_rc -- "$c")"
done
# CR-11: no working Python -> queue-child Bash fails closed; other payloads stay fail-open
mkdir -p "$T/nopy"; printf '#!/bin/sh\nexit 1\n' > "$T/nopy/python3"; cp "$T/nopy/python3" "$T/nopy/python"; chmod +x "$T/nopy/"*
assert_eq "no python: queue headless Bash denied" 2 "$(PATH="$T/nopy:$PATH" policy_rc "${Q[@]}" -- "gh pr view 1")"
assert_eq "no python: non-queue Bash allowed" 0 "$(PATH="$T/nopy:$PATH" policy_rc -- "gh pr view 1")"
assert_eq "no python: interactive merge fails open (warned)" 0 "$(PATH="$T/nopy:$PATH" policy_rc -- "gh pr merge 1")"
rm -rf "$T/nopy"
# N1-146: {mergeOnFinish, fullAuto} x {interactive, queue headless}; only JSON true counts
cfg() { printf '%s\n' "$1" > "$N1_HOME/config.json"; }
MOF='{"finishWork":{"mergeOnFinish":true}}'
FA='{"autonomy":{"fullAuto":true}}'
BOTH='{"finishWork":{"mergeOnFinish":true},"autonomy":{"fullAuto":true}}'
for c in "gh pr merge 12" "git push origin main" "gh api -X PUT repos/o/r/pulls/12/merge"; do
    cfg '{}'
    assert_eq "neither key: interactive denied: $c" 2 "$(policy_rc -- "$c")"
    assert_eq "neither key: queue denied: $c" 2 "$(policy_rc "${Q[@]}" -- "$c")"
    cfg "$FA"
    assert_eq "fullAuto only: interactive denied: $c" 2 "$(policy_rc -- "$c")"
    assert_eq "fullAuto only: queue denied: $c" 2 "$(policy_rc "${Q[@]}" -- "$c")"
    cfg "$MOF"
    assert_eq "mergeOnFinish only: interactive allowed: $c" 0 "$(policy_rc -- "$c")"
    assert_eq "mergeOnFinish only: queue denied: $c" 2 "$(policy_rc "${Q[@]}" -- "$c")"
    assert_eq "mergeOnFinish only: headless (no queue) denied: $c" 2 "$(policy_rc N1_HEADLESS=1 -- "$c")"
    assert_eq "mergeOnFinish only: queue id (not headless) denied: $c" 2 "$(policy_rc N1_QUEUE_RUN_ID=RUN1 -- "$c")"
    cfg "$BOTH"
    assert_eq "both keys: interactive allowed: $c" 0 "$(policy_rc -- "$c")"
    assert_eq "both keys: queue allowed: $c" 0 "$(policy_rc "${Q[@]}" -- "$c")"
    cfg '{"finishWork":{"mergeOnFinish":"true"},"autonomy":{"fullAuto":true}}'
    assert_eq "string mergeOnFinish: interactive denied: $c" 2 "$(policy_rc -- "$c")"
done
# N1-159: a test runner piped into tail/head/grep and && chained into git commit hides the suite status
PIPE_DENY=("evidence-N1-74|bash tests/run.sh 2>&1 | tail -2 && git add -A && git commit -m x"
           "evidence-N1-75|bash tests/test_manifests.sh | tail -2 && git add -A && git commit -m x"
           "pytest-env-wrapper|FOO=1 timeout 5 pytest -q | head -3 && git commit -m x"
           "git-C-grep|pytest | grep -c FAIL && git -C d commit -m x"
           "npm-test|npm test | tail -2 && git commit -m x"
           "go-test|go test ./... | tail && git commit -m x"
           "make-test|make test | tail && git commit -m x"
           "py-pytest|python -m pytest | tail && git commit -m x"
           "pipefail-late|bash tests/run.sh | tail -2 && git commit -m x; set -o pipefail"
           "and-newline|bash tests/run.sh | tail -2 &&
git commit -m x"
           "pipe-amp|bash tests/run.sh |& tail -2 && git commit -m x"
           "pipefail-in-message|bash tests/run.sh | tail -2 && git commit -m 'add pipefail guard'")
PIPE_OK=("pipefail-set|set -o pipefail; bash tests/run.sh 2>&1 | tail -2 && git commit -m x"
         "pipefail-split|set -e -o pipefail; bash tests/run.sh | tail -2 && git commit -m x"
         "pipefail-euo-split|set -eu -o pipefail; bash tests/run.sh | tail -2 && git commit -m x"
         "pipefail-errexit|set -o errexit -o pipefail; bash tests/run.sh | tail -2 && git commit -m x"
         "newline-sep|bash tests/run.sh | tail -2"$'\n'"git commit -m x"
         "pipefail-euo|set -euo pipefail; bash tests/run.sh | tail -2 && git commit -m x"
         "pipestatus|bash tests/run.sh | tail -2 && git commit -m x; echo \${PIPESTATUS[0]}"
         "no-commit|bash tests/run.sh | tail -5" "quoted-text|git commit -m 'pytest | tail -2 done'"
         "no-chain|pytest | grep -c FAIL" "commit-first|git commit -m x && bash tests/run.sh | tail -2"
         "or-chain|bash tests/run.sh | head -3 || git commit -m x"
         "semicolon|bash tests/run.sh | tail -2; git commit -m x"
         "non-runner|git log | head -3 && git commit -m x")
for e in "${PIPE_DENY[@]}"; do
    cfg '{}'
    assert_eq "pipe-mask deny ${e%%|*}" 2 "$(policy_rc -- "${e#*|}")"
    case "$e" in evidence*) cfg "$BOTH"; assert_eq "pipe-mask deny merge-authorized ${e%%|*}" 2 "$(policy_rc -- "${e#*|}")" ;; esac
done
for e in "${PIPE_OK[@]}"; do
    cfg '{}'
    assert_eq "pipe-mask allow ${e%%|*}" 0 "$(policy_rc -- "${e#*|}")"
done
# SEC-1/CR-3: long pathological word must stay linear
LONG="bash $(printf 'tests/%.0s' $(seq 1 20000))x | tail -2 && git commit -m x"
cfg '{}'; START=$SECONDS
assert_eq "pipe-mask long word allowed" 0 "$(policy_rc -- "$LONG")"
assert_eq "pipe-mask long word fast" 1 "$(( SECONDS - START < 5 ))"
cfg "$BOTH"; assert_eq "pipe-mask gh pr merge allowed when authorized" 0 "$(policy_rc -- "gh pr merge 12")"
# CR-2 (N1-146): no Python + authorized queue child -> persona Bash allowed (no-Python deny applies only when merges are not authorized)
mkdir -p "$T/nopy"; printf '#!/bin/sh\nexit 1\n' > "$T/nopy/python3"; cp "$T/nopy/python3" "$T/nopy/python"; chmod +x "$T/nopy/"*
PP=$(jq -cn --arg cwd "$T" '{session_id:"s",cwd:$cwd,agent_type:"n1:developer",tool_name:"Bash",tool_input:{command:"gh pr view 1"}}')
nopy_rc() { local rc=0; printf '%s' "$PP" | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS "${Q[@]}" PATH="$T/nopy:$PATH" bash "$POLICY" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
cfg "$BOTH"; assert_eq "no python: authorized queue persona Bash allowed" 0 "$(nopy_rc)"
cfg '{}'; assert_eq "no python: unauthorized queue persona Bash denied" 2 "$(nopy_rc)"
rm -rf "$T/nopy"
# N1-195: wrapper errors before Python (failing config.sh source, n1_config_file, n1_plugin_root, unreadable stdin)
# deny a reviewer Write and queue-child Bash via the EXIT trap; other calls keep the error code (non-blocking)
mk_tree() {  # mk_tree <name> <config.sh body; empty = missing>: wrapper copy whose ../lib/config.sh is stubbed
    mkdir -p "$T/x-$1/hooks" "$T/x-$1/lib"; cp "$POLICY" "$T/x-$1/hooks/"
    [ -z "$2" ] || printf '%s\n' "$2" > "$T/x-$1/lib/config.sh"
}
mk_tree missing ""
mk_tree fails "return 1"
mk_tree cfgfile "source \"$REPO_ROOT/lib/config.sh\"; n1_config_file() { return 1; }"
mk_tree pluginroot "source \"$REPO_ROOT/lib/config.sh\"; n1_plugin_root() { return 1; }"
xrc() {  # xrc <tree> <payload> [env...]: payload through the stubbed wrapper copy; stderr -> $T/x-err
    local w="$T/x-$1/hooks/enforce-agent-policy.sh" p=$2; shift 2; local rc=0
    printf '%s' "$p" | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS "$@" bash "$w" >/dev/null 2>"$T/x-err" || rc=$?; echo "$rc"
}
QB=$(jq -cn --arg cwd "$T" '{session_id:"s",cwd:$cwd,tool_name:"Bash",tool_input:{command:"gh pr view 1"}}')
RWC=$(jq -c . "$RW")
DW=$(jq -c '.agent_type="n1:developer"' "$RW")
for t in missing fails cfgfile pluginroot; do
    assert_eq "pre-python error ($t): queue-child Bash denied" 2 "$(xrc "$t" "$QB" "${Q[@]}")"
    assert_eq "pre-python error ($t): reviewer Write denied" 2 "$(xrc "$t" "$RWC")"
    assert_eq "pre-python error ($t): reviewer Write denial names the cause" 1 "$(grep -cxF "$DENY_MSG" "$T/x-err" || true)"
    assert_eq "pre-python error ($t): ordinary Bash keeps the error code" 1 "$(xrc "$t" "$QB")"
    assert_eq "pre-python error ($t): developer Write keeps the error code" 1 "$(xrc "$t" "$DW")"
done
rm -rf "$T"/x-*
# Unreadable stdin (a directory: cat fails with EISDIR): the tool is unknown, so a queue child is denied for any call
stdin_dir_rc() { local rc=0; env -u N1_QUEUE_RUN_ID -u N1_HEADLESS "$@" bash "$POLICY" <"$T" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
assert_eq "unreadable stdin: queue child denied" 2 "$(stdin_dir_rc "${Q[@]}")"
assert_eq "unreadable stdin: ordinary session keeps the error code" 1 "$(stdin_dir_rc)"
# Python crash (interpreter probe passes, script exits 1 or 137): queue-child Bash denied unless merge-authorized (CR-2)
mkdir -p "$T/crashpy"
printf '#!/bin/sh\n[ "$1" = -c ] && { cat; echo; exit 0; }\nexit "${CRASH_RC:-1}"\n' > "$T/crashpy/python3"
cp "$T/crashpy/python3" "$T/crashpy/python"; chmod +x "$T/crashpy/"*
for r in 1 137; do
    cfg '{}'
    assert_eq "python crash rc $r: queue-child Bash denied" 2 "$(policy_rc "${Q[@]}" PATH="$T/crashpy:$PATH" CRASH_RC=$r -- "gh pr view 1")"
    assert_eq "python crash rc $r: ordinary Bash allowed" 0 "$(policy_rc PATH="$T/crashpy:$PATH" CRASH_RC=$r -- "gh pr view 1")"
    cfg "$BOTH"
    assert_eq "python crash rc $r: authorized queue-child Bash allowed" 0 "$(policy_rc "${Q[@]}" PATH="$T/crashpy:$PATH" CRASH_RC=$r -- "gh pr view 1")"
done
cfg '{}'
assert_eq "python crash: queue-child developer Write allowed" 0 "$(raw_rc "$DW" "${Q[@]}" PATH="$T/crashpy:$PATH")"
assert_eq "python crash: reviewer Write denied" 2 "$(raw_rc "$RWC" PATH="$T/crashpy:$PATH")"
rm -rf "$T/crashpy"
# Missing or invalid config must deny, never authorize (the shell predicate is false, so Python decides with config {})
c="gh pr merge 12"
rm -f "$N1_HOME/config.json"
assert_eq "no config file: interactive denied" 2 "$(policy_rc -- "$c")"
assert_eq "no config file: queue denied" 2 "$(policy_rc "${Q[@]}" -- "$c")"
cfg '{bad'
assert_eq "invalid config: interactive denied" 2 "$(policy_rc -- "$c")"
assert_eq "invalid config: queue denied" 2 "$(policy_rc "${Q[@]}" -- "$c")"
# The Python mirror decides on its own (the .sh fast exit is skipped when called directly)
PAY=$(jq -cn --arg cwd "$T" '{session_id:"s",cwd:$cwd,tool_name:"Bash",tool_input:{command:"gh pr merge 12"}}')
py_rc() { local rc=0; printf '%s' "$PAY" | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS "$@" python3 "$REPO_ROOT/hooks/enforce-agent-policy.py" "$N1_HOME/config.json" "$REPO_ROOT" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
cfg "$BOTH"; assert_eq "py: both keys, queue allowed" 0 "$(py_rc "${Q[@]}")"
cfg "$MOF";  assert_eq "py: mergeOnFinish only, queue denied" 2 "$(py_rc "${Q[@]}")"
cfg "$MOF";  assert_eq "py: mergeOnFinish only, interactive allowed" 0 "$(py_rc)"
cfg '{"finishWork":{"mergeOnFinish":1}}'; assert_eq "py: number mergeOnFinish, interactive denied" 2 "$(py_rc)"
rm -f "$N1_HOME/config.json"
# bare push while the cwd is on the default branch (config git.defaultBranch honored)
echo '{"git":{"defaultBranch":"trunk"}}' > "$N1_HOME/config.json"
git -C "$T" init -q -b trunk 2>/dev/null || { git -C "$T" init -q; git -C "$T" symbolic-ref HEAD refs/heads/trunk; }
assert_eq "queue headless: bare push on default branch denied" 2 "$(policy_rc "${Q[@]}" -- "git push")"
assert_eq "queue headless: push to configured default denied" 2 "$(policy_rc "${Q[@]}" -- "git push origin trunk")"
assert_eq "queue headless: push main allowed when default is trunk" 0 "$(policy_rc "${Q[@]}" -- "git push origin main")"
git -C "$T" symbolic-ref HEAD refs/heads/feature
assert_eq "queue headless: bare push on feature branch allowed" 0 "$(policy_rc "${Q[@]}" -- "git push")"
rm -rf "$T/.git"
rm -f "$N1_HOME/config.json"

# N1-167 AC1: plain session (no active-run file, not unattended) is not gated
ar_off
for c in "gh pr merge 12" "git push origin HEAD:main" "gh api -X PUT repos/o/r/pulls/12/merge"; do
    assert_eq "plain session: allowed: $c" 0 "$(policy_rc -- "$c")"
    # AC3: unattended behaviour unchanged without an active-run file
    assert_eq "plain session: queue headless still denied: $c" 2 "$(policy_rc "${Q[@]}" -- "$c")"
    assert_eq "plain session: headless (no queue) still denied: $c" 2 "$(policy_rc N1_HEADLESS=1 -- "$c")"
    assert_eq "plain session: queue id (not headless) still denied: $c" 2 "$(policy_rc N1_QUEUE_RUN_ID=RUN1 -- "$c")"
done
# Repo without N1 config or home: plain (Python called directly, no N1_HOME, no config path)
NOHOME_RC=$(rc=0; printf '%s' "$PAY" | env -u N1_HOME -u N1_QUEUE_RUN_ID -u N1_HEADLESS python3 "$REPO_ROOT/hooks/enforce-agent-policy.py" "" "$REPO_ROOT" >/dev/null 2>&1 || rc=$?; echo "$rc")
assert_eq "py: no N1 home, no config: allowed" 0 "$NOHOME_RC"
# Only this session's valid keyed file counts; anything else reads as plain (allowed)
ar_on; cfg '{}'
sid_rc() {  # sid_rc <jq filter>: hook exit code for "gh pr merge 12" with a modified payload
    local rc=0
    jq -cn --arg cwd "$T" '{session_id:"s",cwd:$cwd,tool_name:"Bash",tool_input:{command:"gh pr merge 12"}}' | jq -c "$1" \
        | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS bash "$POLICY" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
assert_eq "active run file, own session: denied" 2 "$(sid_rc '.')"
assert_eq "active run file, missing session_id: allowed" 0 "$(sid_rc 'del(.session_id)')"
assert_eq "active run file, unsafe session_id: allowed" 0 "$(sid_rc '.session_id="../s"')"
assert_eq "other session's active run: allowed" 0 "$(sid_rc '.session_id="s-other"')"
echo '{"ticketId":"../x"}' > "$N1_HOME/active-run.s.json"
assert_eq "active run with invalid ticketId: still denied (SEC-3)" 2 "$(sid_rc '.')"
: > "$N1_HOME/active-run.s.json"
assert_eq "empty active-run file: still denied (SEC-3)" 2 "$(sid_rc '.')"
# run pointer under another ~/.n1/<slug>/ than the cwd/config home (SEC-2); HOME is a temp dir
ar_off; mkdir -p "$T/fakehome/.n1/other"
echo '{"ticketId":"N1-1"}' > "$T/fakehome/.n1/other/active-run.s.json"
assert_eq "pointer under other ~/.n1 slug: denied" 2 "$(policy_rc HOME="$T/fakehome" -- "gh pr merge 12")"
assert_eq "no pointer anywhere (temp HOME): allowed" 0 "$(policy_rc HOME="$T/emptyhome" -- "gh pr merge 12")"
rm -rf "$T/fakehome"
ar_on
# AC2: active run + git.directPush lifts default-branch pushes only, interactive only
cfg '{"git":{"directPush":true}}'
for c in "git push origin HEAD:main" "git push origin main" "git push -u origin main" "git push --follow-tags origin main" \
         "git push --dry-run origin main" "git push -o ci.skip origin main" "git push --no-verify origin main"; do
    assert_eq "active run + directPush: push allowed: $c" 0 "$(policy_rc -- "$c")"
    assert_eq "directPush ignored for queue headless: $c" 2 "$(policy_rc "${Q[@]}" -- "$c")"
    assert_eq "directPush ignored for headless (no queue): $c" 2 "$(policy_rc N1_HEADLESS=1 -- "$c")"
done
for c in "git push --all origin" "git push --mirror origin" "git push --mir origin" "git push origin '*'" "git push origin :" \
         "git push -f origin main" "git push --force origin main" "git push --force-with-lease origin main" "git push --force-if-includes origin main" \
         "git push --for origin main" "git push origin +main" "git push origin +HEAD:main" "git push -d origin main" "git push --delete origin main" \
         "git push origin :main" "git push -fu origin main" \
         "git -c remote.origin.mirror=true push origin main" "git -c remote.origin.push=+HEAD:main push origin main" "git -c REMOTE.origin.PUSH=x push origin main" \
         "git --config-env=remote.origin.push=V push origin main" "GIT_CONFIG_COUNT=1 git push origin main" "GIT_CONFIG_PARAMETERS=x git push origin main" \
         "env GIT_CONFIG_KEY_0=remote.o.push git push origin main" "git push --prune origin main" "git push --pr origin main"; do
    assert_eq "active run + directPush: destructive push still denied: $c" 2 "$(policy_rc -- "$c")"
done
# Codex High: bare push follows repo remote.*.push|mirror config; explicit refspecs ignore it
git -C "$T" init -q -b main 2>/dev/null; git -C "$T" symbolic-ref HEAD refs/heads/main
assert_eq "directPush: bare push, no push config: allowed" 0 "$(policy_rc -- "git push origin")"
git -C "$T" config remote.origin.mirror true
assert_eq "directPush: bare push, remote.origin.mirror: denied" 2 "$(policy_rc -- "git push origin")"
assert_eq "directPush: explicit refspec ignores mirror config: allowed" 0 "$(policy_rc -- "git push origin main")"
git -C "$T" config --unset remote.origin.mirror
git -C "$T" config remote.origin.push '+HEAD:main'
assert_eq "directPush: bare push, remote.origin.push: denied" 2 "$(policy_rc -- "git push origin")"
assert_eq "directPush: explicit refspec ignores push config: allowed" 0 "$(policy_rc -- "git push origin main")"
rm -rf "$T/.git"
for c in "gh pr merge 12" "gh api -X PUT repos/o/r/pulls/12/merge" "gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=x" \
         "git push origin main && gh pr merge 12" "gh pr merge 12; git push origin main"; do
    assert_eq "active run + directPush: merge still denied: $c" 2 "$(policy_rc -- "$c")"
done
ar_off
assert_eq "directPush, no active run: queue headless still denied" 2 "$(policy_rc "${Q[@]}" -- "git push origin HEAD:main")"
ar_on
cfg '{"git":{"directPush":"true"}}'
assert_eq "string directPush: active run push denied" 2 "$(policy_rc -- "git push origin HEAD:main")"
# AC4: denial names the ! escape and asks for a separate command
cfg '{}'
MP=$(jq -cn --arg cwd "$T" '{session_id:"s",cwd:$cwd,tool_name:"Bash",tool_input:{command:"git push origin HEAD:main"}}')
printf '%s' "$MP" | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS bash "$POLICY" >/dev/null 2>"$T/merge-err" || true
assert_eq "deny message names the ! escape" yes "$(grep -qF 'prefixed with !' "$T/merge-err" && echo yes || echo no)"
assert_eq "deny message asks for its own command" yes "$(grep -qF 'as its own command' "$T/merge-err" && echo yes || echo no)"
ar_off
rm -f "$N1_HOME/config.json" "$T/merge-err"

# --- telemetry hooks accept the Claude Code persona prefix -----------------
MEM3="$N1_HOME/memory/T-20/telemetry"; mkdir -p "$MEM3"
mkdir -p "$MEM3/locks"
echo '{"run_id":"n1-run-claude","n1_version":"3.0.0","host":"claude-code","session_id":"s-claude-1"}' > "$MEM3/locks/n1-run-claude.json"
bash "$REPO_ROOT/hooks/telemetry-agent-start.sh" < "$FX/claude/subagent-start.json"
assert_eq "claude agent start recorded" "n1:developer" "$(jq -r .agent_type "$MEM3/raw/agents/n1-run-claude.jsonl")"

# --- session-start: host.json, routing block ------------------------------
export N1_HOST_FILE="$T/host.json"
rm -f "$N1_HOST_FILE"; rm -f "$N1_HOME/config.json"
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
assert_eq "host.json written (claude)" "claude-code" "$(jq -r .host "$N1_HOST_FILE")"
assert_eq "host.json pluginRoot" "$REPO_ROOT" "$(jq -r .pluginRoot "$N1_HOST_FILE")"
TRAMPOLINE="source $N1_STATE_DIR/sessions/\"\${N1_SESSION_ID:-\${CLAUDE_CODE_SESSION_ID:?N1: no session id in env; restart the session}}.preamble.sh\""
assert_eq "constant trampoline written next to host.json" "$TRAMPOLINE" "$(cat "$T/preamble.sh" 2>/dev/null)"
assert_eq "per-session preamble written for the payload session id" "N1_ROOT=$REPO_ROOT
source \"\$N1_ROOT/lib/preamble.sh\"" "$(cat "$N1_STATE_DIR/sessions/s-claude-1.preamble.sh" 2>/dev/null)"
case "$CTX" in *"N1 PLUGIN ROOT: $REPO_ROOT"*) assert_eq "unconfigured branch carries plugin root" ok ok;; *) assert_eq "unconfigured branch carries plugin root" ok "$CTX";; esac
case "$CTX" in *"HOST ROUTING (authoritative for how N1 skills reach Claude Code)"*"subagent_type"*) assert_eq "claude routing block" ok ok;; *) assert_eq "claude routing block" ok "$CTX";; esac
echo '{}' > "$N1_HOME/config.json"
PROJ="$T/proj"; mkdir -p "$PROJ"
PAYLOAD=$(jq -c --arg cwd "$PROJ" '.cwd = $cwd' "$FX/claude/session-start.json")
OUT=$(echo "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
assert_eq "host.json written (claude, configured)" "claude-code" "$(jq -r .host "$N1_HOST_FILE")"
case "$CTX" in *"HOST ROUTING (authoritative for how N1 skills reach Claude Code)"*"subagent_type"*) assert_eq "claude routing block (configured)" ok ok;; *) assert_eq "claude routing block (configured)" ok "$CTX";; esac
case "$CTX" in *"that is their explicit request to commit, push the feature branch, and create the PR"*"does not authorize merge, release, or pushing the default branch"*) assert_eq "session context pre-authorizes push/PR (N1-57)" ok ok;; *) assert_eq "session context pre-authorizes push/PR (N1-57)" ok "$CTX";; esac
# compaction restore fires on source=compact
cat > "$N1_HOME/active-run.json" <<'AREOF'
{"ticketId":"T-30","runId":"n1-run-c","worktreePath":null,"branch":"T-30"}
AREOF
mkdir -p "$N1_HOME/memory/T-30"; printf -- '---\nstep: review\ntype: task\n---\n## Context\nctx line\n' > "$N1_HOME/memory/T-30/overview.md"
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"ORCHESTRATOR STATE"*"Active ticket: T-30"*"Current step: review"*) assert_eq "compaction state restore on source=compact" ok ok;; *) assert_eq "compaction state restore on source=compact" ok "$CTX";; esac
case "$CTX" in *"n1_*_val helpers, never cat config.json"*) assert_eq "compact hint points at n1_*_val helpers (N1-57)" ok ok;; *) assert_eq "compact hint points at n1_*_val helpers (N1-57)" ok "$CTX";; esac
# N1-124: subagent compaction (agent_id present) must not get orchestrator state; scope note precedes header otherwise
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact","agent_id":"sub-1"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"ORCHESTRATOR STATE"*) assert_eq "no compaction restore when agent_id present (N1-124)" ok "$CTX";; *) assert_eq "no compaction restore when agent_id present (N1-124)" ok ok;; esac
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"orchestrator session only"*"ORCHESTRATOR STATE"*) assert_eq "scope note precedes ORCHESTRATOR STATE header (N1-124)" ok ok;; *) assert_eq "scope note precedes ORCHESTRATOR STATE header (N1-124)" ok "$CTX";; esac
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact","agent_type":"some-agent"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"Active ticket: T-30"*) assert_eq "agent_type alone still restores (N1-124)" ok ok;; *) assert_eq "agent_type alone still restores (N1-124)" ok "$CTX";; esac
rm -f "$N1_HOME/active-run.json"
# compaction restore reads this session's keyed pointer, not another session's (NP-206)
echo '{"ticketId":"T-31","runId":"n1-run-o","worktreePath":null,"branch":"T-31"}' > "$N1_HOME/active-run.json"
echo '{"ticketId":"T-30","runId":"n1-run-c","worktreePath":null,"branch":"T-30"}' > "$N1_HOME/active-run.s1.json"
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"Active ticket: T-30"*) assert_eq "compaction restore uses session-keyed active-run" ok ok;; *) assert_eq "compaction restore uses session-keyed active-run" ok "$CTX";; esac
rm -f "$N1_HOME/active-run.json" "$N1_HOME/active-run.s1.json"
# --- session-start: prMode "skip" is a valid value and is not migrated (NP-202) ---
echo '{"git":{"prMode":"skip"}}' > "$N1_HOME/config.json"
echo '{"session_id":"s-prmode","source":"startup"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "session-start keeps prMode skip" "skip" "$(jq -r .git.prMode "$N1_HOME/config.json")"
unset N1_HOST_FILE

# --- session-start: plugin-root preamble shim generation (NP-192) ------------
RL="$T/rootlink"; mkdir -p "$RL"
SP="$N1_STATE_DIR/sessions/s-root.preamble.sh"
echo '{"session_id":"s-root","source":"startup"}' | N1_HOST_FILE="$RL/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim written for first root" "N1_ROOT=$REPO_ROOT" "$(head -1 "$SP" 2>/dev/null)"
TRAMP1=$(cat "$RL/preamble.sh")
OTHER_ROOT="$T/otherroot"; mkdir -p "$OTHER_ROOT/lib"
echo '{"session_id":"s-root","source":"startup"}' | N1_HOST_FILE="$RL/host.json" CLAUDE_PLUGIN_ROOT="$OTHER_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim rewritten for a different plugin root" "N1_ROOT=$OTHER_ROOT" "$(head -1 "$SP" 2>/dev/null)"
assert_eq "trampoline byte-identical across roots" "$TRAMP1" "$(cat "$RL/preamble.sh")"
assert_eq "no shim tmp files left behind" "" "$(ls "$RL"/*.tmp "$N1_STATE_DIR/sessions"/*.tmp 2>/dev/null)"
RO="$T/rodir"; mkdir -p "$RO"; chmod 555 "$RO"
RC=0; echo '{"session_id":"s-root","source":"startup"}' | N1_HOST_FILE="$RO/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || RC=$?
chmod 755 "$RO"
assert_eq "hook exits 0 when shim dir is unwritable" "0" "$RC"
CYGDIR="$T/cygbin"; mkdir -p "$CYGDIR"
cat > "$CYGDIR/cygpath" <<'CYGEOF'
#!/usr/bin/env bash
[ "$1" = "-u" ] && echo "/c/fake/root"
CYGEOF
chmod +x "$CYGDIR/cygpath"
echo '{"session_id":"s-root","source":"startup"}' | PATH="$CYGDIR:$PATH" N1_HOST_FILE="$RL/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim uses cygpath-converted POSIX root when cygpath is present" "N1_ROOT=/c/fake/root" "$(head -1 "$SP" 2>/dev/null)"

# --- session-start: shim round-trip for a plugin root with special characters (NP-192/CR-1,TQ-1) ---
SPECIAL_ROOT="$T/it's a \$root dir"; mkdir -p "$SPECIAL_ROOT/lib"
printf '#!/usr/bin/env bash\n# minimal stub — no-op, real N1_ROOT resolution already done by the shim\n' > "$SPECIAL_ROOT/lib/preamble.sh"
SPECIAL_HOST_DIR="$T/specialhost"; mkdir -p "$SPECIAL_HOST_DIR"
echo '{"session_id":"s-special","source":"startup"}' | N1_HOST_FILE="$SPECIAL_HOST_DIR/host.json" CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
RESOLVED=$(CLAUDE_CODE_SESSION_ID=s-special bash -c "source \"$SPECIAL_HOST_DIR/preamble.sh\"; printf '%s' \"\$N1_ROOT\"" 2>/dev/null)
assert_eq "shim resolves special-character root exactly" "$SPECIAL_ROOT" "$RESOLVED"

# cygpath exits 0 with empty output must leave the shim containing the original root (CR-1)
EMPTYCYG="$T/emptycygbin"; mkdir -p "$EMPTYCYG"
cat > "$EMPTYCYG/cygpath" <<'CYGEOF2'
#!/usr/bin/env bash
exit 0
CYGEOF2
chmod +x "$EMPTYCYG/cygpath"
echo '{"session_id":"s-root","source":"startup"}' | PATH="$EMPTYCYG:$PATH" N1_HOST_FILE="$RL/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "shim falls back to original root when cygpath outputs nothing" "N1_ROOT=$REPO_ROOT" "$(head -1 "$SP" 2>/dev/null)"

# --- session-start: concurrent sessions keep their own root and host (NP-204) ---
# A (root R1) starts, B (root R2) starts, A compacts: each still resolves its own.
CS="$T/concurrent"; mkdir -p "$CS"; R2="$T/root2"; mkdir -p "$R2/lib"
printf 'N1_R2_MARK=1\n' > "$R2/lib/preamble.sh"
resolve() { # <env assignments...> — source the trampoline like a snippet would
    env "$@" bash -c "source \"$CS/preamble.sh\" && printf '%s' \"\$N1_ROOT\"" 2>/dev/null
}
echo '{"session_id":"s-a","source":"startup"}' | N1_HOST_FILE="$CS/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
echo '{"session_id":"s-b","source":"startup"}' | N1_HOST_FILE="$CS/host.json" CLAUDE_PLUGIN_ROOT="$R2" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "session A resolves its own root after B started" "$REPO_ROOT" "$(resolve CLAUDE_CODE_SESSION_ID=s-a)"
assert_eq "session B resolves its own root" "$R2" "$(resolve CLAUDE_CODE_SESSION_ID=s-b)"
echo '{"session_id":"s-a","source":"compact"}' | N1_HOST_FILE="$CS/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "session B unaffected by A's compact" "$R2" "$(resolve CLAUDE_CODE_SESSION_ID=s-b)"
assert_eq "explicit N1_SESSION_ID wins over the harness id" "$R2" "$(resolve N1_SESSION_ID=s-b CLAUDE_CODE_SESSION_ID=s-a)"
assert_eq "session B host recorded per session" "claude-code" "$(jq -r .host "$N1_STATE_DIR/sessions/s-b.json")"
assert_eq "session A host recorded per session" "claude-code" "$(jq -r .host "$N1_STATE_DIR/sessions/s-a.json")"
RC=0; ERR=$(bash -c "source \"$CS/preamble.sh\"" 2>&1) || RC=$?
assert_eq "no session id in env fails loudly" "127" "$RC"
case "$ERR" in *"N1: no session id"*) assert_eq "no-session-id message" ok ok;; *) assert_eq "no-session-id message" ok "$ERR";; esac
RC=0; bash -c "CLAUDE_CODE_SESSION_ID=s-nope source \"$CS/preamble.sh\"" 2>/dev/null || RC=$?
assert_eq "unknown session id fails instead of using another root" "1" "$RC"
# stale session files are pruned after 7 days; fresh ones survive
touch -d '10 days ago' "$N1_STATE_DIR/sessions/s-old.json" "$N1_STATE_DIR/sessions/s-old.preamble.sh"
echo '{"session_id":"s-a","source":"resume"}' | N1_HOST_FILE="$CS/host.json" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "stale session files pruned" "" "$(ls "$N1_STATE_DIR/sessions"/s-old.* 2>/dev/null)"
assert_eq "fresh session files kept" "2" "$(ls "$N1_STATE_DIR/sessions"/s-b.* 2>/dev/null | wc -l | tr -d ' ')"

# --- session-start: TRACKER ROUTING includes versionMcp when configured ----
export N1_HOST_FILE="$T/host2.json"
cat > "$N1_HOME/config.json" <<'EOF'
{"tracker":{"type":"jira","mcp":"plugin_atlassian_atlassian","versionMcp":"publius-jc-mcp","operations":{"getJiraIssue":"getIssue"}}}
EOF
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"publius-jc-mcp"*) assert_eq "versionMcp appears in TRACKER ROUTING" ok ok;; *) assert_eq "versionMcp appears in TRACKER ROUTING" ok "$CTX";; esac
case "$CTX" in *"mcp__publius-jc-mcp__"*) assert_eq "versionMcp prefix in TRACKER ROUTING" ok ok;; *) assert_eq "versionMcp prefix in TRACKER ROUTING" ok "$CTX";; esac
# without versionMcp the old NEVER directive is still present
cat > "$N1_HOME/config.json" <<'EOF'
{"tracker":{"type":"jira","mcp":"plugin_atlassian_atlassian","operations":{"getJiraIssue":"getIssue"}}}
EOF
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
CTX=$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext)
case "$CTX" in *"NEVER use any other MCP server"*) assert_eq "no versionMcp keeps NEVER directive" ok ok;; *) assert_eq "no versionMcp keeps NEVER directive" ok "$CTX";; esac
export N1_HOST_FILE="$T/host.json"

# --- session-stop: active matching pointer retains the selected run ----------
STOP_TICK="T-STOP"
STOP_MEM="$N1_HOME/memory/$STOP_TICK"
STOP_TELEM="$STOP_MEM/telemetry"
mkdir -p "$STOP_TELEM/raw/steps" "$STOP_TELEM/runs"
mkdir -p "$STOP_TELEM/locks"
echo '{"run_id":"run-stop-test","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop"}' > "$STOP_TELEM/locks/run-stop-test.json"
echo '{"run_id":"run-stop-test","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop"}' > "$STOP_TELEM/telemetry.lock"
printf -- '---\ntype: task\ntier: standard\nstep: done\n---\n' > "$STOP_MEM/overview.md"
echo '{"ticketId":"T-STOP","runId":"run-stop-test"}' > "$N1_HOME/active-run.s-stop.json"
echo '{"session_id":"s-stop","transcript_path":"/tmp/stop.jsonl"}' | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
assert_eq "active pointer: no envelope_close written" "0" \
    "$(grep -c '"envelope_close"' "$STOP_TELEM/raw/steps/run-stop-test.jsonl" 2>/dev/null)"
assert_eq "active pointer: transcript recorded" "/tmp/stop.jsonl" \
    "$(tail -1 "$STOP_TELEM/raw/steps/run-stop-test.jsonl" | jq -r .session_transcript_path 2>/dev/null)"
assert_eq "active pointer: compatibility lock survives" "true" \
    "$([ -f "$STOP_TELEM/telemetry.lock" ] && echo true || echo false)"
assert_eq "active pointer: run lock survives" "true" \
    "$([ -f "$STOP_TELEM/locks/run-stop-test.json" ] && echo true || echo false)"

# Repeated Stops keep their transcript records and the selected run remains available to decisions.
echo '{"session_id":"s-stop","transcript_path":"/tmp/stop-later.jsonl"}' | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
assert_eq "active pointer: repeated Stop records both transcripts" "2" \
    "$(grep -c '"layer":"session"' "$STOP_TELEM/raw/steps/run-stop-test.jsonl" 2>/dev/null)"
N1_HOME="$N1_HOME" N1_SESSION_ID=s-stop ID="$STOP_TICK" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash -c 'source "$1/lib/config.sh"; source "$1/lib/telemetry.sh"; n1_record_decision late-review true' bash "$REPO_ROOT"
assert_eq "active pointer: later decision uses retained run" "late-review" \
    "$(tail -1 "$STOP_TELEM/raw/steps/run-stop-test.jsonl" | jq -r .id 2>/dev/null)"

# Pointer-owned paused, escalated, and failed states also survive Stop; overview is not terminal state.
for STOP_STATE in paused escalated failed; do
    STATE_TICK="T-STOP-${STOP_STATE}"
    STATE_TELEM="$N1_HOME/memory/$STATE_TICK/telemetry"
    mkdir -p "$STATE_TELEM/raw/steps" "$STATE_TELEM/runs" "$STATE_TELEM/locks"
    echo "{\"run_id\":\"run-stop-${STOP_STATE}\",\"n1_version\":\"3.14.1\",\"host\":\"claude-code\",\"session_id\":\"s-stop-${STOP_STATE}\"}" > "$STATE_TELEM/locks/run-stop-${STOP_STATE}.json"
    echo "{\"run_id\":\"run-stop-${STOP_STATE}\",\"n1_version\":\"3.14.1\",\"host\":\"claude-code\",\"session_id\":\"s-stop-${STOP_STATE}\"}" > "$STATE_TELEM/telemetry.lock"
    printf -- '---\nstep: %s\n---\n' "$STOP_STATE" > "$N1_HOME/memory/$STATE_TICK/overview.md"
    echo "{\"ticketId\":\"$STATE_TICK\",\"runId\":\"run-stop-${STOP_STATE}\"}" > "$N1_HOME/active-run.s-stop-${STOP_STATE}.json"
    echo "{\"session_id\":\"s-stop-${STOP_STATE}\"}" | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
    assert_eq "active pointer: $STOP_STATE state retains lock" "true" \
        "$([ -f "$STATE_TELEM/telemetry.lock" ] && echo true || echo false)"
done

# A mismatched pointer and a foreign session's pointer cannot retain this selected lock.
MISMATCH_TICK="T-STOP-MISMATCH"
MISMATCH_MEM="$N1_HOME/memory/$MISMATCH_TICK"
MISMATCH_TELEM="$MISMATCH_MEM/telemetry"
mkdir -p "$MISMATCH_TELEM/raw/steps" "$MISMATCH_TELEM/runs" "$MISMATCH_TELEM/locks"
echo '{"run_id":"run-stop-mismatch","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop-mismatch"}' > "$MISMATCH_TELEM/locks/run-stop-mismatch.json"
echo '{"run_id":"run-stop-mismatch","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop-mismatch"}' > "$MISMATCH_TELEM/telemetry.lock"
echo '{"ticketId":"T-STOP-MISMATCH","runId":"other-run"}' > "$N1_HOME/active-run.s-stop-mismatch.json"
echo '{"ticketId":"T-STOP-MISMATCH","runId":"run-stop-mismatch"}' > "$N1_HOME/active-run.s-foreign.json"
echo '{"session_id":"s-stop-mismatch"}' | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
assert_eq "mismatched pointer: abandoned close written" "abandoned" \
    "$(grep '"envelope_close"' "$MISMATCH_TELEM/raw/steps/run-stop-mismatch.jsonl" | tail -1 | jq -r .final_outcome 2>/dev/null)"
assert_eq "mismatched pointer: locks removed" "false" \
    "$([ -f "$MISMATCH_TELEM/telemetry.lock" ] && echo true || echo false)"

# A terminal envelope wins over a residual matching pointer and is never duplicated.
TERM_TICK="T-STOP-TERMINAL"
TERM_MEM="$N1_HOME/memory/$TERM_TICK"
TERM_TELEM="$TERM_MEM/telemetry"
mkdir -p "$TERM_TELEM/raw/steps" "$TERM_TELEM/runs" "$TERM_TELEM/locks"
echo '{"run_id":"run-stop-terminal","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop-terminal"}' > "$TERM_TELEM/locks/run-stop-terminal.json"
echo '{"run_id":"run-stop-terminal","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop-terminal"}' > "$TERM_TELEM/telemetry.lock"
echo '{"layer":"envelope_close","final_outcome":"success"}' > "$TERM_TELEM/raw/steps/run-stop-terminal.jsonl"
echo '{"ticketId":"T-STOP-TERMINAL","runId":"run-stop-terminal"}' > "$N1_HOME/active-run.s-stop-terminal.json"
echo '{"session_id":"s-stop-terminal"}' | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
assert_eq "terminal pointer: close is not duplicated" "1" \
    "$(grep -c '"envelope_close"' "$TERM_TELEM/raw/steps/run-stop-terminal.jsonl" 2>/dev/null)"
assert_eq "terminal pointer: locks removed" "false" \
    "$([ -f "$TERM_TELEM/telemetry.lock" ] && echo true || echo false)"

# session-stop: no lock -> silent exit, no crash
NO_LOCK_MEM="$N1_HOME/memory/T-NOLOCK"
mkdir -p "$NO_LOCK_MEM"
echo '{"session_id":"s-no-lock"}' | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null
assert_eq "stop hook no lock exits clean" "0" "$?"

# --- session-stop: pending background agent -> no terminal envelope_close --
PEND_TICK="T-STOP-PENDING"
PEND_MEM="$N1_HOME/memory/$PEND_TICK"
PEND_TELEM="$PEND_MEM/telemetry"
mkdir -p "$PEND_TELEM/raw/steps" "$PEND_TELEM/raw/agents" "$PEND_TELEM/runs" "$PEND_TELEM/locks"
echo '{"run_id":"run-pending-test","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop-pending"}' > "$PEND_TELEM/locks/run-pending-test.json"
echo '{"run_id":"run-pending-test","n1_version":"3.14.1","host":"claude-code","session_id":"s-stop-pending"}' > "$PEND_TELEM/telemetry.lock"
printf -- '---\ntype: task\ntier: standard\nstep: implementation\n---\n' > "$PEND_MEM/overview.md"
echo '{"run_id":"run-pending-test","layer":"agent","event":"start","agent_id":"a1","agent_type":"product-analyst"}' > "$PEND_TELEM/raw/agents/run-pending-test.jsonl"
echo '{"session_id":"s-stop-pending","transcript_path":"/tmp/pending.jsonl"}' | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
assert_eq "pending agent: no envelope_close written" "0" \
    "$(grep -c '"envelope_close"' "$PEND_TELEM/raw/steps/run-pending-test.jsonl" 2>/dev/null)"
assert_eq "pending agent: lock survives (not removed)" "true" \
    "$([ -f "$PEND_TELEM/telemetry.lock" ] && echo true || echo false)"

# same run, agent later completes (stop event added) -> no pointer cleanup fires normally
echo '{"run_id":"run-pending-test","layer":"agent","event":"stop","agent_id":"a1","agent_type":"product-analyst"}' >> "$PEND_TELEM/raw/agents/run-pending-test.jsonl"
echo '{"session_id":"s-stop-pending","transcript_path":"/tmp/pending.jsonl"}' | N1_HOME="$N1_HOME" N1_STATE_DIR="$N1_STATE_DIR" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-stop.sh" 2>/dev/null || true
assert_eq "agent resolved: abandoned write fires (regression)" "abandoned" \
    "$(grep '"envelope_close"' "$PEND_TELEM/raw/steps/run-pending-test.jsonl" 2>/dev/null | tail -1 | jq -r .final_outcome 2>/dev/null)"
assert_eq "agent resolved: lock removed after merge" "false" \
    "$([ -f "$PEND_TELEM/telemetry.lock" ] && echo true || echo false)"

# --- session-start: queue digest line (NP-194) --------------------------------
QD="$N1_HOME/queue/hq"; mkdir -p "$QD"; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","queue":"hq","run_id":"R1","event":"ticket_finished","ticket":"T-1","outcome":"pr","pr":"","session":"","duration_s":5,"reason":""}\n{"ts":"%s","queue":"hq","run_id":"R1","event":"escalated","ticket":"T-2","outcome":"","pr":"","session":"","duration_s":null,"reason":""}\n' "$NOW" "$NOW" > "$QD/events.jsonl"
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
assert_eq "session-start: queue digest line" "1" \
    "$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext | grep -c '^N1 QUEUE STATUS: Queue hq: 1 PR, 1 needs you (T-2)$' || true)"
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"startup","agent_id":"sub-1"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
assert_eq "session-start: no queue digest when agent_id present (N1-124)" "0" \
    "$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext | grep -c 'N1 QUEUE STATUS' || true)"
OUT=$(echo '{"session_id":"s1","cwd":"/repo","hook_event_name":"SessionStart","source":"compact"}' | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh")
assert_eq "session-start: compact w/o agent_id -> queue line preceded by scope note (N1-124)" "1" \
    "$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext | grep -A1 '^(Scope: orchestrator session only' | grep -c '^N1 QUEUE STATUS' || true)"
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
assert_eq "session-start: startup queue line has no scope note (N1-124)" "0" \
    "$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext | grep -c '^(Scope: orchestrator session only' || true)"
printf 'garbage\n' > "$QD/events.jsonl"
OUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" < "$FX/claude/session-start.json")
assert_eq "session-start: corrupt events -> no digest, valid JSON" "0" \
    "$(echo "$OUT" | jq -r .hookSpecificOutput.additionalContext | grep -c 'N1 QUEUE STATUS' || true)"
rm -rf "$N1_HOME/queue"

# --- session-start: local-testing enable offer (NP-222) ----------------------
LTP="$T/ltproj"; mkdir -p "$LTP"; touch "$LTP/compose.yaml"
has_offer() {
  local ctx
  ctx=$(echo "{\"session_id\":\"s-lt\",\"cwd\":\"$LTP\",\"source\":\"startup\"}" | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start.sh" 2>/dev/null | jq -r .hookSpecificOutput.additionalContext)
  case "$ctx" in *"LOCAL TESTING OFFER"*) echo yes;; *) echo no;; esac
}
echo '{}' > "$N1_HOME/config.json"
assert_eq "enable offer injected when live is off and compose exists" "yes" "$(has_offer)"
echo '{"localTesting":{"autoLive":true}}' > "$N1_HOME/config.json"
assert_eq "no enable offer when live already resolves" "no" "$(has_offer)"
echo '{"localTesting":{"enabled":false,"autoLive":true}}' > "$N1_HOME/config.json"
assert_eq "enable offer when localTesting disabled" "yes" "$(has_offer)"
echo '{"localTesting":{"mode":"test"}}' > "$N1_HOME/config.json"
assert_eq "no enable offer when mode explicitly set to test" "no" "$(has_offer)"
echo '{"localTesting":{"enabled":false,"mode":"test"}}' > "$N1_HOME/config.json"
assert_eq "no enable offer even when disabled, if mode explicitly set (never overwrite a deliberate choice)" "no" "$(has_offer)"
rm "$LTP/compose.yaml"; echo '{}' > "$N1_HOME/config.json"
assert_eq "no enable offer without a compose file" "no" "$(has_offer)"

# --- notify-question hook (N1-103) --------------------------------------------
NQ="$REPO_ROOT/hooks/notify-question.sh"
NQBIN="$T/nqbin"; NQLOG="$T/nq.log"; mkdir -p "$NQBIN"
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s"\n' "$NQLOG" > "$NQBIN/notify-send"; chmod +x "$NQBIN/notify-send"
mkdir -p "$N1_HOME/memory/Q-1"
printf -- '---\nstep: analysis\n---\n' > "$N1_HOME/memory/Q-1/overview.md"
echo '{}' > "$N1_HOME/config.json"
nq() {  # nq [VAR=val ...] -> prints hook exit code; waits briefly for the backgrounded notifier
  local rc=0; : > "$NQLOG"
  echo '{"session_id":"s-nq","tool_name":"AskUserQuestion"}' | env -u N1_HEADLESS -u N1_QUEUE_RUN_ID -u N1_RUN_ID "$@" PATH="$NQBIN:$PATH" bash "$NQ" >"$T/nq.out" 2>&1 || rc=$?
  sleep 0.5; echo "$rc"
}
assert_eq "notify-question: no active run -> exit 0" "0" "$(nq)"
assert_eq "notify-question: no active run -> no call" "0" "$(wc -l < "$NQLOG" | tr -d ' ')"
echo '{"ticketId":"Q-1","runId":"r1","worktreePath":null,"branch":"b"}' > "$N1_HOME/active-run.s-nq.json"
assert_eq "notify-question: active run -> exit 0" "0" "$(nq)"
assert_eq "notify-question: active run -> one call naming ID and step" "N1 Q-1|Waiting for your answer after analysis" "$(cat "$NQLOG")"
assert_eq "notify-question: no stdout" "" "$(cat "$T/nq.out")"
assert_eq "notify-question: N1_HEADLESS=1 -> exit 0" "0" "$(nq N1_HEADLESS=1)"
assert_eq "notify-question: N1_HEADLESS=1 -> no call" "0" "$(wc -l < "$NQLOG" | tr -d ' ')"
assert_eq "notify-question: N1_QUEUE_RUN_ID -> exit 0" "0" "$(nq N1_QUEUE_RUN_ID=q1)"
assert_eq "notify-question: N1_QUEUE_RUN_ID -> no call" "0" "$(wc -l < "$NQLOG" | tr -d ' ')"
echo '{"notify":{"onQuestion":false}}' > "$N1_HOME/config.json"
assert_eq "notify-question: onQuestion=false -> exit 0" "0" "$(nq)"
assert_eq "notify-question: onQuestion=false -> no call" "0" "$(wc -l < "$NQLOG" | tr -d ' ')"
echo '{}' > "$N1_HOME/config.json"
rm "$N1_HOME/active-run.s-nq.json"; echo '{"ticketId":"Q-1"}' > "$N1_HOME/active-run.json"
nq >/dev/null
assert_eq "notify-question: unkeyed pointer ignored" "0" "$(wc -l < "$NQLOG" | tr -d ' ')"
rm "$N1_HOME/active-run.json"
assert_eq "hooks.json: AskUserQuestion matcher runs notify-question.sh" "1" \
  "$(jq '[.hooks.PreToolUse[] | select(.matcher=="AskUserQuestion") | .hooks[].command | select(test("notify-question.sh"))] | length' "$REPO_ROOT/hooks/hooks.json")"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]

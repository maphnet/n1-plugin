# Shared setup and fixtures for tests/test_queue_runner*.sh (N1-304). Sourced by each file, never run:
# the name is outside the tests/test_*.sh glob, so tests/run.sh does not execute it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"; PASS=$((PASS+1))
    else
        echo "FAIL: $label (expected=[$expected] actual=[$actual])"; FAIL=$((FAIL+1))
    fi
}

plan_cell() { # <queue.md> <row#> <col: 8=Status 9=Reason>
    awk -F'|' -v n="$2" -v c="$3" '{ for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) } $2 == n && NF >= 9 { print $c }' "$1"
}

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
export N1_WSL_POWERSHELL=/nonexistent  # never fire a real WSL toast from tests
: "${N1_HOME:=}"; : "${ID:=}"; export N1_HOME ID
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/frontmatter.sh"
source "${REPO_ROOT}/lib/queue.sh"
source "${REPO_ROOT}/lib/validation.sh"

# --- Background-session (claude-code) runner path ----------------------------
# mk_bg <tmp> <queue-id> <ticket:states>... — queue.md plus a fake
# claude and a no-op sleep in <tmp>/bin. States are space-separated, one per poll of
# that session; the last state repeats. Timeout 1 min, poll 30 s -> 2 polls.
# Optional per-ticket files in <tmp>/fake: finish-step.<t>, overview.<t> (full overview written on done),
# overview.<t>.<poll> (full overview written on that poll), relay.<t>.
mk_bg() {
    local tmp="$1" qid="$2" n=0 spec t; shift 2
    mkdir -p "$tmp/bin" "$tmp/fake" "$tmp/n1home/memory"
    # N1-182: runner asks gh for an open PR of an incomplete child; default answer comes from
    # $FAKE_DIR/gh-pr (absent -> no PR). Never reach the real gh from tests.
    # N1-185: pr view prints $FAKE_DIR/gh-state (OPEN/MERGED/CLOSED); absent -> exit 1 as before. N1-422: gh-state-seq overrides it per read.
    # N1-292: pr view --json ...headRefOid reads gh-view[.<pr#>] (TSV); pr checks / pr merge / repo view per the files named in the fake.
    [ -e "$tmp/bin/gh" ] || { cat > "$tmp/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/gh-all"
# N1-292: per-PR view file gh-view.<pr#> (falls back to gh-view), keyed by the */pull/<n> argument.
pr=""; for a in "$@"; do case "$a" in */pull/*) pr="${a##*/}" ;; esac; done
v="$FAKE_DIR/gh-view.$pr"; [ -f "$v" ] || v="$FAKE_DIR/gh-view"
case "$1 $2" in
    "pr list")
        case "$*" in
            *"--head story/"*) # N1-293: final PR lookup; answers gh-final-list.<base> (absent -> no PR)
                echo "$*" >> "$FAKE_DIR/gh-final-calls"
                b=""; prev=""; for a in "$@"; do [ "$prev" = --base ] && b="$a"; prev="$a"; done
                cat "$FAKE_DIR/gh-final-list.$b" 2>/dev/null || echo '[]' ;;
            *) echo "$*" >> "$FAKE_DIR/gh-calls"; cat "$FAKE_DIR/gh-pr" 2>/dev/null ;;
        esac ;;
    "pr view") # N1-214: gh-fail holds a count of reads to fail before answering
        if [ -s "$FAKE_DIR/gh-fail" ]; then n=$(cat "$FAKE_DIR/gh-fail"); if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FAKE_DIR/gh-fail"; exit 1; fi; fi
        case "$*" in
            *mergeable*) # N1-293: one line of gh-mergeable-seq per read (last line repeats); absent -> exit 1
                echo "$*" >> "$FAKE_DIR/gh-mergeable-calls"
                [ -s "$FAKE_DIR/gh-mergeable-seq" ] || exit 1
                head -n1 "$FAKE_DIR/gh-mergeable-seq"
                if [ "$(wc -l < "$FAKE_DIR/gh-mergeable-seq")" -gt 1 ]; then sed -i 1d "$FAKE_DIR/gh-mergeable-seq"; fi ;;
            *headRefOid*) cat "$v" 2>/dev/null || exit 1 ;;   # N1-292: n1_queue_pr_view (TSV state, base, head)
            *) # N1-422: gh-state-seq answers one line per state read (last line repeats); absent -> gh-state
                if [ -s "$FAKE_DIR/gh-state-seq" ]; then
                    head -n1 "$FAKE_DIR/gh-state-seq"
                    if [ "$(wc -l < "$FAKE_DIR/gh-state-seq")" -gt 1 ]; then sed -i 1d "$FAKE_DIR/gh-state-seq"; fi
                else cat "$FAKE_DIR/gh-state" 2>/dev/null || exit 1; fi ;;
        esac ;;
    "pr edit"|"pr ready") # N1-293: the runner's own reuse refresh; logged, gh-edit-fail makes both fail
        echo "$*" >> "$FAKE_DIR/gh-refresh-calls"
        [ -f "$FAKE_DIR/gh-edit-fail" ] && exit 1
        [ "$2" = ready ] && echo ready > "$FAKE_DIR/gh-ready-done"
        exit 0 ;;
    "pr checks") # N1-292: stdout gh-checks[.<pr#>] (N1-424: per PR, falls back to gh-checks), stderr gh-checks-err, exit gh-checks-rc (default 0)
        c="$FAKE_DIR/gh-checks.$pr"; [ -f "$c" ] || c="$FAKE_DIR/gh-checks"
        cat "$FAKE_DIR/gh-checks-err" >&2 2>/dev/null
        cat "$c" 2>/dev/null
        exit "$(cat "$FAKE_DIR/gh-checks-rc" 2>/dev/null || echo 0)" ;;
    "pr merge") # N1-292: log the call; gh-merge-rc != 0 refuses with gh-merge-err; success flips the view to MERGED
        # N1-424: gh-merge-rc|err|queued and gh-view-after also exist per PR as <name>.<pr#> (fall back to the plain name)
        mf() { if [ -e "$FAKE_DIR/$1.$pr" ]; then echo "$FAKE_DIR/$1.$pr"; else echo "$FAKE_DIR/$1"; fi; }
        echo "$*" >> "$FAKE_DIR/gh-merge"
        rc=$(cat "$(mf gh-merge-rc)" 2>/dev/null || echo 0)
        if [ "$rc" != 0 ]; then cat "$(mf gh-merge-err)" >&2 2>/dev/null; exit "$rc"; fi
        IFS=$'\t' read -r _ b h < "$v"
        [ -f "$(mf gh-view-after)" ] && b=$(cat "$(mf gh-view-after)")
        st=MERGED; [ -f "$(mf gh-merge-queued)" ] && st=OPEN   # a merge queue leaves the PR OPEN
        printf '%s\t%s\t%s\n' "$st" "$b" "$h" > "$v"
        printf 'MERGED %s\n' "$b" > "$FAKE_DIR/gh-state"
        if [ -f "$FAKE_DIR/gh-view-gone-after" ]; then rm -f "$v"; fi ;;   # the post-merge base re-read then fails
    "repo view") # gh-repo-fail-from2: the 2nd and later repo reads fail (the pin lookup follows the repo identity check)
        n=$(cat "$FAKE_DIR/gh-repo-n" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_DIR/gh-repo-n"
        [ -f "$FAKE_DIR/gh-repo-fail-from2" ] && [ "$n" -ge 1 ] && exit 1
        cat "$FAKE_DIR/gh-repo" 2>/dev/null || exit 1 ;;
    *) exit 1 ;;
esac
GHEOF
        chmod +x "$tmp/bin/gh"; }
    cat > "$tmp/bin/claude" <<'FAKEEOF'
#!/usr/bin/env bash
# Fake claude CLI for background-session tests. State lives in $FAKE_DIR.
D="$FAKE_DIR"
case "$1" in
    --bg)
        all="$*"; name=""; settings=""; prompt=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --name) name="$2"; shift ;;
                --settings) settings="$2"; shift ;;
                --model|--permission-mode|--plugin-dir) shift ;;
                --bg) ;;
                *) prompt="$1" ;;
            esac
            shift
        done
        echo "launch $name" >> "$D/events"
        # forge-story: the launched child rewrites queue.md to story mode (frontmatter + mapping for the repo in the file)
        [ -f "$D/forge-story" ] && sed -i -e '1a mode: story\nstory_id: S-1' \
            -e "/^## Runs\$/i ## Story Branches\n| Repo | Branch |\n|------|--------|\n| $(cat "$D/forge-story") | story/S-1 |\n" "$D/../queue.md"
        printf '%s\n' "$all" > "$D/args.$name"
        printf '%s\n' "$settings" > "$D/settings.$name"
        pwd > "$D/cwd.$name"   # N1-293: the final PR session runs in the runner's worktree
        if [ -f "$D/refuse" ] || { [ -f "$D/refuse-clean" ] && [ "${name%-clean}" != "$name" ]; } || { [ -f "$D/refuse-done" ] && [ "${name%-done}" != "$name" ]; }; then
            echo "Bypass Permissions mode requires accepting the disclaimer first. Run claude --dangerously-skip-permissions once."
            exit 1
        fi
        printf '%s\n' "$prompt" > "$D/prompt.$name"
        # N1-293: a final story PR session (<name> contains -final-) opens PR 9 on story/S-1 when final-create exists:
        # gh-final-list.<base> (base parsed from the prompt) gets one open PR, a draft exactly when the prompt says --draft.
        case "$name" in *-final-*)
            if [ -f "$D/final-create" ]; then
                b=$(grep -o -- '--base [^ ]*' <<< "$prompt" | head -1); b="${b#--base }"
                dr=false; grep -qF -- '--draft' <<< "$prompt" && dr=true
                printf '[{"url":"https://github.com/o/r/pull/9","isDraft":%s,"headRefName":"story/S-1","baseRefName":"%s","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]\n' "$dr" "$b" > "$D/gh-final-list.$b"
            fi ;;
        esac
        t="${prompt##* }"
        grep '^queue_tag_removed:' "$FAKE_N1H/memory/$t/overview.md" > "$D/flag.$t" 2>/dev/null || true
        n=$(( $(cat "$D/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/seq"
        printf '%08x' "$n" > "$D/id.$name"
        printf 'backgrounded \xc2\xb7 %08x \xc2\xb7 %s\n' "$n" "$name"
        ;;
    agents)
        # N1-293: agents-fail-final makes the session list unreadable once a final session was launched
        if [ -f "$D/agents-fail-final" ] && compgen -G "$D/prompt.*-final-*" >/dev/null; then echo "agents down" >&2; exit 1; fi
        out=""
        for f in "$D"/prompt.*; do
            [ -f "$f" ] || continue
            name="${f##*/prompt.}"; t=$(cat "$f"); t="${t% chained}"; t="${t##* }"
            c=$(( $(cat "$D/poll.$name" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$D/poll.$name"
            # N1-185: a chained n1-finish session (<name>-fin) replays states.<t>.fin (default done).
            sf="$D/states.$t"; case "$name" in *-final-*) sf="$D/states.$t.final" ;; *-fin) sf="$D/states.$t.fin" ;; *-clean) sf="$D/states.$t.clean" ;; *-done) sf="$D/states.$t.done" ;; esac
            read -r -a seq 2>/dev/null < "$sf" || seq=(done)
            i=$(( c < ${#seq[@]} ? c - 1 : ${#seq[@]} - 1 ))
            st="${seq[$i]}"
            echo "state $name $st" >> "$D/events"
            # relay.<t>: an answer relay in flight; lands as the runner's marker (mtime kept) when
            # the fake first reports the session stopped, i.e. after the runner saw the first block.
            [ "$st" = stopped ] && [ -f "$D/relay.$t" ] && mv "$D/relay.$t" "$D/../.relay-$t"
            if [ "${name%-done}" != "$name" ] || [ "${name#*-final-}" != "$name" ]; then :   # N1-292/N1-293: Done and final sessions never write a child overview
            elif [ "${name%-fin}" != "$name" ]; then
                # N1-185: fin-merge.<t> makes the chained finish merge the PR when it is done.
                [ "$st" = done ] && [ -f "$D/fin-merge.$t" ] && echo MERGED > "$D/gh-state"
            elif [ -f "$D/overview.$t.$c" ]; then
                mkdir -p "$FAKE_N1H/memory/$t"
                cp "$D/overview.$t.$c" "$FAKE_N1H/memory/$t/overview.md"
                echo "overview $name $c" >> "$D/events"
            elif [ "$st" = done ]; then
                # N1-74: the runner now polls agents again after a ticket finalizes (draining
                # the bg session until idle); cap done-poll writes so a later poll doesn't
                # clobber what finalize already stamped onto overview.md (e.g. queue_run_id).
                wn=$(( $(cat "$D/wrote.$t" 2>/dev/null || echo 0) + 1 ))
                if [ "$wn" -le 1 ]; then
                    echo "$wn" > "$D/wrote.$t"
                    mkdir -p "$FAKE_N1H/memory/$t"
                    # finish-step.<ticket>: overrides the terminal step (default pr) so a test
                    # can simulate a bg session reporting done while overview never reached a
                    # terminal step (NP-216).
                    step="pr"; [ -f "$D/finish-step.$t" ] && step=$(cat "$D/finish-step.$t")
                    if [ -f "$D/overview.$t" ]; then cp "$D/overview.$t" "$FAKE_N1H/memory/$t/overview.md"
                    else printf -- '---\nstep: %s\n---\n# T\n\n## Pending\npr_url: https://x/pr/1\n' "$step" > "$FAKE_N1H/memory/$t/overview.md"; fi
                fi
            fi
            sid=$(cat "$D/id.$name" 2>/dev/null || echo "00000000")
            # stopeffective: a stopped session reports done afterwards (default: the stop has no effect).
            # stoplag: N (file content) agents reads after the stop still report the old state.
            if [ -f "$D/stopeffective" ] && grep -qx "$sid" "$D/stopped" 2>/dev/null; then
                lagn=$(cat "$D/stoplag" 2>/dev/null || echo 0)
                if [ "$lagn" -gt 0 ]; then echo $((lagn - 1)) > "$D/stoplag"; else st=done; fi
            fi
            out="$out${out:+,}{\"kind\":\"background\",\"id\":\"$sid\",\"sessionId\":\"$sid-0000-0000-0000-000000000000\",\"name\":\"$name\",\"state\":\"$st\",\"waitingFor\":null,\"pid\":1,\"cwd\":\"/r\"}"
        done
        echo "[$out]"
        ;;
    stop)
        if [ -f "$D/stopfail.$2" ]; then
            echo "$2" >> "$D/stopfail-log"
            rm -f "$D/stopfail.$2"
            exit 1
        fi
        echo "$2" >> "$D/stopped"
        ;;
esac
FAKEEOF
    printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"
    chmod +x "$tmp/bin/claude" "$tmp/bin/sleep"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":1,"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$tmp" > "$tmp/n1home/config.json"
    {
        printf -- '---\nstep: plan\nqueue_id: %s\n---\n## Plan\n' "$qid"
        printf '| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|--------|-------|------|---------|-------|--------|--------|\n'
        for spec in "$@"; do
            n=$((n + 1)); t="${spec%%:*}"
            printf '%s\n' "${spec#*:}" > "$tmp/fake/states.$t"
            printf '| %s | %s | Fix %s | %s | %s | sonnet | pending | |\n' "$n" "$t" "$t" "$tmp" "$tmp/n1home"
        done
        printf '\n## Runs\n| Ticket | Started | Exit | Outcome | PR | Session |\n|--------|---------|------|---------|----|---------|\n'
    } > "$tmp/queue.md"
}

run_bg_queue() { # <tmp> — runs the runner with the fakes first on PATH; prints its exit code
    local rc=0
    env -u ORCA_CLI_COMMAND FAKE_DIR="$1/fake" FAKE_N1H="$1/n1home" N1_HOME="$1/n1home" PATH="$1/bin:$PATH" \
        bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$1/queue.md" > "$1/output.txt" 2>&1 || rc=$?
    echo "$rc"
}

line_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }

# --- N1-225: Orca orchestration backend ---------------------------------------
# mk_orca <tmp> — fake Orca CLI <tmp>/bin/fake-orca on top of mk_bg's fakes; argv log in $FAKE_DIR/orca-calls.
# worker-start copies the ticket's sentinel to $FAKE_DIR/sentinel.<t> and writes the child's overview at once
# (none when $FAKE_DIR/keepov.<t> exists; else $FAKE_DIR/overview.<t> if present, else step from $FAKE_DIR/step.<t>, default pr). check reports worker_done once per started task unless
# $FAKE_DIR/nodone.<t> exists, plus $FAKE_DIR/question (one message JSON) once any task has started, plus
# $FAKE_DIR/heartbeat (one message JSON) on every check once any task has started. $FAKE_DIR/at.<n> runs on the n-th check.
# N1-270: each call also logs "<verb> <sub> <ORCA_TERMINAL_HANDLE>" to $FAKE_DIR/orca-handles; terminal create returns the
# handle in $FAKE_DIR/sink (no file: fails); FAKE_ORCA_SINK_REFUSE=1 makes run-create refuse that handle.
mk_orca() {
    : > "$1/fake/orca-calls"
    cat > "$1/bin/fake-orca" <<'ORCAEOF'
#!/usr/bin/env bash
D="$FAKE_DIR"; printf '%s\n' "$*" >> "$D/orca-calls"; printf '%s %s %s\n' "$1" "$2" "${ORCA_TERMINAL_HANDLE:-}" >> "$D/orca-handles"
ok() { printf '{"id":"1","ok":true,"result":%s}\n' "$1"; }
err() { printf '{"id":"1","ok":false,"error":{"code":"x","message":"%s"}}\n' "$1"; exit 1; }
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "$2"; return; }; shift; done; }
msg() { jq -cn --arg y "$1" --arg k "$2" --arg i "$3" '{id: $i, type: $y, payload: ({taskId: $k, dispatchId: ("d-" + ($k | ltrimstr("task-")))} | tojson)}'; }   # real shape: ids only in the payload string
full=0; for a in "$@"; do [ "$a" = --full ] && full=1; done
# Real 1.4.247 CLI: concise receipts unless --full; --full is an unknown flag outside orchestration.
[ "$full" = 1 ] && [ "$1" != orchestration ] && { printf '{"id":"1","ok":false,"error":{"code":"invalid_argument","message":"Unknown flag --full"}}\n'; exit 1; }
case "$1 $2" in
  "status --json") [ -n "${FAKE_ORCA_DOWN:-}" ] && err "runtime down"; ok '{"runtime":{"reachable":true}}' ;;
  "orchestration run-create") [ -n "${FAKE_ORCA_RUN_FAIL:-}" ] && err "unknown command"
      [ -n "${FAKE_ORCA_SINK_REFUSE:-}" ] && [ "${ORCA_TERMINAL_HANDLE:-}" = "$(cat "$D/sink" 2>/dev/null)" ] && err "not your terminal"
      if [ "$full" = 1 ]; then ok '{"run":{"id":"run-1"}}'; else ok '{"runId":"run-1","objective":"x"}'; fi ;;
  "terminal create") [ -f "$D/sink" ] || err "no terminals"; ok "{\"terminal\":{\"handle\":\"$(cat "$D/sink")\"}}" ;;
  "orchestration run-use") [ -n "${FAKE_ORCA_RUNUSE_FAIL:-}" ] && err "no such run"; ok '{}' ;;
  "orchestration task-create") [ -n "${FAKE_ORCA_TASK_FAIL:-}" ] && err "task-create failed"; if [ "$full" = 1 ]; then ok "{\"task\":{\"id\":\"task-$(arg --task-title "$@")\"}}"; else ok "{\"taskId\":\"task-$(arg --task-title "$@")\",\"status\":\"ready\"}"; fi ;;
  "orchestration worker-start")
      task=$(arg --task "$@"); t="${task#task-}"
      [ -n "${FAKE_ORCA_START_FAIL:-}" ] && err "lost response"
      cp "$FAKE_N1H/queue/sentinels/$t.env" "$D/sentinel.$t" 2>/dev/null
      echo "$task" >> "$D/started"
      mkdir -p "$FAKE_N1H/memory/$t"
      if [ -f "$D/keepov.$t" ]; then :   # N1-271: a resumed worker leaves the existing memory alone at start
      elif [ -f "$D/overview.$t" ]; then cp "$D/overview.$t" "$FAKE_N1H/memory/$t/overview.md"
      else printf -- '---\nstep: %s\n---\n## Pending\npr_url: https://x/pr/%s\n' "$(cat "$D/step.$t" 2>/dev/null || echo pr)" "$t" > "$FAKE_N1H/memory/$t/overview.md"; fi
      ok "{\"dispatch\":{\"id\":\"d-$t\"}}" ;;
  "orchestration check")
      [ -n "$(arg --ack "$@")" ] && { ok '{}'; exit 0; }
      [ -n "${FAKE_ORCA_CHECK_FAIL:-}" ] && [ -s "$D/started" ] && err "inbox down"   # N1-268: inbox unreadable once a worker runs
      m=""; n=$(( $(cat "$D/ncheck" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/ncheck"
      [ -f "$D/at.$n" ] && bash "$D/at.$n"   # N1-267: $D/at.<n>: script run on the n-th check (tick n), before that tick's row loop
      # $D/replay: the first 5 checks replay a message for a task no row owns (a missed ack); on the 6th the
      # tickets named in $D/finish-late finish.
      [ -f "$D/replay" ] && [ "$n" -le 5 ] && m=$(msg question task-ghost m-ghost)
      if [ -f "$D/replay" ] && [ "$n" -eq 6 ]; then cp "$D/overview.late" "$FAKE_N1H/memory/T-A/overview.md"; fi
      while read -r task; do
          [ -f "$D/nodone.${task#task-}" ] && continue
          grep -qx "$task" "$D/reported" 2>/dev/null && continue
          echo "$task" >> "$D/reported"
          m="$m${m:+,}$(msg worker_done "$task" "m-$task")"
      done < <(cat "$D/started" 2>/dev/null)
      if [ -f "$D/question" ] && [ -s "$D/started" ]; then m="$m${m:+,}$(cat "$D/question")"; rm -f "$D/question"; fi
      if [ -f "$D/heartbeat" ] && [ -s "$D/started" ]; then m="$m${m:+,}$(cat "$D/heartbeat")"; sleep 0.2; fi
      ok "{\"deliveryId\":\"del-1\",\"messages\":[$m]}" ;;
  "worktree list") [ -n "${FAKE_ORCA_WT_FAIL:-}" ] && err "boom"; ok "{\"worktrees\":[$(cat "$D/worktrees" 2>/dev/null)]}" ;;   # $D/worktrees: comma-separated {"path":...} objects
  "orchestration worker-list") [ -n "${FAKE_ORCA_WL_FAIL_AFTER:-}" ] && [ "$(grep -c 'worker-list' "$D/orca-calls")" -gt "$FAKE_ORCA_WL_FAIL_AFTER" ] && err "list down"
      cat "$D/workers.json" 2>/dev/null || ok '{"workers":[]}' ;;
  "orchestration worker-release") ok '{}' ;;
  "terminal close") [ -n "${FAKE_ORCA_CLOSE_FAIL:-}" ] && err "close failed"; ok '{}' ;;
  *) err "unknown command" ;;
esac
ORCAEOF
    chmod +x "$1/bin/fake-orca"
}

run_orca_queue() { # <tmp> [VAR=value...] — run_bg_queue with the fake Orca CLI as ORCA_CLI_COMMAND. Pass N1_QUEUE_TEST_MAX_TICKS=<n>
                   # to end a run whose workers never finish after n ticks (runner self-SIGTERM, rc 143) instead of a wall-clock timeout.
    local tmp="$1" rc=0; shift
    env -u CLAUDE_CONFIG_DIR HOME="$tmp/hh" "$@" ORCA_CLI_COMMAND="$tmp/bin/fake-orca" FAKE_DIR="$tmp/fake" FAKE_N1H="$tmp/n1home" N1_HOME="$tmp/n1home" PATH="$tmp/bin:$PATH" \
        timeout 60 bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" > "$tmp/output.txt" 2>&1 || rc=$?   # N1-268: a runner missing a behaviour fails fast (rc 124) instead of hanging
    echo "$rc"
}

cfg_set() { jq "$2" "$1/n1home/config.json" > "$1/cfg.tmp" && mv "$1/cfg.tmp" "$1/n1home/config.json"; } # <tmp> <jq-filter>
# orca_msg <type> <task> <msg-id> [stopReason] [subject] [body] — one inbox message, real Orca 1.4.243 shape
# (taskId/dispatchId and stopReason only inside "payload"; subject/body top-level, as the observed stop notice).
orca_msg() {
    jq -cn --arg y "$1" --arg k "$2" --arg i "$3" --arg s "${4:-}" --arg sub "${5:-}" --arg b "${6:-}" \
        '{id: $i, type: $y, payload: ({taskId: $k, dispatchId: ("d-" + ($k | ltrimstr("task-")))}
            + (if $s != "" then {stopReason: $s} else {} end) | tojson)}
         + (if $sub != "" then {subject: $sub} else {} end) + (if $b != "" then {body: $b} else {} end)'
}

# wl_row <ticket> <running|succeeded|released> [liveness verdict] [stage detail] — one worker-list row, real Orca 1.4.243
# shape. A stage detail (N1-333, e.g. terminal_missing) adds projection.stage {worker: "abandoned", detail}.
wl_row() {
    local ws ds ts oc nx lv
    case "$2" in
        running)   ws=ready;     ds=dispatched; ts=active;      oc=in_progress; nx=none;    lv=live ;;
        succeeded) ws=succeeded; ds=completed;  ts=reclaimable; oc=succeeded;   nx=release; lv=unverifiable ;;
        released)  ws=succeeded; ds=completed;  ts=released;    oc=succeeded;   nx=none;    lv=exited ;;
    esac
    lv="${3:-$lv}"
    jq -cn --arg t "$1" --arg ws "$ws" --arg ds "$ds" --arg ts "$ts" --arg oc "$oc" --arg nx "$nx" --arg lv "$lv" --arg sd "${4:-}" \
        '{dispatchId: ("d-" + $t), taskId: ("task-" + $t), runId: "run-1", workerState: $ws, dispatchStatus: $ds,
          terminalState: $ts, resource: {}, projection: ({outcome: $oc, nextAction: {kind: $nx, argv: []},
          liveness: ({verdict: $lv} + (if $lv == "unverifiable" then {reason: "missing_status"} else {} end))}
          + (if $sd != "" then {stage: {worker: "abandoned", detail: $sd}} else {} end))}'
}
wl_set() { local tmp="$1"; shift; local IFS=,; printf '{"ok":true,"result":{"workers":[%s]}}\n' "$*" > "$tmp/fake/workers.json"; }   # <tmp> <row-json>...

# drain_notifier <tmp> — N1-265: desktop notify through a notify-send that swallows its stdin (what WSL
# powershell.exe does); each call appends to $FAKE_DIR/drained so a test can prove the notifier fired.
drain_notifier() {
    printf '#!/bin/sh\nwhile read -r _; do :; done\necho x >> "%s/fake/drained"\nexit 0\n' "$1" > "$1/bin/notify-send"
    chmod +x "$1/bin/notify-send"
    cfg_set "$1" '.queue.notify = "desktop"'
}

# orca_lib <tmp> <fn> [args...] — N1-268: run one lib function with the fake Orca CLI, the fake gh and a private HOME.
orca_lib() {
    local tmp="$1"; shift
    env -u CLAUDE_CONFIG_DIR HOME="$tmp/hh" ORCA_CLI_COMMAND="$tmp/bin/fake-orca" FAKE_DIR="$tmp/fake" FAKE_N1H="$tmp/n1home" \
        N1_HOME="$tmp/n1home" PATH="$tmp/bin:$PATH" \
        bash -c 'r="$1"; shift; for f in config frontmatter queue orca-queue; do source "$r/lib/$f.sh"; done; "$@"' _ "$REPO_ROOT" "$@"
}

# orca_live_fixture <tmp> <pr-url> — one in-progress Orca row T-A with its identity file, Runs row and a running worker
# whose own terminal handle is term-A.
orca_live_fixture() {
    local tmp="$1"
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    mkdir -p "$tmp/hh" "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: implement\n---\n## Pending\npr_url: %s\n' "$2" > "$tmp/n1home/memory/T-A/overview.md"
    n1_queue_row_status "$tmp/queue.md" 1 in-progress
    echo "| T-A | 2026-11-02T00:00:00Z | | | | orca:task-T-A/d-T-A |" >> "$tmp/queue.md"
    : > "$tmp/events.jsonl"
    orca_lib "$tmp" n1_orca_sentinel_write "$tmp/n1home" T-A "$tmp" RID run-1 task-T-A
    wl_set "$tmp" "$(wl_row T-A running | jq -c '.resource.terminalHandle = "term-A"')"
}

# orca_resumed_row <tmp> — N1-267: a resumed run whose row T-A is already in-progress on a live, unverifiable Orca worker
# (no launch, so the fake worktree list may already name T-A); overview step implement; timeout 1 min, poll 30 s.
orca_resumed_row() {
    local tmp="$1"
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-1; n1_write_frontmatter "$tmp/queue.md" run_id R1; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    mkdir -p "$tmp/n1home/queue/sentinels"; printf 'N1_ORCA_TASK=task-T-A\n' > "$tmp/n1home/queue/sentinels/T-A.env"
    n1_queue_row_status "$tmp/queue.md" 1 in-progress
    echo "| T-A | 2026-10-31T00:00:00Z | | | | orca:task-T-A/d-T-A |" >> "$tmp/queue.md"
    mkdir -p "$tmp/n1home/memory/T-A"; printf -- '---\nstep: implement\n---\n' > "$tmp/n1home/memory/T-A/overview.md"
    wl_set "$tmp" "$(wl_row T-A running unverifiable)"
}

# orca_stall_fixture <tmp> <line>... — N1-267: orca_resumed_row plus Orca worktree /orca/wt/T-A and its newest Claude
# transcript ($tmp/cc, passed as CLAUDE_CONFIG_DIR) holding the given JSONL lines; at.<n> scripts get $tmp/fake/{late,asst}.
orca_stall_fixture() {
    local tmp="$1"; shift
    orca_resumed_row "$tmp"
    printf '{"path":"/orca/wt/T-A"}' > "$tmp/fake/worktrees"
    mkdir -p "$tmp/cc/projects/-orca-wt-T-A"
    printf '%s\n' "$@" > "$tmp/cc/projects/-orca-wt-T-A/s1.jsonl"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/fake/late"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"resumed"}]}}' > "$tmp/fake/asst"
}

# N1-60 follow-up: a field full of control characters (U+0001) JSON-encodes each char
# as a 6-byte \u0001 escape, and a field full of 4-byte UTF-8 (emoji) is 4x its char
# count in bytes — both can push the capped-at-2000-chars packed reason well past
# execve's 128 KiB per-arg limit (~156 KiB and ~104 KiB respectively at 13 max-length
# fields) unless the control chars are stripped before capping and a hard byte-size
# fallback shrinks the per-field cap.
mk_oversized_question() {
    # Usage: mk_oversized_question <dir> <ticket> <char> — writes a .question-<ticket>.json
    # with question/10-options/recommended/rationale all at the 2000-char cap, filled
    # with 2000 repeats of <char> (may be a multi-byte literal). Built via a plain bash
    # loop, not `yes | head` (SIGPIPE under pipefail, N1-75).
    local dir="$1" ticket="$2" ch="$3" v="" opts i
    for ((i = 0; i < 2000; i++)); do v+="$ch"; done
    opts=""
    for i in $(seq 1 10); do opts="$opts\"$v\","; done
    opts="${opts%,}"
    printf '{"question":"%s","options":[%s],"recommended":"%s","rationale":"%s"}' \
        "$v" "$opts" "$v" "$v" > "$dir/.question-$ticket.json"
}

# start_fake_runner — sets FAKE_RUNNER_PID to a live process whose cmdline names n1-queue-run
# (what n1_queue_runner_alive accepts as a runner). stop_fake_runner kills and reaps it.
start_fake_runner() {
    # N1-185 SEC-2: argv is script + queue path, as the launcher starts the real runner.
    bash -c 'sleep 30; :' "${1:-/x}/scripts/n1-queue-run.sh" "${2:-/x/queue.md}" >/dev/null 2>&1 &
    FAKE_RUNNER_PID=$!
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        case "$(tr '\0' ' ' < "/proc/$FAKE_RUNNER_PID/cmdline" 2>/dev/null)" in *n1-queue-run*) return 0 ;; esac
        [ -r "/proc/$FAKE_RUNNER_PID/cmdline" ] || return 0
        sleep 0.2
    done
}
stop_fake_runner() { kill "$FAKE_RUNNER_PID" 2>/dev/null || true; wait "$FAKE_RUNNER_PID" 2>/dev/null || true; }

# count_x <file> <exact-line> — number of lines equal to <exact-line> (0 when the file is missing).
count_x() { [ -f "$1" ] || { echo 0; return; }; grep -cxF -- "$2" "$1" || true; }

# seed_live_session <tmp> <name> <ticket> <id8> — a live bg session the fake claude lists (states.<ticket>).
seed_live_session() {
    printf '/n1:n1-start %s\n' "$3" > "$1/fake/prompt.$2"
    printf '%s' "$4" > "$1/fake/id.$2"
}

# N1-185 chain fixtures.
chain_setup() { # <tmp> <fullAuto> <mergeOnFinish> — config with both flags; PR state OPEN
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":10,"notify":"command","notifyCommand":"cat >> %s/notes"},"autonomy":{"fullAuto":%s},"finishWork":{"mergeOnFinish":%s}}\n' \
        "$1" "$2" "$3" > "$1/n1home/config.json"
    echo OPEN > "$1/fake/gh-state"
}
gh_overview() { # <file> <pr-number> — overview at step pr with a GitHub pr_url
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://github.com/o/r/pull/%s\n' "$2" > "$1"
}
runs_outcome() { # <queue.md> <ticket> — Outcome cell of the ticket's last Runs row
    awk -F'|' -v tk="$2" '/^## Runs/{f=1;next} f { t=$2; gsub(/ /,"",t); if (t == tk) { o=$5; gsub(/ /,"",o) } } END { print o }' "$1"
}

# Review fixes: reconcile (marker hit) state handling.
chain_restart_setup() { # <tmp> <marker-state> — pr row of this run, marker with that state, no live fin session
    mk_bg "$1" bgq "T-A:done"
    chain_setup "$1" true true
    n1_write_frontmatter "$1/queue.md" run_id R1
    n1_queue_row_status "$1/queue.md" 1 pr
    echo '| T-A | 2026-01-01T00:00:00Z | | pr | https://github.com/o/r/pull/1 | 00000009 |' >> "$1/queue.md"
    mkdir -p "$1/n1home/memory/T-A"; gh_overview "$1/n1home/memory/T-A/overview.md" 1
    n1_write_frontmatter "$1/n1home/memory/T-A/overview.md" queue_run_id R1
    echo done > "$1/fake/states.T-A.fin"; touch "$1/fake/fin-merge.T-A"
    printf 'R1\n%s\n' "$2" > "$1/.chained-T-A"
}

# --- n1_queue_status_table ----------------------------------------------------
mk_status_queue() { # <tmp> — a 3-row queue.md + events.jsonl + overview.md fixture
    local tmp="$1"
    mkdir -p "$tmp/h/memory/T-2" "$tmp/h/memory/T-4"
    printf -- '---\nstep: review\n---\n' > "$tmp/h/memory/T-2/overview.md"
    printf -- '---\nstep: escalated\n---\n\n## Escalations\n\n- [headless] qa: first blocker\n- [headless] implementation: second blocker\n' > "$tmp/h/memory/T-4/overview.md"
    {
        printf '## Plan\n| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|--------|-------|------|---------|-------|--------|--------|\n'
        printf '| 1 | T-1 | A | /r | %s/h | sonnet | pr | |\n' "$tmp"
        printf '| 2 | T-2 | B | /r | %s/h | sonnet | in-progress | |\n' "$tmp"
        printf '| 3 | T-3 | C | /r | %s/h | sonnet | awaiting-human | |\n' "$tmp"
        printf '| 4 | T-4 | D | /r | %s/h | sonnet | escalated | |\n' "$tmp"
        printf '\n## Runs\n| Ticket | Started | Exit | Outcome | PR | Session |\n|--------|---------|------|---------|----|---------|\n'
        printf '| T-1 | 2020-01-01T00:00:00Z | | pr | https://x/pr/1 | 00000001 |\n'
        printf '| T-2 | %s | | | | 0000abcd |\n' "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)"
        printf '| T-3 | %s | | | | 11112222 |\n' "$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)"
        printf '| T-4 | 2020-01-01T00:00:00Z | | escalated | | |\n'
    } > "$tmp/q.md"
    printf '{"ts":"2020-01-01T00:01:00Z","queue":"q","run_id":"r","event":"ticket_finished","ticket":"T-1","outcome":"pr","pr":"https://x/pr/1","session":"00000001","duration_s":60,"reason":""}\n' \
        > "$tmp/events.jsonl"
}

# N1-64: held rows (same-plan blocker) — helpers and runner hold/expire.
mk_held_plan() { # <file> <status-of-T-1>
    cat > "$1" <<EOF
---
queue_id: q
run_id: R1
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | A | /r | /h | sonnet | $2 | |
| 2 | T-2 | B | /r | /h | sonnet | held | blocked_on T-1 · tag match |
| 3 | T-3 | C | /r | /h | sonnet | held | blocked_on T-2 |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
}

# sched_set <tmp> <max_concurrent|-> [<ticket> <after>]... — N1-303: a planned max_concurrent in mk_bg's
# frontmatter ("-" = none) and a ## Schedule section (one row per ticket/after pair) before ## Runs.
sched_set() {
    local f="$1/queue.md" mc="$2" rows=""; shift 2
    while [ $# -ge 2 ]; do rows="$rows| $1 | $2 |"$'\n'; shift 2; done
    MC="$mc" ROWS="$rows" awk '
        NR == 2 && ENVIRON["MC"] != "-" { print "max_concurrent: " ENVIRON["MC"] }
        /^## Runs$/ && ENVIRON["ROWS"] != "" { printf "## Schedule\n| Ticket | After |\n|--------|-------|\n%s\n", ENVIRON["ROWS"] }
        { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# touches_set <tmp> <ticket> <touches>... — N1-269: a ## Decisions table (Touches column only) before ## Runs, then
# the real n1_queue_schedule_write derives ## Schedule from it (unlike sched_set, edges are not hand-written).
touches_set() {
    local f="$1/queue.md" rows="" t; shift
    while [ $# -ge 2 ]; do rows="$rows| $1 | $2 |  |  |  |  |"$'\n'; shift 2; done
    ROWS="$rows" awk '/^## Runs$/ { printf "## Decisions\n| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |\n|--------|---------|-------|-------------------------|---------------|-------|\n%s\n", ENVIRON["ROWS"] }
        { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    bash -c "source '$REPO_ROOT/lib/config.sh'; source '$REPO_ROOT/lib/queue.sh'; n1_queue_schedule_write '$f'"
}

# N1-290: sb_fixture <tmp> <mode> [origin] — mk_bg queue "sq" with two rows (T-A, T-B) in one real clone
# ($tmp/repo) of <origin> (default: a fresh $tmp/origin with one commit on main); mode (and story_id S-1 in story
# mode) in frontmatter; $tmp/fake/events exists so a launch count reads 0 when nothing launched.
sb_fixture() {
    local tmp="$1" origin="${3:-$1/origin}"
    if [ -z "${3:-}" ]; then
        git init -q -b main "$origin"
        git -C "$origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    fi
    git clone -q "$origin" "$tmp/repo" 2>/dev/null
    mk_bg "$tmp" sq "T-A:done" "T-B:done"
    sed -i "s#| $tmp | $tmp/n1home |#| $tmp/repo | $tmp/n1home |#g" "$tmp/queue.md"
    n1_write_frontmatter "$tmp/queue.md" mode "$2"
    [ "$2" = story ] && n1_write_frontmatter "$tmp/queue.md" story_id S-1
    : > "$tmp/fake/events"
}

# --- N1-292: runner story merge --------------------------------------------------
SM_PIN=$(printf '%040d' 0 | tr 0 1)   # the reviewed head every story fixture PR reports
nlines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# story_merge_fixture <tmp> <ticket:states>... — mk_bg queue "sq" in story mode (story_id S-1). All rows sit in one real
# clone ($tmp/repo) whose origin carries story/S-1. Config has fullAuto and mergeOnFinish off (the story merge needs
# neither). The fake gh answers repo view o/r, CI green, and per PR (number = row number) OPEN on story/S-1 at $SM_PIN.
# Each row has a review pin and a GitHub pr_url overview.
story_merge_fixture() {
    local tmp="$1" n=0 spec t; shift
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git -C "$tmp/origin" branch story/S-1
    git clone -q "$tmp/origin" "$tmp/repo" 2>/dev/null
    mk_bg "$tmp" sq "$@"
    sed -i "s#| $tmp | $tmp/n1home |#| $tmp/repo | $tmp/n1home |#g" "$tmp/queue.md"
    n1_write_frontmatter "$tmp/queue.md" mode story
    n1_write_frontmatter "$tmp/queue.md" story_id S-1
    chain_setup "$tmp" false false
    echo o/r > "$tmp/fake/gh-repo"
    echo '[{"bucket":"pass"}]' > "$tmp/fake/gh-checks"
    mkdir -p "$tmp/n1home/review-pins"
    for spec in "$@"; do
        n=$((n + 1)); t="${spec%%:*}"
        gh_overview "$tmp/fake/overview.$t" "$n"
        printf 'OPEN\tstory/S-1\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.$n"
        echo "$SM_PIN" > "$tmp/n1home/review-pins/o_r_$n"
    done
    : > "$tmp/fake/events"
}

# story_restart_setup <tmp> <marker-state|""> <OPEN|MERGED> — story_merge_fixture T-A at pr of run R1 (as
# chain_restart_setup), the Story Branches row written, PR 1 in that state on story/S-1 at $SM_PIN, and the
# .chained-T-A marker in that state (none for "").
story_restart_setup() {
    story_merge_fixture "$1" "T-A:done"
    n1_write_frontmatter "$1/queue.md" run_id R1
    n1_queue_row_status "$1/queue.md" 1 pr
    n1_queue_story_branch_set "$1/queue.md" "$1/repo" story/S-1
    echo '| T-A | 2026-01-01T00:00:00Z | | pr | https://github.com/o/r/pull/1 | 00000009 |' >> "$1/queue.md"
    mkdir -p "$1/n1home/memory/T-A"; gh_overview "$1/n1home/memory/T-A/overview.md" 1
    n1_write_frontmatter "$1/n1home/memory/T-A/overview.md" queue_run_id R1
    printf '%s\tstory/S-1\t%s\n' "$3" "$SM_PIN" > "$1/fake/gh-view.1"
    [ -z "$2" ] || printf 'R1\n%s\n' "$2" > "$1/.chained-T-A"
}

# --- N1-293: final story PR ----------------------------------------------------------
# final_fixture <tmp> <ticket:states>... — story_merge_fixture whose final PR session opens PR 9 (final-create) and whose
# mergeable read answers UNKNOWN once, then MERGEABLE/CLEAN.
final_fixture() {
    story_merge_fixture "$@"
    touch "$1/fake/final-create"
    printf 'UNKNOWN\t\nMERGEABLE\tCLEAN\n' > "$1/fake/gh-mergeable-seq"
}
fin_row() { n1_queue_final_prs "$1/queue.md" | awk -F'\t' -v r="$2" '$1 == r' | cut -f2-; }   # <tmp> <repo>

# --- N1-424: gated runner merge of the final PR ---------------------------------------
# final_merge_fixture <tmp> <ticket:states>... — final_fixture with fullAuto and mergeOnFinish on, one commit on origin
# story/S-1 (FM_HEAD: the final PR head, so the Codex diff is not empty), PR 9 OPEN into main at FM_HEAD, and a fake
# codex first on PATH (logged in; exec mode per $FAKE_DIR/codex-mode: fail|hang|findings|move; default "No findings.").
# The fake logs each review to codex-calls and the reviewed checkout's HEAD to codex-head; "move" rewrites PR 9's head.
final_merge_fixture() {
    local tmp="$1"
    final_fixture "$@"
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true'
    git -C "$tmp/origin" checkout -q story/S-1
    echo story > "$tmp/origin/story.txt"
    git -C "$tmp/origin" add story.txt
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q -m story
    git -C "$tmp/origin" checkout -q main
    FM_HEAD=$(git -C "$tmp/origin" rev-parse story/S-1)
    printf 'OPEN\tmain\t%s\n' "$FM_HEAD" > "$tmp/fake/gh-view.9"
    cat > "$tmp/bin/codex" <<'CXEOF'
#!/usr/bin/env bash
[ "$1" = login ] && exit 0
echo "$*" >> "$FAKE_DIR/codex-calls"
git rev-parse HEAD > "$FAKE_DIR/codex-head"
m=$(cat "$FAKE_DIR/codex-mode" 2>/dev/null)
case "$m" in
    fail) exit 1 ;;
    hang) exec /bin/sleep 10 ;;
    move) printf 'OPEN\tmain\t%040d\n' 2 > "$FAKE_DIR/gh-view.9" ;;
esac
o='No findings.'; [ "$m" = findings ] && o=$'[P1] x is wrong\n[P2] y'
while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf '%s\n' "$o" > "$2"; break; }; shift; done
CXEOF
    chmod +x "$tmp/bin/codex"
}
run_fm() { N1_STATE_DIR="$1/state" run_bg_queue "$1"; }   # <tmp> — Codex receipts under <tmp>, never in ~/.n1
fin_note() { fin_row "$1" "$1/repo" | cut -f4; }            # <tmp>
fm_merges() { [ -f "$1/fake/gh-merge" ] || { echo 0; return; }; grep -c -- "pull/$2 " "$1/fake/gh-merge" || true; }   # <tmp> <pr#>
fm_event() { jq -r 'select(.event == "final_pr_merge") | "\(.outcome)|\(.reason)"' "$1/events.jsonl"; }   # <tmp>
has_file() { [ -e "$1" ] && echo yes || echo no; }

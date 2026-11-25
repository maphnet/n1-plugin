#!/usr/bin/env bash
# lib/worker-step.sh (N1-645): entry, result and question helpers for the ci-worker and local-testing-worker
# dispatches (skills/n1-start/procedures/step-worker-dispatch.md), plus the local-testing auto-skip check.
# Requires lib/preamble.sh first. Needs $N1_HOME and $ID. Never calls step markers (the skill text keeps them; both
# workers are denied them) and holds no remote-write commands (tests/test_pr_step_lib.sh greps lib/*-step.sh).
_n1_sw_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_n1_sw_persona() { case "$1" in ci) echo ci-worker;; lt) echo local-testing-worker;; *) return 1;; esac; }

n1_sw_entry() {
    # Usage: n1_sw_entry ci <pr> | n1_sw_entry lt — writes <memory>/<s>-input.md (ci: pr; lt: mode and the QA runner
    # commands from qa.md), removes stale <s>-result.md and <s>-question.md, prints the worker model line.
    local S="${1:-}" P PM MEM="$N1_HOME/memory/$ID"
    P=$(_n1_sw_persona "$S") || { echo "ERROR: n1_sw_entry: unknown step '$S'" >&2; return 1; }
    if [ "$S" = ci ]; then
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "ERROR: n1_sw_entry ci: PR number required" >&2; return 1; }
    fi
    rm -f "$MEM/$S-result.md" "$MEM/$S-question.md"
    if [ "$S" = ci ]; then
        printf 'pr: %s\n' "$2" > "$MEM/ci-input.md"
    else
        { echo "mode: live"; echo "qa_runner_cmds: |"
          grep 'Runner command:' "$MEM/qa.md" 2>/dev/null | sed 's/.*Runner command: */  /'; } > "$MEM/lt-input.md"
    fi
    IFS=$'\t' read -r PM _ < <(n1_resolve_agent "$P")
    echo "model:$PM memory:$MEM n1_root:$N1_ROOT worktree:$(git rev-parse --show-toplevel)"
}

n1_sw_result() {
    # Usage: n1_sw_result <ci|lt> — parses <memory>/<s>-result.md. Prints sw:<complete|stopped|question|prompt|unknown>,
    # outcome: (success|failed|skipped, else empty), metadata: (compact JSON object, else empty), reason: (printable, 300).
    local S="${1:-}" F T O M R
    _n1_sw_persona "$S" >/dev/null || { echo "sw:unknown"; return 1; }
    F="$N1_HOME/memory/$ID/$S-result.md"
    T=$(sed -nE 's/^status: (complete|stopped|question)\r?$/\1/p' "$F" 2>/dev/null | tail -1)
    O=$(sed -nE 's/^outcome: (success|failed|skipped)\r?$/\1/p' "$F" 2>/dev/null | tail -1)
    R=$(sed -n 's/^reason: //p' "$F" 2>/dev/null | head -1 | tr -cd '[:print:]' | cut -c1-300)
    M=$(sed -n 's/^metadata: //p' "$F" 2>/dev/null | head -1 | tr -d '\r')
    [ -z "$M" ] || M=$(jq -ce 'select(type=="object")' <<<"$M" 2>/dev/null) || M=
    [ "$T" = complete ] && [ -z "$O" ] && T=
    [ "$T" = stopped ] && [[ ${R,,} == prompt:* ]] && T=prompt
    [ "$T" = question ] && [ ! -s "$N1_HOME/memory/$ID/$S-question.md" ] && T=
    echo "sw:${T:-unknown}"; echo "outcome:$O"; echo "metadata:$M"; echo "reason:$R"
}

n1_sw_question() {
    # Usage: n1_sw_question <ci|lt> — prints class:, stop_list:, recommended:, question: and one option: line per option
    # from <memory>/<s>-question.md, then removes the file. Fails closed: unknown class -> stop_list:security and
    # recommended:none; missing stop_list -> security. recommended is set by class (lt-fix-exhausted 2 with 2+ options, else none)
    # and the file field is ignored; stop_list is raised by stop-list wording in the question/options.
    local S="${1:-}" F C L RC Q N OPTS D
    _n1_sw_persona "$S" >/dev/null || { echo "class:unknown"; return 1; }
    F="$N1_HOME/memory/$ID/$S-question.md"
    [ -s "$F" ] || { echo "class:unknown"; return 1; }
    C=$(sed -nE "s/^class: ($S-[a-z-]+)\r?\$/\1/p" "$F" | head -1)
    case "$C" in
        ci-escalate|ci-low-confidence|ci-not-branch-caused|ci-cap-exhausted|ci-pending-budget|lt-env-failure|lt-fix-exhausted) ;;
        *) C=unknown;;
    esac
    L=$(sed -nE 's/^stop_list: (none|security|architecture|public-api)\r?$/\1/p' "$F" | head -1)
    N=$(grep -c '^option: ' "$F")
    # The class fixes the recommendation (step text: "No recommendation" except the 9d skip action); the file's field is ignored.
    RC=none; [ "$C" = lt-fix-exhausted ] && [ "$N" -ge 2 ] && RC=2
    Q=$(sed -n 's/^question: //p' "$F" | head -1 | tr -cd '[:print:]' | cut -c1-4000)
    OPTS=$(sed -n 's/^option: //p' "$F" | head -9 | tr -cd '[:print:]\n' | cut -c1-1000)
    # The stop list can only grow here: question/option text naming a stop-list category overrides the worker's field.
    if [ "${L:-none}" = none ] || [ "$C" = unknown ]; then
        D=$(grep -oiE -m1 'secur|vulnerab|credential|secret|authori[sz]|authenticat|architect|public[ -]?(api|interface)|breaking change' <<<"$Q"$'\n'"$OPTS" | head -1)
        case "${D,,}" in
            secur*|vulnerab*|credential|secret|authori*|authenticat*) L=security;;
            architect*) L=architecture;;
            ?*) L=public-api;;
        esac
    fi
    [ "$C" = unknown ] && L=security
    echo "class:$C"; echo "stop_list:${L:-security}"; echo "recommended:$RC"; echo "question:$Q"
    sed 's/^/option:/' <<<"$OPTS"
    rm -f "$F"
}

n1_sw_lt_auto_skip() {
    # Usage: n1_sw_lt_auto_skip — prints true only when every changed file is non-runtime (docs, .gitignore; any YAML or
    # env file is runtime); an unresolvable base, a failed diff or an empty diff prints false. Records the
    # local-testing-auto-skip decision. rc 1 on an invalid story base.
    local SB BP_FILE BASE_REF BASE CHANGED_FILES SKIP=false
    source "$_n1_sw_dir/classify.sh"
    SB=$(n1_story_base) || { echo "ERROR: invalid story base" >&2; return 1; }
    BP_FILE="$N1_HOME/memory/$ID/branch-point"
    BASE_REF=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || { [ -n "$SB" ] && echo "origin/$SB"; } || n1_config_val '.git.defaultBranch' )
    if BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null) && CHANGED_FILES=$(git diff --no-renames --name-only "$BASE" 2>/dev/null); then
        SKIP=$(n1_classify_local_test_skip "$CHANGED_FILES")
    fi
    n1_record_decision local-testing-auto-skip "$SKIP" '{}' "skip=$SKIP" >&2
    echo "$SKIP"
}

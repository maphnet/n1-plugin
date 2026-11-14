#!/usr/bin/env bash
# N1 shared helpers: N1_HOME resolution, JSON config, model resolution, JSON escaping
# shellcheck source=host.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host.sh"

n1_home() {
    local home

    # 1. Env-var override (highest priority — platform-local, user-controlled)
    if [ -n "${N1_HOME:-}" ]; then
        printf '%s' "$N1_HOME"
        return
    fi

    # 2. Auto-derive from repo name: $HOME/.n1/<slug>
    # Try both remote-URL and directory-name slugs — n1-init historically used
    # directory name, so existing setups may only match that.
    local slug_remote slug_dir candidate
    slug_remote=$(basename "$(git remote get-url origin 2>/dev/null)" .git 2>/dev/null || true)
    slug_dir=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)
    for candidate in "$slug_remote" "$slug_dir"; do
        [ -n "$candidate" ] || continue
        candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
        home="${HOME}/.n1/${candidate}"
        if [ -d "$home" ]; then
            printf '%s' "$home"
            return
        fi
    done

    # 3. Legacy: git config n1.home (backward compat)
    home=$(git config n1.home 2>/dev/null || true)
    if [ -n "$home" ]; then
        home="${home/#\~/$HOME}"
        if [ -n "${WSL_DISTRO_NAME:-}" ] && [[ "$home" =~ ^[A-Z]:/ ]]; then
            home=$(wslpath -u "$home" 2>/dev/null) || true
        fi
        printf '%s' "$home"
        return
    fi

    # 4. Legacy: in-repo .n1/
    if [ -f "${PWD}/.n1/n1.config.json" ]; then
        printf '%s' ".n1"
        return
    fi
    if [ -f "${PWD}/.n1/config.json" ]; then
        printf '%s' ".n1"
        return
    fi
}

n1_config_file() {
    local home
    home=$(n1_home)
    if [ -n "$home" ]; then
        if [ "${home#.}" != "$home" ] && [ -f "${PWD}/${home}/n1.config.json" ]; then
            printf '%s' "${home}/n1.config.json"
        else
            printf '%s' "${home}/config.json"
        fi
    else
        if [ -f "${PWD}/.n1/n1.config.json" ]; then
            printf '%s' ".n1/n1.config.json"
        elif [ -f "${PWD}/.n1/config.json" ]; then
            printf '%s' ".n1/config.json"
        fi
    fi
}

n1_config_val() {
    local path="$1" file="${2:-$(n1_config_file)}"
    [ -f "$file" ] || return 0
    case "$path" in [A-Za-z_]*) path=".$path";; esac  # dotless path is a jq function call, not a key (N1-567)
    if command -v jq >/dev/null 2>&1; then
        jq -r "if (${path}) == null then empty else (${path}) end" "$file" 2>/dev/null || true
        return
    fi
    local stripped="${path#.}"
    local section="${stripped%%.*}"
    local key="${stripped#*.}"
    # Value pattern matches quoted strings AND unquoted scalars (true/false/numbers/null),
    # so boolean gates like localTesting.enabled work without jq.
    local val_re="\"${key}\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[-0-9a-zA-Z.]\{1,\}\)"
    if [ "$section" = "$key" ]; then
        grep -o "$val_re" "$file" 2>/dev/null \
            | head -1 | sed -e 's/.*:[[:space:]]*//' -e 's/^"//' -e 's/"$//' || true
    else
        awk -v sec="\"${section}\"" '
            $0 ~ sec { if ($0 ~ /:[[:space:]]*null/) exit; found=1; depth=0 }
            found && /{/ { depth++ }
            found && /}/ { depth--; if(depth<=0) { found=0 } }
            found { print }
        ' "$file" 2>/dev/null \
            | grep -o "$val_re" \
            | head -1 | sed -e 's/.*:[[:space:]]*//' -e 's/^"//' -e 's/"$//' || true
    fi
}

# n1_tag_is_service_label <tag> [config-file] — rc 0 when <tag> equals the ticketTagging service label (N1-548).
# The label pipeline mirrors references/ticket-tagging.md § Resolve (parity checked by tests/test_ticket_tagging_wiring.sh);
# the tag is normalized the same way. Disabled tagging, empty service or empty label: rc 1.
n1_tag_is_service_label() {
    local file="${2:-$(n1_config_file)}" label tag
    [ "$(n1_config_val '.ticketTagging.enabled' "$file")" = true ] || return 1
    label=$(printf '%s' "$(n1_config_val '.ticketTagging.service' "$file")" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' '-' | tr -cd 'a-z0-9._-' | sed 's/^[-._]*//; s/[-._]*$//')
    tag=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' '-' | tr -cd 'a-z0-9._-' | sed 's/^[-._]*//; s/[-._]*$//')
    [ -n "$label" ] && [ "$tag" = "$label" ]
}

n1_config_ops() {
    local path="$1" file="${2:-$(n1_config_file)}"
    [ -f "$file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r "${path} // {} | to_entries | map(\"\(.key)=\(.value)\") | join(\", \")" "$file" 2>/dev/null || true
        return
    fi
    local stripped="${path#.}"
    local section="${stripped%%.*}"
    local opkey="${stripped#*.}"
    awk -v sec="\"${section}\"" '
        $0 ~ sec { found=1; depth=0 }
        found && /{/ { depth++ }
        found && /}/ { depth--; if(depth<=0) { found=0 } }
        found { print }
    ' "$file" 2>/dev/null \
        | awk -v ops="\"${opkey}\"" '
            $0 ~ ops { found=1; depth=0 }
            found && /{/ { depth++ }
            found && /}/ { depth--; if(depth<=0) { print; found=0; next } }
            found { print }
        ' 2>/dev/null \
        | grep -o '"[a-zA-Z_]*"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | grep -v "\"${opkey}\"" \
        | sed 's/"\([^"]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1=\2/' \
        | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g' || true
}

n1_resolve_tier() {
    local tier="$1" base_model="$2"
    case "$tier" in
        frontier) printf 'opus' ;;
        standard) printf '%s' "$base_model" ;;
        downgrade)
            case "$base_model" in
                opus) printf 'sonnet' ;;
                sonnet) printf 'haiku' ;;
                *) printf '%s' "$base_model" ;;
            esac
            ;;
        minimal) printf 'haiku' ;;
        *) printf '%s' "$base_model" ;;
    esac
}

_n1_agent_frontmatter() {
    # Usage: _n1_agent_frontmatter <persona> <model|effort>
    local persona="$1" key="$2" agent_file
    agent_file="$(n1_plugin_root)/agents/${persona}.md"
    [ -f "$agent_file" ] || return 0
    awk -v key="$key" 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { exit } in_fm && $0 ~ "^" key ":[[:space:]]*" { sub("^" key ":[[:space:]]*", ""); gsub(/\r/, ""); print; exit }' "$agent_file"
}

_n1_known_role() {
    local role
    role=$(_n1_agent_frontmatter "$1" model)
    case "$role" in opus|sonnet|haiku) printf '%s' "$role";; esac
}

_n1_model_override() {
    # Usage: _n1_model_override <persona> — models.<persona> from config, or empty.
    # Plain string. A pre-4.0 host-keyed object is read through its "claude-code" key.
    local persona="$1" config_file
    config_file=$(n1_config_file)
    [ -f "$config_file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg p "$persona" '
            .models[$p] as $e |
            if ($e|type) == "string" then $e
            elif ($e|type) == "object" then ($e["claude-code"] | if type == "string" then . elif type == "object" then (.model // empty) else empty end)
            else empty end' "$config_file" 2>/dev/null || true
    else
        n1_config_val ".models.${persona}" "$config_file"
    fi
}

n1_model_for() {
    # Usage: n1_model_for <persona> — the model to spawn this persona with.
    local persona="$1" v role
    role=$(_n1_known_role "$persona")
    if [ -n "$role" ]; then n1_resolve_model "$persona"; return; fi
    v=$(_n1_model_override "$persona")
    if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    printf 'sonnet'
}

n1_resolve_model() {
    local agent_name="$1"
    local context="${2:-}"
    local override=""
    local config_file
    config_file=$(n1_config_file)

    # 1. Config override (always wins)
    override=$(_n1_model_override "$agent_name")
    if [ -n "$override" ]; then printf '%s' "$override"; return; fi

    # Get base model from agent frontmatter
    local base_model
    base_model=$(_n1_known_role "$agent_name")
    if [ -z "$base_model" ]; then
        printf 'sonnet'; return
    fi

    # 2. Signal-driven escalation/downgrade (condition-gated)
    local pipeline_file="$(n1_plugin_root)/pipeline.json"
    if [ -f "$pipeline_file" ] && [ -n "$context" ] && command -v jq >/dev/null 2>&1; then
        local trigger_key="${agent_name}:${context}"
        local mem_dir="${N1_HOME:+${N1_HOME}/memory/${ID}}"
        local overview_file="${mem_dir:+${mem_dir}/overview.md}"

        type n1_eval_signal_gate >/dev/null 2>&1 || source "$(n1_plugin_root)/lib/signals.sh" 2>/dev/null || true

        local section trigger_tier trigger_cond
        for section in escalation_triggers downgrade_triggers; do
            trigger_tier=$(jq -r ".${section}[\"${trigger_key}\"].tier // empty" "$pipeline_file" 2>/dev/null || true)
            [ -n "$trigger_tier" ] || continue

            trigger_cond=$(jq -c ".${section}[\"${trigger_key}\"].condition // empty" "$pipeline_file" 2>/dev/null || true)
            if [ -z "$trigger_cond" ] || [ "$trigger_cond" = '""' ]; then
                # No condition — apply unconditionally
                n1_resolve_tier "$trigger_tier" "$base_model"
                return
            fi

            # Evaluate condition; requires memory dir
            if [ -n "$mem_dir" ] && [ -d "$mem_dir" ]; then
                type n1_record_decision >/dev/null 2>&1 || source "$(n1_plugin_root)/lib/telemetry.sh" 2>/dev/null || true
                local dec_id="${section%_triggers}:${trigger_key}"   # e.g. escalation:developer:implementation
                if n1_eval_signal_gate "$mem_dir" "$overview_file" "$trigger_cond"; then
                    n1_record_decision "$dec_id" true "$trigger_cond" "tier=${trigger_tier}" 2>/dev/null || true
                    n1_resolve_tier "$trigger_tier" "$base_model"
                    return
                else
                    n1_record_decision "$dec_id" false "$trigger_cond" "tier=${trigger_tier}" 2>/dev/null || true
                fi
            fi
        done
    fi

    # 3. Profile step_overrides (from type registry)
    if [ -f "$pipeline_file" ] && [ -n "$N1_HOME" ] && [ -n "$ID" ]; then
        local overview_file="${N1_HOME}/memory/${ID}/overview.md"
        if [ -f "$overview_file" ]; then
            source "$(n1_plugin_root)/lib/frontmatter.sh" 2>/dev/null || true
            local wf_type
            wf_type=$(n1_read_frontmatter "$overview_file" "type" 2>/dev/null || true)
            if [ -n "$wf_type" ]; then
                local step_name="$context"
                [ -z "$step_name" ] && step_name="$agent_name"
                local profile_tier=""
                if command -v jq >/dev/null 2>&1; then
                    profile_tier=$(jq -r ".types[\"${wf_type}\"].step_overrides[\"${step_name}\"].model_tier // empty" "$pipeline_file" 2>/dev/null || true)
                fi
                if [ -n "$profile_tier" ]; then
                    n1_resolve_tier "$profile_tier" "$base_model"
                    return
                fi
            fi
        fi
    fi

    # 4. Agent frontmatter default
    printf '%s' "$base_model"
}

n1_resolve_agent() {
    # Usage: n1_resolve_agent <persona> [step-context] — prints "<model>\t<effort>".
    # Effort is always empty on Claude Code; the column stays so tab-splitting callers are unchanged.
    printf '%s\t\n' "$(n1_resolve_model "$1" "${2:-}")"
}

n1_plan_approval_required() {
    # Prints true/false; exit code agrees (0 only when true).
    # Headless runs (N1_HEADLESS=1, e.g. queue children) have no user to answer Gate 2, so the plan checkpoint is always off there.
    if [ "${N1_HEADLESS:-}" = "1" ]; then printf 'false'; return 1; fi
    local v; v=$(n1_config_val '.planReview.requirePlanApproval')
    [ "$v" = "true" ] && printf 'true' || printf 'false'
    [ "$v" = "true" ]
}

n1_post_deploy_verification_enabled() {
    # Prints true/false. An explicit boolean owns the gate; only an absent key may
    # fall back to legacy smoke mode. Invalid explicit values fail closed.
    local file state
    file=$(n1_config_file)
    if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
        printf 'false'
        return
    fi
    state=$(jq -r '
        if (.finishWork? | type) == "object"
          and (.finishWork.postDeployVerification? | type) == "object"
          and (.finishWork.postDeployVerification | has("enabled"))
        then (.finishWork.postDeployVerification.enabled | if type == "boolean" then . else "invalid" end)
        else "absent"
        end
    ' "$file" 2>/dev/null || printf 'invalid')
    case "$state" in
        true|false) printf '%s' "$state"; return ;;
        invalid) printf 'false'; return ;;
    esac
    [ "$(n1_config_val '.localTesting.mode')" = "smoke" ] && printf 'true' || printf 'false'
}

n1_finish_merge_enabled() {
    # N1-140. Prints true only when finishWork.mergeOnFinish is the JSON boolean true.
    # Absent, false, strings ("true"), numbers, invalid JSON, a missing file or no jq: false.
    local file out
    file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1 \
        && out=$(jq -r '(.finishWork? | objects | .mergeOnFinish) == true' "$file" 2>/dev/null) && [ "$out" = "true" ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

n1_fullauto_enabled() {
    # N1-146. Prints true only when autonomy.fullAuto is the JSON boolean true (same rules as
    # n1_finish_merge_enabled). fullAuto chains n1-finish after PR + CI; it never merges on its own.
    local file out
    file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1 \
        && out=$(jq -r '(.autonomy? | objects | .fullAuto) == true' "$file" 2>/dev/null) && [ "$out" = "true" ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

n1_release_autorun_enabled() {
    # N1-301. Prints true only when release.autoRun is the JSON boolean true (the string "true" is false;
    # n1_config_val would print true for both). autoRun skips per-step "Run this?" prompts in custom
    # release procedures and the missing-offer ask; it never skips the Step 3 confirmation gate.
    local file out
    file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1 \
        && out=$(jq -r '(.release? | objects | .autoRun) == true' "$file" 2>/dev/null) && [ "$out" = "true" ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

n1_merge_authorized() {
    # N1-146. The one merge predicate for n1-finish and the merge-deny hook (mirrored in
    # hooks/enforce-agent-policy.py merge_authorized): mergeOnFinish true, and in an unattended
    # run (N1_QUEUE_RUN_ID set or N1_HEADLESS=1) fullAuto true as well.
    [ "$(n1_finish_merge_enabled)" = true ] || { printf 'false'; return; }
    if [ -n "${N1_QUEUE_RUN_ID:-}" ] || [ "${N1_HEADLESS:-}" = 1 ]; then
        n1_fullauto_enabled
    else
        printf 'true'
    fi
}

n1_review_artifacts_ok() {
    # N1-182. rc 0 when the active run's review step left its artifacts: a non-empty review-cr.md,
    # or review.md carrying the review-core SKIP record ("Review skipped"). Fails open (rc 0) with
    # no active-run pointer, no ticketId, an unsafe ticketId or no jq (standalone n1-pr, non-N1 use;
    # same precedent as n1_review_check_run). rc 1 (artifacts/event missing), rc 2 (verdict not PASS)
    # or rc 3 (head not bound to the review, N1-184) prints the ticket id.
    # Also requires (SEC-3) a review step event in some run file of this ticket (n1_step_begin
    # "review"), so a hand-written review-cr.md fails; any run file, not only the active runId's,
    # because n1_run_begin mints a new runId on resume. With review-cr.md the combined review.md must
    # open with "### Verdict: PASS" (SEC-1; review-hdr.md is first, the reviewers' own verdict lines
    # follow); the "Review skipped" record needs no verdict. Fails open when the pointer's runId is
    # empty/none or the ticket has no step telemetry at all.
    # N1-184: with a non-empty <head>, the head must be the end of the review head chain over the
    # ticket's ended step events in run-file (chronological) order: an ended "review" event sets the
    # chain to its metadata.head (a missing head breaks it); a "head" event (n1_head_record: soft-fix
    # pass, n1-pr doc commit, conflict-free rebase) moves it to metadata.head only when metadata.from
    # equals the current end (a record whose head already is the end is a no-op); heads and froms
    # that are not 40-hex count as missing. A broken chain stays broken until the next review event.
    # ponytail: blocks stale artifacts and unrecorded commits, not forgery (memory and telemetry are
    # agent-writable; signed evidence would be a separate ticket). review-sec.md is not required
    # because "security reviewer required" is not persisted. n1-finish's pin == head check stays the backstop.
    local home="$1" head="${2:-}" f id rid end
    local -a steps
    f=$(n1_active_run_file) && [ -f "$f" ] && command -v jq >/dev/null 2>&1 || return 0
    id=$(jq -r '.ticketId // empty' "$f" 2>/dev/null)
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$id" != . ] && [ "$id" != .. ] || return 0
    rid=$(jq -r '.runId // empty' "$f" 2>/dev/null)
    steps=("$home/memory/$id/telemetry/raw/steps/"*.jsonl)
    [ -e "${steps[0]}" ] || steps=()
    if [ -n "$rid" ] && [ "$rid" != none ] && [ "${#steps[@]}" -gt 0 ]; then
        grep -qh '"layer":"step","step":"review"' "${steps[@]}" 2>/dev/null || { printf '%s' "$id"; return 1; }
        if [ -n "$head" ]; then
            end=$(jq -Rrn '
                def sha: if type == "string" and test("^[0-9a-f]{40}$") then . else null end;
                [inputs | fromjson? | objects | select(.layer == "step" and has("outcome"))]
                | reduce .[] as $e (null;
                    (($e.metadata | objects | .head | sha) // null) as $to | (($e.metadata | objects | .from | sha) // null) as $from
                    | if $e.step == "review" then $to
                    elif $e.step == "head" then (if . != null and $to == . then . elif . != null and $from == . then $to else null end)
                    else . end)
                | strings' "${steps[@]}" 2>/dev/null)
            [[ "$end" =~ ^[0-9a-f]{40}$ ]] && [ "$end" = "$head" ] || { printf '%s' "$id"; return 3; }
        fi
    fi
    if [ -s "$home/memory/$id/review-cr.md" ]; then
        [ "$(grep -m1 '^### Verdict:' "$home/memory/$id/review.md" 2>/dev/null)" = '### Verdict: PASS' ] && return 0
        printf '%s' "$id"; return 2
    fi
    grep -qF 'Review skipped' "$home/memory/$id/review.md" 2>/dev/null && return 0
    printf '%s' "$id"
    return 1
}

n1_review_reviewed_head() {
    # N1-439. Prints metadata.head (40-hex) of the last ended "review" step event of the active-run
    # ticket, over its run files in chronological order (same pointer guards as n1_review_artifacts_ok);
    # empty when none. Diff base for the pre-PR re-review in skills/n1-start/steps/pr.md: when the
    # head chain is broken its end is null, so the last reviewed tip is the only reliable base.
    local home="$1" f id
    local -a steps
    f=$(n1_active_run_file) && [ -f "$f" ] && command -v jq >/dev/null 2>&1 || return 0
    id=$(jq -r '.ticketId // empty' "$f" 2>/dev/null)
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$id" != . ] && [ "$id" != .. ] || return 0
    steps=("$home/memory/$id/telemetry/raw/steps/"*.jsonl)
    [ -e "${steps[0]}" ] || return 0
    jq -Rrn '[inputs | fromjson? | objects | select(.layer == "step" and .step == "review" and has("outcome"))
        | .metadata | objects | .head | strings | select(test("^[0-9a-f]{40}$"))] | last // empty' "${steps[@]}" 2>/dev/null
}

n1_review_pin() {
    # N1-141 (SEC-5). The PR head that passed N1 review: one 40-hex SHA per PR in
    # $(n1_home)/review-pins/<owner>_<repo>_<pr>. n1-finish merges only that head.
    #   get <pr>                  print the bare pin; empty when missing; "unavailable" on any lookup failure
    #   set <pr> [--confirmed]    pin the PR's current head (n1-pr Step 9); refuses (rc 1, pin:refused)
    #                             when the active run has no review artifacts (N1-182) or the head is
    #                             not the reviewed SHA or a recorded post-review head (N1-184); --confirmed
    #                             is only for the user-confirmed n1-finish re-pins (repin.md, resolve-dirty.md)
    #   advance <pr> <from> <to>  move the pin to <to> only when it is <from> (N1 fix-loop pushes)
    # set/advance print pin:set|advanced <sha7>, pin:kept or pin:unavailable and never fail the
    # caller (only set's pin:refused returns 1); a missing pin makes n1-finish refuse to merge (fail closed).
    # set/advance only pin a head equal to the local tip of the PR branch (refs/heads/<headRefName>,
    # shared by every worktree), i.e. a commit N1 itself pushed. A foreign push, or a run that
    # pushed nothing, leaves the pin behind (or unset) and n1-finish refuses to merge.
    # ponytail: the user's own commits pushed from this checkout (e.g. "Fix manually") are advanced
    # too, and so is anything pulled into the checkout from others (git pull adopts it as reviewed);
    # per-commit provenance would need signed commits.
    local op="${1:-}" pr="${2:-}" home repo file cur sha="" tmp="" br tip id rc
    home=$(n1_home)
    # One head lookup for set: the guard binds to the same SHA that is pinned below (N1-184).
    [ "$op" != set ] || sha=$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null)
    if [ "$op" = set ] && [ "${3:-}" != --confirmed ] && [ -n "$home" ]; then
        id=$(n1_review_artifacts_ok "$home" "$sha"); rc=$?
        if [ "$rc" = 2 ]; then
            echo "pin:refused review-failed $id (the review verdict is not PASS; fix and re-review)"
            echo "n1_review_pin: refused: memory/$id/review.md does not open with '### Verdict: PASS'" >&2
            return 1
        elif [ "$rc" = 3 ]; then
            echo "pin:refused unreviewed-head $id (head is not the reviewed SHA or a recorded post-review head; re-run review)"
            echo "n1_review_pin: refused: PR head ${sha:0:7} is not the end of the review head chain in memory/$id/telemetry" >&2
            return 1
        elif [ "$rc" != 0 ]; then
            echo "pin:refused no-review-artifacts $id (run the review step; do not hand-write the pin)"
            echo "n1_review_pin: refused: no review-cr.md or skipped review.md in memory/$id for the active run" >&2
            return 1
        fi
    fi
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr / _)
    if [ -z "$home" ] || [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        [ "$op" = get ] && echo unavailable || echo pin:unavailable
        return 0
    fi
    if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        [ "$op" = get ] && echo unavailable || echo pin:unavailable
        return 0
    fi
    file="$home/review-pins/${repo}_$pr"
    cur=$(cat "$file" 2>/dev/null)
    case "$op" in
        get) [[ "$cur" =~ ^[0-9a-f]{40}$ ]] && printf '%s\n' "$cur"; return 0 ;;
        set) ;;
        advance) [[ "$cur" =~ ^[0-9a-f]{40}$ ]] && [ "$cur" = "${3:-}" ] || { echo pin:kept; return 0; }; sha="${4:-}" ;;
        *) return 1 ;;
    esac
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo pin:unavailable; return 0; }
    br=$(gh pr view "$pr" --json headRefName -q .headRefName 2>/dev/null)
    tip=""; [ -z "$br" ] || tip=$(git rev-parse --verify -q "refs/heads/$br" 2>/dev/null)
    if [ "$sha" != "$tip" ]; then
        [ "$op" = set ] && echo pin:unavailable || echo pin:kept
        return 0
    fi
    if mkdir -p "${file%/*}" && tmp=$(mktemp "$file.XXXXXX") && printf '%s\n' "$sha" > "$tmp" && mv -f "$tmp" "$file"; then
        if [ "$op" = set ]; then echo "pin:set ${sha:0:7}"; else echo "pin:advanced ${sha:0:7}"; fi
    else
        [ -z "$tmp" ] || rm -f "$tmp"
        echo pin:unavailable
    fi
    return 0
}

n1_delivery_action() {
    # NP-219. Prints none | runbook | execute for the n1-finish delivery step.
    # none: delivery.mode is not "ssh" (absent/empty/unknown) -> the step is a no-op.
    # runbook: queue children and headless runs never execute delivery.command; they leave
    #   a runbook for the human (no auto-resolved confirm prompt can approve a deploy).
    #   Also forced when jq is unavailable: the grep/awk config-value fallback mis-parses
    #   escaped quotes, so its output must never be executed (SEC-3).
    # execute: interactive runs ask, execute, verify.
    # Without jq the fallback cannot read compact JSON, so any "delivery" key fails closed
    # to runbook; none only when the config has no delivery block at all.
    if ! command -v jq >/dev/null 2>&1; then
        if grep -q '"delivery"[[:space:]]*:' "$(n1_config_file)" 2>/dev/null; then printf 'runbook'; else printf 'none'; fi
        return 0
    fi
    if [ "$(n1_config_val '.delivery.mode')" != "ssh" ]; then printf 'none'; return 0; fi
    if [ -n "${N1_QUEUE_RUN_ID:-}" ] || [ "${N1_HEADLESS:-}" = "1" ]; then printf 'runbook'; return 0; fi
    printf 'execute'
}

n1_delivery_skip() {
    # N1-531. Reads the merged PR's changed paths (one per line) on stdin; prints skip | deliver.
    # skip only when jq is available, .delivery.skipPaths is an array with at least one
    # non-empty string glob, stdin holds at least one path, and every path matches a glob.
    # Globs use bash case semantics (as lib/rules.sh): * also matches /; a glob ending in /
    # is a directory prefix (docs/ -> docs/*). Anything else fails safe to deliver.
    local f paths globs path glob hit n=0
    paths=$(cat)
    f=$(n1_config_file)
    if ! command -v jq >/dev/null 2>&1 || [ ! -f "$f" ]; then printf 'deliver'; return 0; fi
    # || globs="": jq exits non-zero on malformed config or a non-object .delivery; under set -e that must not abort
    globs=$(jq -r '.delivery.skipPaths | if type == "array" then .[] | strings | select(length > 0) else empty end' "$f" 2>/dev/null) || globs=""
    if [ -z "$globs" ]; then printf 'deliver'; return 0; fi
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        n=$((n+1)); hit=0
        while IFS= read -r glob; do
            glob="${glob#./}"   # gh file paths never start with ./
            case "$glob" in */) glob="$glob*" ;; esac
            # shellcheck disable=SC2254
            case "$path" in $glob) hit=1; break ;; esac
        done <<< "$globs"
        if [ "$hit" -eq 0 ]; then printf 'deliver'; return 0; fi
    done <<< "$paths"
    if [ "$n" -gt 0 ]; then printf 'skip'; else printf 'deliver'; fi
}

n1_delivery_is_multi_step() {
    # NP-240. Prints true when delivery is an ordered delivery.steps list (an array, even an
    # empty one) and delivery.command is empty; false otherwise. command wins when both are
    # set: a hand-edited dual config degrades to the older single-command path.
    # Needs jq; prints false without it (n1_delivery_action already forces runbook then).
    local f
    f=$(n1_config_file)
    if ! command -v jq >/dev/null 2>&1 || [ ! -f "$f" ]; then printf 'false'; return 0; fi
    jq -r 'if ((.delivery.command // "") == "") and ((.delivery.steps | type) == "array")
           then "true" else "false" end' "$f" 2>/dev/null || printf 'false'
}

n1_delivery_step() {
    # NP-240. Usage: n1_delivery_step <index> <cmd-file>
    # Classifies delivery.steps[index] with the references/deployment-actions.md grammar:
    # "Manual:" prefix -> manual; starts with a backtick, exactly two backticks, non-empty
    # command -> shell; anything else -> manual. Line 1: shell | manual | end; lines 2+:
    # the item text. shell writes the extracted command to <cmd-file> so the bytes shown and
    # the bytes run are identical. NEVER executes anything. Needs jq (execute branch only).
    local idx="$1" out="$2" f n item nbt cmd=""
    rm -f "$out"
    case "$idx" in ''|*[!0-9]*) printf 'end\n'; return 0 ;; esac
    if [ "$(n1_delivery_is_multi_step)" != "true" ]; then printf 'end\n'; return 0; fi
    f=$(n1_config_file)
    n=$(jq -r '.delivery.steps | length' "$f" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$idx" -ge "$n" ]; then printf 'end\n'; return 0; fi
    item=$(jq -r --argjson i "$idx" '.delivery.steps[$i] | if type == "string" then . else tojson end' "$f" 2>/dev/null)
    nbt=$(printf '%s' "$item" | tr -dc '`' | wc -c)
    case "$item" in
        'Manual:'*) ;;
        '`'*) if [ "$nbt" -eq 2 ]; then cmd=$(printf '%s' "$item" | awk -F'`' '{ printf "%s", $2 }'); fi ;;
    esac
    if [ -n "$cmd" ]; then
        printf '%s' "$cmd" > "$out"
        printf 'shell\n%s\n' "$item"
    else
        printf 'manual\n%s\n' "$item"
    fi
}

n1_delivery_runbook() {
    # NP-219. Usage: n1_delivery_runbook <ID> [merge-sha] [first-step]
    # Writes $N1_HOME/memory/<ID>/runbook.md with the configured deploy/verify commands and
    # sets overview.md deploy_pending: true (+ deploy_merge_sha when the merge already
    # happened, so `n1-finish <ID>` skips straight to the deploy). NEVER executes either
    # command. Prints the runbook path. Needs frontmatter.sh (loaded by the preamble).
    # NP-240: with delivery.steps, lists the steps from index <first-step> (default 0) and
    # records it as overview deploy_next_step, so a resumed walk starts there and steps
    # that already ran are never offered again.
    local id="$1" sha="${2:-}" first="${3:-0}" dir ov cmd verify multi
    case "$first" in ''|*[!0-9]*) first=0 ;; esac
    dir="$N1_HOME/memory/$id"; ov="$dir/overview.md"
    mkdir -p "$dir"
    cmd=$(n1_config_val '.delivery.command')
    verify=$(n1_config_val '.delivery.verifyCommand')
    multi=$(n1_delivery_is_multi_step)
    {
        printf '# Deploy runbook: %s\n\n' "$id"
        if [ -n "$sha" ]; then
            printf 'Merged at `%s`. The deploy is pending.\n\n' "$sha"
        else
            printf 'Not merged yet. `n1-finish %s` confirms (or performs) the merge first, then deploys.\n\n' "$id"
        fi
        if [ "$multi" = "true" ]; then
            printf 'Run interactively: `n1-finish %s`. It asks before each step, starting at step %s, runs the verify command, and closes the ticket on success.\n\n' "$id" "$((first + 1))"
            printf 'Deploy steps (`Manual:` steps are done by hand; the others are shell commands):\n\n'
            jq -r --argjson f "$first" '.delivery.steps | to_entries[] | select(.key >= $f)
                | "\(.key + 1). \(.value | if type == "string" then . else tojson end)"' "$(n1_config_file)" 2>/dev/null
        else
            printf 'Run interactively: `n1-finish %s`. It asks to confirm, runs the deploy, runs the verify command, and closes the ticket on success.\n\n' "$id"
            if [ -n "$cmd" ]; then
                printf 'Deploy command:\n\n```\n%s\n```\n' "$cmd"
            else
                printf 'Deploy: not rendered here (jq is unavailable or delivery has no command). See `delivery` in the N1 config.json.\n'
            fi
        fi
        if [ -n "$verify" ]; then
            printf '\nVerify command:\n\n```\n%s\n```\n' "$verify"
        fi
    } > "$dir/runbook.md"
    if [ ! -f "$ov" ]; then printf -- '---\n---\n' > "$ov"; fi
    n1_write_frontmatter "$ov" deploy_pending true
    if [ -n "$sha" ]; then n1_write_frontmatter "$ov" deploy_merge_sha "$sha"; fi
    if [ "$multi" = "true" ]; then n1_write_frontmatter "$ov" deploy_next_step "$first"; fi
    printf '%s\n' "$dir/runbook.md"
}

n1_delivery_covered() {
    # N1-528. Usage: n1_delivery_covered <sha> [exclude-id]
    # Lists other tickets whose pending deploy shipped with the delivery of <sha>: overview.md has
    # deploy_pending: true and a deploy_merge_sha that resolves to a commit in the CURRENT repo and is an
    # ancestor of (or equal to) <sha> whose commit message names <ID> (ticket binding). One line per ticket: "<ID> <merge-sha> ok", or "<ID> <merge-sha> actions"
    # when memory/<ID>/runbook.md still has an unticked row under "## Deployment Actions" (never close those).
    # Skips <exclude-id>, archived "-old" dirs and IDs outside [A-Za-z0-9_-]. Fails closed: invalid or unknown
    # <sha>, no git repo or no N1_HOME print nothing; a SHA from another repo in a shared N1_HOME never resolves.
    # Pure: reads only, writes nothing (N1-529 may call it from the session-start hook). Always rc 0.
    local x="${1:-}" ex="${2:-}" ov id sha rb msg
    [ -n "${N1_HOME:-}" ] || return 0
    [[ "$x" =~ ^[0-9a-f]{7,40}$ ]] || return 0
    git cat-file -e "$x^{commit}" 2>/dev/null || return 0
    for ov in "$N1_HOME"/memory/*/overview.md; do
        [ -f "$ov" ] || continue
        id="${ov%/overview.md}"; id="${id##*/}"
        case "$id" in ''|*-old|*[!A-Za-z0-9_-]*) continue ;; esac
        [ "$id" = "$ex" ] && continue
        [ "$(n1_read_frontmatter "$ov" deploy_pending)" = true ] || continue
        sha=$(n1_read_frontmatter "$ov" deploy_merge_sha)
        [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || continue
        git cat-file -e "$sha^{commit}" 2>/dev/null || continue
        git merge-base --is-ancestor "$sha" "$x" 2>/dev/null || continue
        # Bind to identity: the merge commit must name this ticket (hand-edited or foreign overviews fail closed).
        msg=$(git log -1 --format=%B "$sha^{commit}" 2>/dev/null) || continue
        [[ "$msg" =~ ^$id([^A-Za-z0-9_-]|$) || "$msg" =~ [^A-Za-z0-9_-]$id([^A-Za-z0-9_-]|$) ]] || continue
        rb="${ov%overview.md}runbook.md"
        if [ -f "$rb" ] && awk '/^## / { s = ($0 ~ /^## Deployment Actions\r?$/) } s && /^- \[ \] / { f = 1; exit } END { exit !f }' "$rb"; then
            printf '%s %s actions\n' "$id" "$sha"
        else
            printf '%s %s ok\n' "$id" "$sha"
        fi
    done
    return 0
}

n1_review_narrow_threshold() {
    # Prints integer. Default: 50.
    local v; v=$(n1_config_val '.review.narrowThreshold')
    printf '%s' "${v:-50}"
}

n1_review_skip_doc_config() {
    # Prints true/false. Default: true.
    # n1_config_val (NP-213) already null-checks and distinguishes explicit false from
    # absent; this local jq call is kept for the tri-state "absent" fallback text below.
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r 'if .review.skipDocConfigOnly == null then "absent" else (.review.skipDocConfigOnly | tostring) end' "$file" 2>/dev/null || true)
        [ "$v" = "false" ] && { printf 'false'; return; }
        [ "$v" = "true" ] && { printf 'true'; return; }
    fi
    printf 'true'
}

n1_compose_file() {
    # Usage: n1_compose_file [dir]. Prints the first matching root compose filename and returns 0,
    # or prints nothing and returns 1. Single source of truth for the compose-name list (NP-222) --
    # n1_resolve_local_testing_mode, n1_detect_start_command, hooks/session-start.sh's enable offer,
    # and n1-init step 08 all call this instead of each keeping their own copy of the list.
    local dir="${1:-.}" f
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [ -f "$dir/$f" ]; then printf '%s' "$f"; return 0; fi
    done
    return 1
}

n1_resolve_local_testing_mode() {
    # Usage: n1_resolve_local_testing_mode [repo_dir]
    # Prints live, smoke or none (N1-559 removed mode "test"). Precedence: explicit localTesting.mode
    # "live"/"smoke" > localTesting.autoLive=true + root compose file -> live > startCommand set -> live
    # > none. Any other explicit mode value (legacy "test") is ignored as if unset.
    local dir="${1:-.}" mode
    mode=$(n1_config_val '.localTesting.mode')
    case "$mode" in live|smoke) printf '%s' "$mode"; return 0 ;; esac
    if [ "$(n1_config_val '.localTesting.autoLive')" = "true" ] && n1_compose_file "$dir" >/dev/null; then
        printf 'live'; return 0
    fi
    if [ -n "$(n1_config_val '.localTesting.startCommand')" ]; then printf 'live'; return 0; fi
    printf 'none'
}

n1_detect_start_command() {
    # Usage: n1_detect_start_command [dir]. Prints the suggested local start command and returns 0, or
    # prints nothing and returns 1. Code form of n1-init step 08's Startup Detection table (N1-559),
    # highest priority first: root compose file, Makefile up/run/serve/start/dev target, package.json
    # dev then start script (needs jq), manage.py, Procfile web: line (else heroku local).
    local dir="${1:-.}" t
    if n1_compose_file "$dir" >/dev/null; then printf 'docker compose up -d'; return 0; fi
    if [ -f "$dir/Makefile" ]; then
        t=$(grep -m1 -oE '^(up|run|serve|start|dev):' "$dir/Makefile" | tr -d ':')
        if [ -n "$t" ]; then printf 'make %s' "$t"; return 0; fi
    fi
    if [ -f "$dir/package.json" ] && command -v jq >/dev/null 2>&1; then
        t=$(jq -r '.scripts // {} | if .dev then "npm run dev" elif .start then "npm start" else empty end' "$dir/package.json" 2>/dev/null)
        if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
    fi
    if [ -f "$dir/manage.py" ]; then printf 'python manage.py runserver'; return 0; fi
    if [ -f "$dir/Procfile" ]; then
        t=$(sed -n 's/^web:[[:space:]]*//p' "$dir/Procfile" | head -1)
        printf '%s' "${t:-heroku local}"; return 0
    fi
    return 1
}

n1_local_testing_offer() {
    # Usage: n1_local_testing_offer [dir]. N1-559: decides the attended n1-start live-testing offer.
    # Prints "compose" (root compose file) or "start:<cmd>" (other detected start script) when
    # localTesting.enabled is not false, the resolved mode is none and localTesting.autoLive is absent
    # (an explicit false means declined: never asked again). Prints nothing otherwise, and also when the
    # config file is absent or jq is missing (n1_local_testing_offer_write could not persist an answer).
    # The <cmd> text is for display only: never paste it into a shell literal. Always returns 0.
    local dir="${1:-.}" cmd f
    f=$(n1_config_file)
    { [ -f "$f" ] && command -v jq >/dev/null 2>&1; } || return 0
    [ "$(n1_config_val '.localTesting.enabled')" != "false" ] || return 0
    [ "$(n1_resolve_local_testing_mode "$dir")" = "none" ] || return 0
    [ -z "$(n1_config_val '.localTesting.autoLive')" ] || return 0
    cmd=$(n1_detect_start_command "$dir") || return 0
    if n1_compose_file "$dir" >/dev/null; then printf 'compose'; else printf 'start:%s' "$cmd"; fi
}

n1_local_testing_offer_write() {
    # Usage: n1_local_testing_offer_write <compose|start|start-stdin|no> [dir]. N1-559: persists the offer
    # answer. compose -> autoLive=true; start -> startCommand=<n1_detect_start_command [dir]>;
    # start-stdin -> startCommand=<stdin> (user-edited command, passed through a quoted heredoc so
    # repo- or user-derived text is never pasted into a shell literal); compose/start/start-stdin delete
    # a legacy mode "test". no -> autoLive=false. Returns 1 (config untouched) in headless runs, without
    # jq or config, on a bad answer, an empty command or one with control characters, or a failed write.
    local f filter cmd="" tmp drop='| if .localTesting.mode == "test" then del(.localTesting.mode) else . end'
    [ "${N1_HEADLESS:-}" = 1 ] && return 1
    f=$(n1_config_file)
    { [ -f "$f" ] && command -v jq >/dev/null 2>&1; } || return 1
    case "$1" in
        no) filter='.localTesting.autoLive = false' ;;
        compose) filter=".localTesting.autoLive = true $drop" ;;
        start|start-stdin)
            if [ "$1" = start ]; then cmd=$(n1_detect_start_command "${2:-.}") || return 1; else cmd=$(cat); fi
            cmd="${cmd%$'\r'}"
            [[ -n "$cmd" && ! "$cmd" =~ [[:cntrl:]] ]] || return 1
            filter=".localTesting.startCommand = \$cmd $drop" ;;
        *) return 1 ;;
    esac
    tmp="$f.tmp"
    # Write a tmp file with the original mode, then rename over the config: readers never see a partial file.
    if cp -p "$f" "$tmp" && jq --arg cmd "$cmd" "$filter" "$f" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"; return 1
    fi
}

n1_copy_worktree_files() {
    # Usage: n1_copy_worktree_files <main_checkout> <worktree_path>
    # Copies each worktree.copyFiles entry (relative file path, e.g. ".env") from the main
    # checkout into a new worktree. Copies only when the destination is missing and the path is
    # git-ignored in the worktree (so it can never be committed). Rejects absolute paths and
    # '..' segments (config is user-authored, but an escape would write outside the worktree).
    # Missing sources are skipped. Prints the number of files copied; always returns 0.
    local src="$1" dst="$2" file f n=0
    file=$(n1_config_file)
    if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then printf '0'; return 0; fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            /*|[A-Za-z]:*) echo "N1: worktree.copyFiles entry rejected (absolute path): $f" >&2; continue ;;
        esac
        case "/$f/" in
            */../*) echo "N1: worktree.copyFiles entry rejected ('..' segment): $f" >&2; continue ;;
        esac
        [ -e "$dst/$f" ] && continue
        [ -f "$src/$f" ] || continue
        if ! git -C "$dst" check-ignore -q -- "$f" 2>/dev/null; then
            echo "N1: worktree.copyFiles entry skipped (not git-ignored in worktree): $f" >&2
            continue
        fi
        mkdir -p "$(dirname "$dst/$f")" && cp -p "$src/$f" "$dst/$f" && n=$((n + 1))
    done < <(jq -r '.worktree.copyFiles // [] | .[]? | strings' "$file" 2>/dev/null)
    printf '%s' "$n"
}

n1_cross_host_review_val() {
    # Usage: n1_cross_host_review_val <key>
    # Keys: enabled, autoTriage, maxFixAttempts
    # Defaults: enabled=true, autoTriage=true (explicit false opts out, N1-94), maxFixAttempts=1
    local key="$1"
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r --arg k "$key" 'if .crossHostReview[$k] == null then "absent" else (.crossHostReview[$k] | tostring) end' "$file" 2>/dev/null || true)
        if [ "$v" != "absent" ]; then printf '%s' "$v"; return; fi
    else
        local v; v=$(n1_config_val ".crossHostReview.${key}")
        if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    fi
    case "$key" in
        enabled)          printf 'true' ;;
        autoTriage)       printf 'true' ;;
        maxFixAttempts)   printf '1' ;;
        *)                printf '' ;;
    esac
}

n1_review_fix_gate() {
    # Usage: n1_review_fix_gate <overview.md> -> prints allow|exhausted; returns 1 when exhausted (N1-211, N1-569).
    # Budget: review.maxFixAttempts (default 3 = pipeline.json review_fix max_default) FAIL fix cycles. Cycle 1 always
    # runs; a later cycle only on progress (_n1_fix_progress over the files beside overview.md). Appends
    # {"cycle":<cur+1>,"decision":"allow|deny","reason":"<r>"} to fix-gate.jsonl beside overview.md unless review.md
    # there opens `### Verdict: PASS` (SOFT-ONLY entry). Reasons: first, progress | cap, counter, no-data, no-progress,
    # carried, contract. Needs n1_read_frontmatter (lib/frontmatter.sh; loaded by the preamble via step.sh).
    local dir max cur reason d
    dir=$(dirname "$1")
    max=$(n1_config_val '.review.maxFixAttempts'); [[ "$max" =~ ^[0-9]{1,9}$ ]] || max=3
    cur=$(n1_read_frontmatter "$1" review_fix_cycle); cur=${cur:-0}
    if ! [[ "$cur" =~ ^[0-9]{1,9}$ ]]; then reason=counter; cur=0   # garbage counter fails closed
    else
        cur=$((10#$cur)); max=$((10#$max))
        if [ "$cur" -ge "$max" ]; then reason=cap
        elif [ "$cur" -eq 0 ]; then reason=first
        else reason=$(_n1_fix_progress "$dir" "$cur"); fi
    fi
    case "$reason" in first|progress) d=allow ;; *) d=deny ;; esac
    head -n 1 "$dir/review.md" 2>/dev/null | grep -q '^### Verdict: PASS' \
        || printf '{"cycle":%s,"decision":"%s","reason":"%s"}\n' "$((cur + 1))" "$d" "$reason" >> "$dir/fix-gate.jsonl" 2>/dev/null || true
    if [ "$d" = allow ]; then echo allow; else echo exhausted; return 1; fi
}

_n1_fix_progress() {
    # Usage: _n1_fix_progress <memory dir> <cycle> -> prints progress|no-progress|carried|no-data|contract (N1-569).
    # Reads the n1_fix_states rows of bucket <cycle> in fingerprints.jsonl and the contract-miss line in fix-gate.jsonl.
    # carried wins over progress: a blocking finding open after two fix cycles (age >= 2) stops the loop.
    local rows
    grep -qxF "{\"cycle\":$2,\"contract\":\"missing\"}" "$1/fix-gate.jsonl" 2>/dev/null && { echo contract; return; }
    rows=$(grep -E "\"status\":\"(resolved|withdrawn|downgraded|oos|carried|new)\",\"cycle\":$2," "$1/fingerprints.jsonl" 2>/dev/null)
    [ -n "$rows" ] || { echo no-data; return; }
    if grep -qE '"status":"carried","cycle":[0-9]+,"age":([2-9]|[1-9][0-9]+),' <<< "$rows"; then echo carried
    elif grep -qE '"status":"(resolved|withdrawn|downgraded|oos)"' <<< "$rows"; then echo progress
    else echo no-progress; fi
}

n1_review_fix_audit() {
    # Usage: n1_review_fix_audit <overview.md> -> prints ok|breach; returns 1 on breach (N1-260, N1-569).
    # Breach: review_fix_cycle above review.maxFixAttempts (default 3) with fewer extension rows than cycles over it.
    # An extension row sits in `## Decision Ledger`: step fix, tag [asked] ([plan] = queue plan time), Question
    # `review fix cap reached`, Chosen option 2 (`2` or `One more FAIL fix cycle`). Nothing else counts.
    local max cur n re='^[|] fix [|] [^|]* [|] [^|]* [|] \[(asked|plan)\] [|] review fix cap reached [|] (2|One more FAIL fix cycle) [|]'
    max=$(n1_config_val '.review.maxFixAttempts'); [[ "$max" =~ ^[0-9]{1,9}$ ]] || max=3
    cur=$(n1_read_frontmatter "$1" review_fix_cycle); cur=${cur:-0}
    [[ "$cur" =~ ^[0-9]{1,9}$ ]] || { echo breach; return 1; }  # garbage or >9-digit counter (64-bit wrap) fails closed
    cur=$((10#$cur)); max=$((10#$max))  # decimal: 08/09 are not octal
    if [ "$cur" -le "$max" ]; then echo ok; return 0; fi
    n=$(_n1_ledger_count "$1" "$re")
    if [ "$n" -ge $((cur - max)) ]; then echo ok; else echo breach; return 1; fi
}

_n1_ledger_count() {
    # Usage: _n1_ledger_count <overview.md> <ERE> -> count of `## Decision Ledger` lines matching <ERE>.
    local line in_l=0 n=0
    [ -r "$1" ] || { echo 0; return; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '## Decision Ledger'*) in_l=1; continue ;; '## '*) in_l=0; continue ;; esac
        if [ "$in_l" = 1 ] && [[ "$line" =~ $2 ]]; then n=$((n + 1)); fi
    done < "$1"
    echo "$n"
}

n1_review_fix_outcome() {
    # Usage: n1_review_fix_outcome <memory dir> -> one-line JSON for n1_step_end "fix" (N1-569, D9):
    # {"gate":[fix-gate.jsonl lines],"states":[{"cycle":N,"<state>":["ID",...]},...]} from fingerprints.jsonl state rows.
    # Built by jq from files only; unparsable lines are skipped; prints {} when jq is missing.
    local m="$1" g f
    command -v jq >/dev/null 2>&1 || { printf '{}'; return 0; }
    g=$(cat "$m/fix-gate.jsonl" 2>/dev/null | jq -scR '[splits("\n") | select(length > 0) | fromjson? | select(type == "object")]') || g='[]'
    f=$(cat "$m/fingerprints.jsonl" 2>/dev/null | jq -scR '[splits("\n") | select(length > 0) | fromjson? | select(type == "object")
        | select((.status // "") | test("^(resolved|withdrawn|downgraded|oos|carried|new)$"))]
        | group_by(.cycle) | map({cycle: .[0].cycle} + (group_by(.status) | map({(.[0].status): map(.id)}) | add))') || f='[]'
    jq -cn --argjson g "${g:-[]}" --argjson f "${f:-[]}" '{gate: $g, states: $f}' 2>/dev/null || printf '{}'
}

n1_escalation_val() {
    # Usage: n1_escalation_val alwaysAskOn -- fixed stop list (N1-113).
    case "$1" in
        alwaysAskOn)  printf '["security","architecture","public-api"]' ;;
        *)            printf '' ;;
    esac
}

# Detect if running inside a linked git worktree NOT managed by N1.
# Returns 0 (true) when: git-dir diverges from git-common-dir (linked worktree)
# AND the worktree toplevel is NOT under the host worktree root (n1_worktree_root).
# Returns 1 (false) otherwise.
n1_is_external_worktree() {
    local git_dir git_common_dir toplevel
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    # Resolve to absolute paths for reliable comparison
    git_dir=$(cd "$git_dir" && pwd -P)
    git_common_dir=$(cd "$git_common_dir" && pwd -P)
    # Not a linked worktree — git-dir and git-common-dir are the same
    [ "$git_dir" != "$git_common_dir" ] || return 1
    # It is a linked worktree — check if N1-managed
    toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    # Under the host's N1 worktree root → N1-managed
    local wt_root; wt_root=$(n1_worktree_root)
    case "$toplevel" in
        */"${wt_root}"/*) return 1 ;;
    esac
    # Linked worktree, not under the host worktree root — external
    return 0
}

# N1-224: <ID> occurs in <text> as a whole token (case-insensitive; N1-22 does not match N1-224).
_n1_id_in() {
    local id t
    id=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'); t=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
    [ -n "$id" ] || return 1
    case "$t" in "$id"|"$id"[!a-z0-9]*|*[!a-z0-9]"$id"|*[!a-z0-9]"$id"[!a-z0-9]*) return 0 ;; esac
    return 1
}

# N1-291: n1_story_base — the story child's integration branch (story/<ID>, or N1-446 queue/<ID> for a list/tag queue
# with integration: queue; no origin/), validated; prints nothing for a non-integration run. The queue runner sets
# N1_STORY_BRANCH/N1_STORY_ID on integration children only. rc 2 (stderr) when the branch is set but invalid or is
# neither story/$N1_STORY_ID nor queue/$N1_STORY_ID, or when a queue child carries N1_STORY_ID without a branch: an
# integration child never falls back to the default branch. The runner (story_env) pins the prefix to its run mode.
# Callers: SB=$(n1_story_base) || exit 1.
n1_story_base() {
    local b="${N1_STORY_BRANCH:-}" id="${N1_STORY_ID:-}"
    if [ -z "$b" ]; then
        if [ -n "$id" ] && [ -n "${N1_QUEUE_RUN_ID:-}" ]; then
            printf 'n1_story_base: queue story child %s has no N1_STORY_BRANCH\n' "$id" >&2; return 2
        fi
        return 0
    fi
    if ! [[ "$b" =~ ^(story|queue)/[A-Za-z0-9._-]+$ ]] || [[ "$b" == *..* ]] \
        || ! git check-ref-format --branch "$b" >/dev/null 2>&1 \
        || { [ -n "$id" ] && [ "$b" != "story/$id" ] && [ "$b" != "queue/$id" ]; }; then
        printf 'n1_story_base: invalid story branch %s\n' "$b" >&2; return 2
    fi
    printf '%s' "$b"
}

# N1-224 Gap 1 (applies with or without Orca): does this linked worktree belong to <ID>?
# Usage: n1_worktree_owned <ID> — rc 0 owned, 1 not owned, 2 not a linked worktree (main checkout / no repo).
# Owned when ANY: folder basename or Orca display name equals <ID>; branch contains <ID> (never a spike/* branch); no commits ahead of
# origin/<default> and a clean working tree (fallback: local <default>; neither = unknown = not owned); overview workspace_path or this
# session's active-run worktreePath is this toplevel.
n1_worktree_owned() {
    local id="${1:-}" gd gcd top lid def base="" wp ar st br
    gd=$(cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 2
    gcd=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 2
    [ "$gd" != "$gcd" ] || return 2
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 2
    [ -n "$id" ] || return 1
    lid=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
    [ "$(printf '%s' "${top##*/}" | tr '[:upper:]' '[:lower:]')" = "$lid" ] && return 0
    [ "$(n1_orca_display_name "$top" | tr '[:upper:]' '[:lower:]')" = "$lid" ] && return 0
    # N1-577: a kept spike/<ID> worktree (push failed) is never the ticket's implementation workspace.
    br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    case "$br" in spike/*) ;; *) _n1_id_in "$id" "$br" && return 0 ;; esac
    def=$(n1_config_val '.git.defaultBranch' 2>/dev/null); def="${def:-main}"
    if git rev-parse -q --verify "refs/remotes/origin/$def" >/dev/null 2>&1; then base="origin/$def"
    elif git rev-parse -q --verify "refs/heads/$def" >/dev/null 2>&1; then base="$def"; fi
    # Empty-workspace shortcut needs a clean tree (another ticket's fresh worktree may hold uncommitted work).
    [ -n "$base" ] && [ "$(git rev-list --count "$base..HEAD" 2>/dev/null)" = 0 ] \
        && st=$(git status --porcelain 2>/dev/null) && [ -z "$st" ] && return 0
    wp=$(sed -n 's/^workspace_path: *//p' "$(n1_home)/memory/$id/overview.md" 2>/dev/null | head -1)
    [ -n "$wp" ] && [ "$wp" = "$top" ] && return 0
    ar=$(n1_active_run_file 2>/dev/null) && [ -f "$ar" ] && command -v jq >/dev/null 2>&1 \
        && [ "$(jq -r '.ticketId // empty' "$ar" 2>/dev/null)" = "$id" ] \
        && [ "$(jq -r '.worktreePath // empty' "$ar" 2>/dev/null)" = "$top" ] && return 0
    return 1
}

# N1-224 Gap 2: existing linked worktree for <ID>, in order: overview workspace_path; Orca `reference find`
# and `worktree list` by folder/display name (Orca active only); `git worktree list` by folder or branch.
# Usage: n1_find_workspace <ID> — prints the path, or nothing. Never returns the main checkout.
n1_find_workspace() {
    local id="${1:-}" lid list main wp p b
    [ -n "$id" ] || return 0
    lid=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
    list=$(git worktree list --porcelain 2>/dev/null) || return 0
    main=$(sed -n '1s/^worktree //p' <<<"$list")
    wp=$(sed -n 's/^workspace_path: *//p' "$(n1_home)/memory/$id/overview.md" 2>/dev/null | head -1)
    if [ -n "$wp" ] && [ "$wp" != "$main" ] && [ -d "$wp" ] && grep -qxF "worktree $wp" <<<"$list"; then printf '%s\n' "$wp"; return 0; fi
    if n1_orca_active; then
        p=$(n1_orca reference find "$id" | jq -r 'first(.result | .. | objects | .path? | strings) // empty' 2>/dev/null)
        # N1-224 SEC-2: the lookup may be fuzzy; accept only a folder named <ID>, else fall through to the exact name match.
        [ "$(printf '%s' "${p##*/}" | tr '[:upper:]' '[:lower:]')" = "$lid" ] || p=""
        [ -n "$p" ] || p=$(n1_orca worktree list | jq -r --arg l "$lid" 'first(.result.worktrees[]? | select(.isMainWorktree != true)
            | select((.path | split("/") | last | ascii_downcase) == $l or ((.displayName // "") | ascii_downcase) == $l) | .path) // empty' 2>/dev/null)
        if [ -n "$p" ] && [ "$p" != "$main" ] && [ -d "$p" ] && grep -qxF "worktree $p" <<<"$list"; then printf '%s\n' "$p"; return 0; fi
    fi
    while IFS=$'\t' read -r p b; do
        [ -d "$p" ] || continue
        case "$b" in spike/*) continue ;; esac  # N1-577: spike worktrees are never ticket work
        if [ "$(printf '%s' "${p##*/}" | tr '[:upper:]' '[:lower:]')" = "$lid" ] || _n1_id_in "$id" "$b"; then printf '%s\n' "$p"; return 0; fi
    done < <(awk '/^worktree /{p=substr($0,10)} /^branch /{b=substr($0,19)} /^$/{print p "\t" b; p=""; b=""} END{if(p!="")print p "\t" b}' <<<"$list" | tail -n +2)
    return 0
}

# N1-224 workspace decision for n1-start. Prints exactly one token:
#   stay <path> | ask <path> <branch> | reuse <path> | handoff-launch <path> | handoff-create | create-local
# Handoff only when: Orca active, not headless, not a queue child, no --no-handoff; handoff-launch only for an
# Orca-registered path. --elsewhere skips the ownership check (the user chose a separate workspace).
# Usage: n1_workspace_decide <ID> [--no-handoff] [--elsewhere]
n1_workspace_decide() {
    local id="${1:-}" nh="" el="" a rc=0 top found can=""
    [ $# -gt 0 ] && shift
    for a in "$@"; do case "$a" in --no-handoff) nh=1 ;; --elsewhere) el=1 ;; esac; done
    if [ -z "$el" ]; then
        n1_worktree_owned "$id" || rc=$?
        top=$(git rev-parse --show-toplevel 2>/dev/null)
        case "$rc" in
            0) echo "stay $top"; return 0 ;;
            1) echo "ask $top $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; return 0 ;;
        esac
    fi
    [ -z "$nh" ] && [ "${N1_HEADLESS:-}" != 1 ] && [ -z "${N1_QUEUE_RUN_ID:-}" ] && n1_orca_active && can=1
    found=$(n1_find_workspace "$id")
    if [ -n "$found" ]; then
        if [ -n "$can" ] && n1_orca_owns "$found"; then echo "handoff-launch $found"; else echo "reuse $found"; fi
    elif [ -n "$can" ]; then echo handoff-create
    else echo create-local; fi
    return 0
}

# N1-339: "<path>\t<branch ref or empty>" per worktree from git porcelain, main checkout first.
_n1_wt_records() {
    git worktree list --porcelain 2>/dev/null | awk '/^worktree /{p=substr($0,10)} /^branch /{b=substr($0,8)} /^$/{print p "\t" b; p=""; b=""} END{if(p!="")print p "\t" b}'
}

# N1-339: path of the worktree (main checkout included) holding refs/heads/<branch>, or nothing. A worktree holds its
# branch exclusively, so this exact match can never select another ticket's tree.
_n1_wt_holder() {
    [ -n "${1:-}" ] || return 0
    _n1_wt_records | B="refs/heads/$1" awk -F'\t' '$2 == ENVIRON["B"] {print $1; exit}'
    return 0
}

# N1-339: removal gate for linked worktree <top>. Prints "<mode>\t<keep>": mode orca (Orca-owned, via n1_orca_rm, never
# forced, ignored files do not block) | force (under <main>/<worktree_root>, not Orca-owned, no gates; finish trigger only)
# | managed (same tree, but <nof>=1: gated like plain, ignored files do not block, never forced) | plain (external, never
# forced). keep is empty or dirty | ignored files | unmerged | orca-unreachable (Orca CLI installed, runtime down: ownership
# unknown, so no plain-git removal behind Orca's back).
_n1_clean_gate() {
    local top="$1" main="$2" oid="$3" def="$4" nof="${5:-}" mode=plain keep="" st
    if n1_orca_owns "$top"; then mode=orca
    else
        case "$top" in "$main/$(n1_worktree_root)"/*) mode=force; [ "$nof" = 1 ] && mode=managed ;; esac
        [ -n "${ORCA_CLI_COMMAND:-}" ] && [ -x "$ORCA_CLI_COMMAND" ] && ! n1_orca_active && keep="orca-unreachable"
    fi
    if [ -z "$keep" ] && [ "$mode" != force ]; then
        if ! st=$(git -C "$top" status --porcelain --ignored 2>/dev/null) || [ -n "$(grep -v '^!!' <<<"$st")" ]; then keep="dirty"
        elif [ -n "$st" ] && [ "$mode" = plain ]; then keep="ignored files"
        elif ! git -C "$top" merge-base --is-ancestor HEAD "${oid:-refs/heads/$def}" 2>/dev/null; then keep="unmerged"; fi
    fi
    printf '%s\t%s\n' "$mode" "$keep"
}

# N1-112/N1-339: worktree + local-branch cleanup for a merged ticket; prints status tokens, one per line, always returns 0.
# Usage: n1_finish_cleanup <branch> <merged-pr-head-oid|""> <defaultBranch> [<nof>] [<top>]   (any cwd inside the repository)
# <top> (N1-583): a registered linked worktree to gate and remove instead of the <branch> holder (detached or re-branched
# trees located by overview workspace_path); the main checkout or an unregistered path means no worktree.
# <nof>=1 (every trigger but finish): N1-managed trees are gated (dirty, unmerged) and never removed with --force.
# The worktree is the linked one holding refs/heads/<branch> (never the main checkout, never chosen by cwd); it goes
# first because a checked-out branch cannot be deleted. Gates: _n1_clean_gate. Branch: tip must be an ancestor of the
# merged result (oid, else <defaultBranch>), then -d; -D only when the tip equals the merged PR head oid (squash/rebase).
# When the cwd's worktree was removed the shell is left in the main checkout.
n1_finish_cleanup() {
    local branch="${1:-}" oid="${2:-}" def="${3:-}" nof="${4:-}" want="${5:-}"
    local gcd main top err mode="" keep="" holder
    gcd=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) \
        && main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') && [ -n "$main" ] \
        || { echo worktree:none; echo branch:none; return 0; }
    local G=(git --git-dir="$gcd")
    if [ -n "$want" ]; then top=$(_n1_wt_records | tail -n +2 | P="$want" awk -F'\t' '$1 == ENVIRON["P"] {print $1; exit}')
    else top=$(_n1_wt_holder "$branch"); fi
    [ "$top" = "$main" ] && top=""
    # A registered worktree whose directory is gone cannot be gated or removed: drop its stale admin entry (locked ones
    # survive the prune and are then named by the branch check below) so the branch can be deleted.
    if [ -n "$top" ] && [ ! -d "$top" ]; then "${G[@]}" worktree prune 2>/dev/null; top=""; fi
    if [ -z "$top" ]; then echo "worktree:none"
    else
        IFS=$'\t' read -r mode keep <<<"$(_n1_clean_gate "$top" "$main" "$oid" "$def" "$nof")"
        if [ -n "$keep" ]; then
            echo "worktree:kept ($keep)"
            [ "$keep" = orca-unreachable ] && echo "n1: worktree not removed: $top: workspace manager unreachable" >&2
        elif [ "$mode" = orca ]; then
            # No git fallback: removing behind Orca's back would desync its state.
            if err=$(cd / && n1_orca_rm "$top"); then echo "worktree:removed"
            else err="${err:-workspace manager error}"; echo "worktree:remove-failed ($err)"; echo "n1: worktree not removed: $top: $err" >&2; fi
        elif err=$(cd / && if [ "$mode" = force ]; then "${G[@]}" worktree remove --force "$top"; else "${G[@]}" worktree remove "$top"; fi 2>&1); then
            echo "worktree:removed"
        else echo "worktree:remove-failed (${err%%$'\n'*})"; fi
    fi
    [ -d "$PWD" ] || cd "$main" 2>/dev/null || true
    holder=$(_n1_wt_holder "$branch")
    if [ -z "$branch" ] || [ "$branch" = "$def" ] || ! "${G[@]}" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then echo "branch:none"
    elif [ -n "$holder" ]; then echo "branch:kept (checked out in $holder)"
    elif ! "${G[@]}" merge-base --is-ancestor "refs/heads/$branch" "${oid:-refs/heads/$def}" >/dev/null 2>&1; then echo "branch:kept (not merged)"
    elif "${G[@]}" branch -d -- "$branch" >/dev/null 2>&1; then echo "branch:deleted"
    elif [ -n "$oid" ] && [ "$("${G[@]}" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)" = "$oid" ] \
        && "${G[@]}" branch -D -- "$branch" >/dev/null 2>&1; then echo "branch:deleted"
    else echo "branch:kept (not merged)"; fi
    return 0
}

# N1-339: record a cleanup outcome. Usage: _n1_clean_record <ID> <trigger> <tokens joined by ", "> <path> <mode>
# Upserts "- **Cleanup:**" as the first line of overview ## Finish (appending a minimal ## Finish when absent; skipped
# results are not written there), rewrites finish-report.md's Cleanup line, emits the cleanup step event (bound run
# only: an unbound run id is never merged) and the queue ticket_cleanup event (queue env only). Best effort, rc 0.
_n1_clean_record() {
    local id="$1" trig="$2" toks="$3" path="$4" mode="$5" mem ov rep tmp outcome wt br reason prev
    mem="$(n1_home)/memory/$id"; ov="$mem/overview.md"; rep="$mem/finish-report.md"
    # A no-op re-run never overwrites an earlier successful record (overview line, or a non-pending report line); a
    # verified no-op does replace an earlier kept / failed / skipped one.
    if [ "$toks" = "worktree:none, branch:none" ]; then
        prev=$(grep '^- \*\*Cleanup:\*\*' "$ov" 2>/dev/null; grep '^Cleanup:' "$rep" 2>/dev/null | grep -v '<pending>')
        [ -n "$prev" ] && ! grep -qE 'kept|remove-failed|cleanup:skipped' <<<"$prev" && return 0
    fi
    case "$toks" in *remove-failed*) outcome=failed ;; worktree:kept*|*branch:kept*|cleanup:skipped*) outcome=skipped ;; *) outcome=success ;; esac
    if [ -f "$ov" ] && [ "${toks#cleanup:skipped}" = "$toks" ] && tmp=$(mktemp "$ov.XXXXXX"); then
        L="- **Cleanup:** $toks${path:+ ($path)}" awk '/^## /{s = /^## Finish\r?$/} s && /^- \*\*Cleanup:\*\*/{next} {print}
            /^## Finish\r?$/{print ENVIRON["L"]; d = 1} END{if (!d) {print ""; print "## Finish"; print ENVIRON["L"]}}' "$ov" > "$tmp" \
            && mv "$tmp" "$ov" || rm -f "$tmp"
        # N1-277: a ## Finish exists now, so the awaiting-merge marker goes (same helper as n1-finish Step 6).
        declare -F n1_pending_clear >/dev/null || source "${BASH_SOURCE[0]%/*}/frontmatter.sh" 2>/dev/null
        n1_pending_clear "$ov" || true
    fi
    if [ -f "$rep" ] && tmp=$(mktemp "$rep.XXXXXX"); then
        L="Cleanup: $toks" awk '/^Cleanup:/{print ENVIRON["L"]; next} {print}' "$rep" > "$tmp" && mv "$tmp" "$rep" || rm -f "$tmp"
    fi
    wt="${toks%%, branch:*}"; br=""; case "$toks" in *", branch:"*) br="branch:${toks##*, branch:}" ;; esac
    reason=$(sed -n 's/^[^(]*(\(.*\))$/\1/p' <<<"$wt")
    if [ -n "${N1_RUN_ID:-}" ]; then
        n1_emit_step_event "$N1_RUN_ID" "${N1_VERSION:-}" "$id" cleanup 18 "$mem/telemetry" outcome="$outcome" completed_at=now \
            metadata="$(jq -cn --arg worktree "$wt" --arg reason "$reason" --arg path "$path" --arg branch "$br" \
                --argjson orca "$([ "$mode" = orca ] && echo true || echo false)" --arg trigger "$trig" --arg cwd "$PWD" \
                '{worktree:$worktree,reason:$reason,path:$path,branch:$branch,orca:$orca,trigger:$trigger,cwd:$cwd}')" 2>/dev/null || true
    fi
    if [ -n "${N1_QUEUE_DIR:-}" ] && [ -n "${N1_QUEUE_RUN_ID:-}" ] && [ -d "$N1_QUEUE_DIR" ]; then
        declare -F n1_queue_event >/dev/null || source "${BASH_SOURCE[0]%/*}/queue.sh" 2>/dev/null
        n1_queue_event "$N1_QUEUE_DIR/events.jsonl" "${N1_QUEUE_DIR##*/}" "$N1_QUEUE_RUN_ID" ticket_cleanup ticket="$id" \
            outcome="$outcome" reason="$toks${path:+; $path}" session="${N1_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}" 2>/dev/null || true
    fi
    return 0
}

# N1-583: "<defaultBranch>\t<sha>" for no-PR merge checks: sha of origin/<def>, else local <def>, else empty.
# <def>: origin/HEAD, else git.defaultBranch, else main. --fetch: best-effort `git fetch origin <def>` first (a failed
# fetch only leaves a stale origin ref, which under-reports). Usage: _n1_nopr_base [--fetch]
_n1_nopr_base() {
    local def sha
    def=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); def="${def#origin/}"
    [ -n "$def" ] || def=$(n1_config_val '.git.defaultBranch' 2>/dev/null); def="${def:-main}"
    [ "${1:-}" = --fetch ] && { GIT_TERMINAL_PROMPT=0 timeout 20 git fetch -q origin "$def" </dev/null >/dev/null 2>&1 || true; }
    sha=$(git rev-parse -q --verify "refs/remotes/origin/$def^{commit}" 2>/dev/null) \
        || sha=$(git rev-parse -q --verify "refs/heads/$def^{commit}" 2>/dev/null) || sha=""
    printf '%s\t%s\n' "$def" "$sha"
}

# N1-339: ticket-keyed cleanup, the one entry point for n1-finish (last action), n1-clean --ticket and n1-clean general mode.
# Usage: n1_clean_ticket <ID> <finish|clean|queue|general|merged-nopr> [<headRef> <oid> <defaultBranch>]
# merged-nopr (N1-583, n1-clean general mode after the user confirmed): no PR; the workspace_path tree is removed when
# clean and its HEAD is an ancestor of origin/<default>; extra skips: no-base | spike | no-workspace.
# finish passes the PR facts it already has (local merge: empty oid). Other triggers read pr_url from overview
# (## Pending or ## Finish), require gh state MERGED and take headRefName/headRefOid/baseRefName from it; anything else
# prints one "cleanup:skipped (<why>)" line and touches nothing. Never cwd: n1_finish_cleanup's exact branch match, else
# (N1-583) the ticket's workspace_path tree from n1_find_workspace, always gated (dirty/unmerged kept, never forced).
# Inside an Orca-owned target the predicted outcome is recorded BEFORE the removal, because Orca's rm
# kills the terminal (and this session) running there; a surviving session overwrites it with the real tokens.
n1_clean_ticket() {
    local id="${1:-}" trig="${2:-clean}" hr="${3:-}" oid="${4:-}" def="${5:-}"
    local url="" res="" st="" a main top="" gate="" out toks b="" nof=1
    [ "$trig" = finish ] && nof=0
    [[ "$id" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || id=""
    if [ "$trig" = merged-nopr ]; then
        [ -n "$id" ] || { echo "cleanup:skipped (invalid-id)"; return 0; }
        IFS=$'\t' read -r def oid <<<"$(_n1_nopr_base)"; hr=""
        [ -n "$oid" ] || { _n1_clean_record "$id" "$trig" "cleanup:skipped (no-base)" "" ""; echo "cleanup:skipped (no-base)"; return 0; }
    elif [ "$trig" != finish ]; then
        [ -n "$id" ] || { echo "cleanup:skipped (invalid-id)"; return 0; }
        url=$(awk '/^## (Pending|Finish)/{f=1;next} /^## /{f=0} f && /^pr_url:/{sub(/^pr_url:[[:space:]]*/,""); print; exit}' "$(n1_home)/memory/$id/overview.md" 2>/dev/null)
        if ! [[ "$url" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$ ]]; then st=no-pr
        else
            for a in 1 2 3; do
                res=$(timeout 30 gh pr view --json state,headRefName,headRefOid,baseRefName -q '[.state,.headRefName,.headRefOid,.baseRefName] | @tsv' -- "$url" </dev/null 2>/dev/null) || res=""
                [ -n "$res" ] && break
                [ "$a" -lt 3 ] && sleep $((a * 2))
            done
            IFS=$'\t' read -r st hr oid def <<<"$res"
            case "$st" in MERGED) st="" ;; "") st=pr-unreadable ;; *) st=pr-not-merged ;; esac
            [[ "$hr" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$def" =~ ^[A-Za-z0-9._/-]+$ ]] || st="${st:-pr-unreadable}"
        fi
        if [ -n "$st" ]; then _n1_clean_record "$id" "$trig" "cleanup:skipped ($st)" "" ""; echo "cleanup:skipped ($st)"; return 0; fi
    fi
    [ -n "$id" ] || { n1_finish_cleanup "$hr" "$oid" "$def"; return 0; }
    main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    [ -n "$main" ] || { _n1_clean_record "$id" "$trig" "cleanup:skipped (no-repo)" "" ""; echo "cleanup:skipped (no-repo)"; return 0; }
    top=$(_n1_wt_holder "$hr"); [ "$top" = "$main" ] && top=""
    if [ -z "$top" ]; then
        # N1-583: a detached, re-branched or no-PR tree is located by overview workspace_path first (n1_find_workspace)
        # and always gated, never forced: its HEAD must be an ancestor of the merged oid.
        top=$(n1_find_workspace "$id"); [ "$top" = "$main" ] && top=""
        b=$(_n1_wt_records | P="$top" awk -F'\t' 'ENVIRON["P"] != "" && $1 == ENVIRON["P"] {print substr($2, 12); exit}')
        case "$b" in spike/*) top="" ;; esac   # N1-577: a spike worktree is never the ticket's workspace
        [ -n "$top" ] && nof=1
    fi
    if [ "$trig" = merged-nopr ]; then
        st=""; case "$b" in spike/*) st=spike ;; esac
        [ -n "$st" ] || [ -n "$top" ] || st=no-workspace
        if [ -n "$st" ]; then _n1_clean_record "$id" "$trig" "cleanup:skipped ($st)" "" ""; echo "cleanup:skipped ($st)"; return 0; fi
        hr="$b"   # the tree's own branch (empty when detached) is the one checked and deleted
    fi
    [ -n "$top" ] && gate=$(_n1_clean_gate "$top" "$main" "$oid" "$def" "$nof")
    # The surviving-session record below may emit step/queue events a second time.
    if [ "$gate" = $'orca\t' ] && case "$(pwd -P)/" in "$top"/*) true ;; *) false ;; esac; then
        _n1_clean_record "$id" "$trig" "worktree:removed, branch:kept (checked out in $top)" "$top" orca
    fi
    out=$(n1_finish_cleanup "$hr" "$oid" "$def" "$nof" "$top")
    [ -d "$PWD" ] || cd "$main" 2>/dev/null || true
    toks="${out//$'\n'/, }"
    _n1_clean_record "$id" "$trig" "$toks" "$top" "${gate%%$'\t'*}"
    printf '%s\n' "$out"
    return 0
}

escape_json_val() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Per-session active-run pointer (NP-206): $N1_HOME/active-run.<session_id>.json so concurrent
# sessions in one project never read each other's ticket/worktree/branch. No (or unsafe)
# session id -> unkeyed active-run.json. Read mode (no arg) falls back to the unkeyed file when
# this session's keyed file is absent (writer shell lacked the id); `write` always keys.
n1_active_run_file() {
    local home sid
    home=$(n1_home)
    [ -n "$home" ] || return 1
    sid=$(n1_session_id)
    case "$sid" in *[!a-zA-Z0-9_-]*) sid="" ;; esac   # same rule as n1_session_file
    if [ -n "$sid" ] && { [ "${1:-}" = write ] || [ -f "${home}/active-run.${sid}.json" ]; }; then
        printf '%s' "${home}/active-run.${sid}.json"
    else
        printf '%s' "${home}/active-run.json"
    fi
}

# n1_active_run_ticket [sid]: prints ticketId from the active-run pointer (the key n1_active_run_write
# writes). With a sid, reads that session's keyed file only; without, n1_active_run_file's pick.
n1_active_run_ticket() {
    local f home
    if [ -n "${1:-}" ]; then
        case "$1" in *[!a-zA-Z0-9_-]*) return 0 ;; esac
        home=$(n1_home) && [ -n "$home" ] || return 0
        f="${home}/active-run.${1}.json"
    else
        f=$(n1_active_run_file 2>/dev/null) || return 0
    fi
    jq -r '.ticketId // empty | strings' "$f" 2>/dev/null || true
}

# pid: $PPID of the sourced call shell = this session's claude process (N1-308 owner check);
# appended last so the compact "runId":"..." form n1_active_run_clear_if greps stays intact.
n1_active_run_write() {
    local ticket_id="$1" run_id="$2" worktree_path="${3:-null}" branch="${4:-}"
    local file
    file=$(n1_active_run_file write) || return 0
    local wt_val="null"
    [ "$worktree_path" != "null" ] && [ -n "$worktree_path" ] && wt_val="\"$(escape_json_val "$worktree_path")\""
    local esc_ticket esc_run esc_branch
    esc_ticket=$(escape_json_val "$ticket_id")
    esc_run=$(escape_json_val "$run_id")
    esc_branch=$(escape_json_val "$branch")
    cat > "$file" <<AREOF
{"ticketId":"${esc_ticket}","runId":"${esc_run}","worktreePath":${wt_val},"branch":"${esc_branch}","pid":${PPID}}
AREOF
}

n1_active_run_clear() {
    local file
    file=$(n1_active_run_file) || return 0
    rm -f "$file"
}

# n1-finish marker (N1-167): keyed pointer with runId n1-finish so the merge-deny hook gates n1-finish
# paths; an existing pointer (e.g. n1-start's) is kept. Prints marker:keyed|marker:unkeyed|marker:failed (rc 1).
n1_finish_mark() {
    local f
    f=$(n1_active_run_file write) || f=""
    case "$f" in ""|*/active-run.json) echo marker:unkeyed; return 0 ;; esac
    [ -e "$f" ] || n1_active_run_write "$1" n1-finish null "" 2>/dev/null
    [ -e "$f" ] || { echo marker:failed; return 1; }
    echo marker:keyed
}

# Clear this session's keyed pointer only when its runId is $1 (never one another run wrote).
n1_active_run_clear_if() {
    local f
    f=$(n1_active_run_file) || return 0
    case "$f" in */active-run.json) return 0 ;; esac
    grep -qF "\"runId\":\"$1\"" "$f" 2>/dev/null && rm -f "$f"
    return 0
}

# _n1_owner_alive <pid> (N1-308): rc 0 when <pid> is a live claude process. kill -0 must pass;
# where /proc/<pid>/cmdline is readable it must contain "claude" (cmdline, not comm: bg-hosted
# sessions have comm = the version string). Unreadable /proc: kill -0 stands (n1_queue_runner_alive model).
# ponytail: an owner whose recorded pid is not a claude process (unverified `claude --bg` call-shell
# shape) reads dead and is taken over silently; walk up to the claude ancestor if a bg probe shows that.
_n1_owner_alive() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    [ -r "/proc/$1/cmdline" ] || return 0
    case "$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in *claude*) return 0 ;; esac
    return 1
}

# n1_owner_check <ID> (N1-308): does another live session run n1-start on <ID>? Scans
# $N1_HOME/active-run.*.json; prints owner:self | owner:free | owner:stale-takeover, or
# owner:live <sid> <pid> with rc 1. Never an owner: own-sid file, runId n1-finish (n1_finish_mark),
# pid == $PPID (this claude process under a new sid), missing/non-numeric pid (legacy pointer).
# Dead pid: stale, left on disk; the caller's own n1_active_run_write takes over. Headless live: also
# prints a HEADLESS ESCALATION line and appends to overview.md only when it already exists (no new
# memory write). Fail-open: no home or no jq -> owner:free. Run in the sourced call shell ($PPID).
# ponytail: check-then-write; two sessions starting one ticket in the same second both pass.
# A hard-link claim file closes the gap if simultaneous starts ever happen.
n1_owner_check() {
    local id="$1" home sid f fsid t r p stale="" own="" ov
    home=$(n1_home) && [ -n "$home" ] || { echo owner:free; return 0; }
    command -v jq >/dev/null 2>&1 || { echo owner:free; return 0; }
    sid=$(n1_session_id)
    for f in "$home"/active-run.*.json; do
        [ -f "$f" ] || continue
        fsid=${f##*/active-run.}; fsid=${fsid%.json}
        case "$fsid" in ''|*[!a-zA-Z0-9_-]*) continue ;; esac
        t=""; r=""; p=""
        { IFS= read -r t; IFS= read -r r; IFS= read -r p; } \
            < <(jq -r '(.ticketId // ""), (.runId // ""), ((.pid // "") | tostring)' "$f" 2>/dev/null) || :
        [ -n "$t" ] && [ "$t" = "$id" ] || continue
        [ "$fsid" = "$sid" ] && { own=1; continue; }
        [ "$r" = n1-finish ] && continue
        case "$p" in ''|*[!0-9]*) continue ;; esac
        [ "$p" = "$PPID" ] && { own=1; continue; }
        if _n1_owner_alive "$p"; then
            echo "owner:live $fsid $p"
            if [ "${N1_HEADLESS:-}" = 1 ]; then
                echo "HEADLESS ESCALATION: $id owned by live session $fsid (pid $p)"
            fi
            return 1
        fi
        stale=1
    done
    if [ -n "$stale" ]; then echo owner:stale-takeover
    elif [ -n "$own" ]; then echo owner:self
    else echo owner:free
    fi
    return 0
}

n1_assign_gap_warn() {
    # Usage: n1_assign_gap_warn   (no args; always returns 0, fail-open like n1_config_val)
    local ttype atc missing=""
    ttype=$(n1_config_val ".tracker.type")
    case "$ttype" in ""|none) return 0 ;; esac
    atc=$(n1_config_val ".tracker.assignToCreator")
    [ "$atc" = "false" ] && return 0
    [ -n "$(n1_config_val ".tracker.operations.getCurrentUser")" ] || missing="getCurrentUser"
    [ -n "$(n1_config_val ".tracker.operations.assign")" ] || missing="${missing:+$missing and }assign"
    [ -n "$missing" ] || return 0
    printf 'Warning: tracker.assignToCreator is on but config lacks tracker.operations.%s; tickets will not be assigned. Run /n1:n1-init to add it, or set tracker.assignToCreator to false.\n' "$missing"
    return 0
}

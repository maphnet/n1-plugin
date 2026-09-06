#!/usr/bin/env bash
# N1 story orchestrator helpers (n1-story-run). Pure functions; no MCP calls.
# Requires lib/config.sh sourced first (n1_config_val, escape_json_val).

n1_story_parse_service() {
    # Usage: n1_story_parse_service <title>
    # Prints the service tag from "<service> | <title>" or nothing.
    local title="$1"
    case "$title" in
        *" |"*) printf '%s' "${title%% |*}" | sed 's/[[:space:]]*$//' ;;
        *) printf '' ;;
    esac
}

n1_story_find_repo() {
    # Usage: n1_story_find_repo <service> [n1_root]
    # Prints "<config-path>\t<repoPath>" for the first ~/.n1/*/config.json whose
    # ticketTagging.service matches case-insensitively. Exit 1 when none match.
    local service="$1" root="${2:-$HOME/.n1}"
    local want; want=$(printf '%s' "$service" | tr '[:upper:]' '[:lower:]')
    local cfg svc repo
    for cfg in "$root"/*/config.json; do
        [ -f "$cfg" ] || continue
        svc=$(jq -r '.ticketTagging.service // empty' "$cfg" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [ -n "$svc" ] && [ "$svc" = "$want" ] || continue
        repo=$(jq -r '.repoPath // empty' "$cfg" 2>/dev/null)
        printf '%s\t%s' "$cfg" "$repo"
        return 0
    done
    return 1
}

n1_story_val() {
    # Usage: n1_story_val <key> — .story.<key> from config, else defaults/story.json.
    local key="$1" val
    val=$(n1_config_val ".story.${key}")
    if [ -z "$val" ]; then
        val=$(n1_config_val ".${key}" "${CLAUDE_PLUGIN_ROOT}/defaults/story.json")
    fi
    printf '%s' "$val"
}

_n1_story_size_rank() {
    case "$1" in
        XS) echo 1 ;; S) echo 2 ;; M) echo 3 ;; L) echo 4 ;; XL) echo 5 ;;
        *) echo 2 ;;  # unknown/empty counts as S
    esac
}

n1_story_pick_model() {
    # Usage: n1_story_pick_model <size> [flags-csv]
    # sonnet by default; opus when size >= story.opusFromSize or a risk flag is set.
    local size="$1" flags="${2:-}" threshold
    threshold=$(n1_story_val opusFromSize)
    local f
    local -a _flags
    IFS=',' read -r -a _flags <<< "$flags"
    for f in "${_flags[@]+"${_flags[@]}"}"; do
        case "$f" in
            security|public-api|schema-migration|contract) printf 'opus'; return ;;
        esac
    done
    if [ "$(_n1_story_size_rank "$size")" -ge "$(_n1_story_size_rank "${threshold:-M}")" ]; then
        printf 'opus'
    else
        printf 'sonnet'
    fi
}

n1_story_child_status() {
    # Usage: n1_story_child_status <overview.md> <exit-code>
    # Prints: merged | awaiting-merge | escalated | failed | running
    local overview="$1" exit_code="${2:-0}"
    if [ ! -f "$overview" ]; then
        [ "$exit_code" != "0" ] && printf 'failed' || printf 'running'
        return
    fi
    source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
    local step; step=$(n1_read_frontmatter "$overview" "step")
    if [ "$step" = "escalated" ] || awk '/^## Escalations/{f=1;next} /^## /{f=0} f && NF' "$overview" | grep -q .; then
        printf 'escalated'; return
    fi
    if awk '/^## Pending/{f=1;next} /^## /{f=0} f' "$overview" | grep -q '^awaiting: merge'; then
        printf 'awaiting-merge'; return
    fi
    if [ "$step" = "done" ]; then printf 'merged'; return; fi
    [ "$exit_code" != "0" ] && printf 'failed' || printf 'running'
}

n1_story_child_pr_url() {
    # Usage: n1_story_child_pr_url <overview.md> — pr_url from Pending/Finish blocks only.
    local overview="$1"
    [ -f "$overview" ] || return 0
    awk '/^## (Pending|Finish)/{f=1;next} /^## /{f=0} f && /^pr_url:/{sub(/^pr_url:[[:space:]]*/,""); print; exit}' "$overview"
}

n1_story_child_cmd() {
    # Usage: n1_story_child_cmd <repoPath> <ticket-id> <model> <story-id> <log-path>
    local repo="$1" id="$2" model="$3" story="$4" log="$5"
    local plugin_dir=""
    [ -n "${N1_STORY_PLUGIN_DIR:-}" ] && plugin_dir=" --plugin-dir \"${N1_STORY_PLUGIN_DIR}\""
    printf 'cd "%s" && N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous N1_STORY_ID="%s" claude -p "/n1:n1-start %s" --model %s --permission-mode bypassPermissions --output-format stream-json --verbose%s > "%s" 2>&1' \
        "$repo" "$story" "$id" "$model" "$plugin_dir" "$log"
}

n1_story_toposort() {
    # Usage: n1_story_toposort <nodes-csv> <edges: newline-separated "A>B" (A before B)>
    # Kahn's algorithm, stable on input order. Exit 2 on cycle.
    local nodes_csv="$1" edges="${2:-}"
    awk -v nodes="$nodes_csv" -v edges="$edges" '
    BEGIN {
        n = split(nodes, order, ",");
        for (i = 1; i <= n; i++) { node = order[i]; indeg[node] = 0; present[node] = 1 }
        m = split(edges, lines, "\n");
        for (j = 1; j <= m; j++) {
            if (lines[j] == "") continue;
            split(lines[j], pair, ">");
            a = pair[1]; b = pair[2];
            if (!(a in present) || !(b in present)) continue;
            succ[a] = succ[a] " " b; indeg[b]++;
        }
        emitted = 0;
        while (emitted < n) {
            found = 0;
            for (i = 1; i <= n; i++) {
                node = order[i];
                if (done[node] || indeg[node] != 0) continue;
                print node; done[node] = 1; emitted++; found = 1;
                k = split(succ[node], s, " ");
                for (t = 1; t <= k; t++) if (s[t] != "") indeg[s[t]]--;
                break;
            }
            if (!found) {
                rem = "";
                for (i = 1; i <= n; i++) if (!done[order[i]]) rem = rem (rem == "" ? "" : ",") order[i];
                print "cycle: " rem > "/dev/stderr"; exit 2;
            }
        }
    }'
}

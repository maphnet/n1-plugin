#!/usr/bin/env bash
# N1 queue runner helpers (n1-queue). Pure functions; no MCP calls.
# Requires lib/config.sh, lib/host.sh, lib/frontmatter.sh sourced first.

n1_queue_val() {
    # Usage: n1_queue_val <key> — .queue.<key> from config, else defaults/queue.json.
    local key="$1" val
    val=$(n1_config_val ".queue.${key}")
    if [ -z "$val" ]; then
        val=$(n1_config_val ".${key}" "$(n1_plugin_root)/defaults/queue.json")
    fi
    printf '%s' "$val"
}

n1_queue_child_status() {
    # Usage: n1_queue_child_status <overview.md> <exit-code>
    # Prints: pr | escalated | failed | running
    local overview="$1" exit_code="${2:-0}"
    if [ ! -f "$overview" ]; then
        [ "$exit_code" != "0" ] && printf 'failed' || printf 'running'
        return
    fi
    local step; step=$(n1_read_frontmatter "$overview" "step")
    # pr/ci/done all mean stop-at-CI success
    case "$step" in pr|ci|done) printf 'pr'; return ;; esac
    if [ "$step" = "escalated" ] || awk '/^## Escalations/{f=1;next} /^## /{f=0} f && NF' "$overview" | grep -q .; then
        printf 'escalated'; return
    fi
    [ "$exit_code" != "0" ] && printf 'failed' || printf 'running'
}

n1_queue_child_pr_url() {
    # Usage: n1_queue_child_pr_url <overview.md> — pr_url from Pending/Finish blocks.
    local overview="$1"
    [ -f "$overview" ] || return 0
    awk '/^## (Pending|Finish)/{f=1;next} /^## /{f=0} f && /^pr_url:/{sub(/^pr_url:[[:space:]]*/,""); print; exit}' "$overview"
}

n1_queue_child_cmd() {
    # Usage: n1_queue_child_cmd <repoPath> <ticket-id> <model> <run-id> <log-path>
    # Like n1_story_child_cmd but with queue-specific env vars.
    # Test hook: when N1_QUEUE_CHILD_STUB is set, the command is "$N1_QUEUE_CHILD_STUB" <ticket> <overview-path>.
    local repo="$1" id="$2" model="$3" run_id="$4" log="$5"
    if [ -n "${N1_QUEUE_CHILD_STUB:-}" ]; then
        printf '"%s" "%s"' "$N1_QUEUE_CHILD_STUB" "$id"
        return
    fi
    printf 'cd "%s" && N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous N1_STOP_AT=ci N1_QUEUE_RUN_ID="%s" %s' \
        "$repo" "$run_id" "$(n1_headless_cmd n1-start "$id" "$model" "$log")"
}

n1_queue_row_status() {
    # Usage: n1_queue_row_status <queue.md> <row-number> <status> [reason]
    # Rewrites the Status (and optionally Reason) cell of the Plan table row
    # whose first cell equals <row-number>.
    # Row shape: | # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
    local file="$1" row_num="$2" status="$3" reason="${4:-}"
    awk -v num="$row_num" -v st="$status" -v rsn="$reason" 'BEGIN { FS="|"; OFS="|" } {
        f2 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f2)
        if (f2 == num && NF >= 9) {
            $8 = " " st " "
            if (rsn != "") $9 = " " rsn " "
        }
        print
    }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

n1_queue_pending_rows() {
    # Usage: n1_queue_pending_rows <queue.md>
    # Prints: #<TAB>Ticket<TAB>Repo<TAB>N1 Home<TAB>Model for rows with Status "pending".
    local file="$1"
    awk -F'|' '
    {
        for (i = 1; i <= NF; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        }
        if ($8 == "pending" && $2 ~ /^[0-9]+$/) {
            printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $5, $6, $7
        }
    }' "$file"
}

n1_queue_toposort() {
    # Usage: n1_queue_toposort <nodes-csv> <edges: newline-separated "A>B" (A before B)>
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

#!/usr/bin/env bash
# N1 queue statusline — opt-in Claude Code statusline segment for the active queue.
# Deliberately standalone: does NOT source lib/config.sh or lib/queue.sh. Sourcing the
# real preamble measures ~56ms; this script has a <50ms hard budget since Claude Code
# invokes it on every render. It re-derives the N1_HOME slug and re-reads frontmatter
# inline instead (ponytail: logic duplicated from n1_home()/n1_read_frontmatter() in
# lib/config.sh and lib/frontmatter.sh; keep the two in sync if either changes shape).
# Never writes settings.json; see references/architecture.md for the opt-in snippet.
# Prints nothing (exit 0) whenever there is no active queue or anything looks off —
# a statusline must never emit a partial/garbled line or a nonzero exit.
set -uo pipefail

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0

home="${N1_HOME:-}"
if [ -z "$home" ]; then
    cd "$cwd" 2>/dev/null || exit 0
    slug_remote=$(basename "$(git remote get-url origin 2>/dev/null)" .git 2>/dev/null)
    slug_dir=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
    for candidate in "$slug_remote" "$slug_dir"; do
        [ -n "$candidate" ] || continue
        candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
        [ -d "$HOME/.n1/$candidate" ] || continue
        home="$HOME/.n1/$candidate"
        break
    done
fi
[ -n "$home" ] || exit 0

queue_md=""
for f in "$home"/queue/*/queue.md; do
    [ -f "$f" ] || continue
    if [ -z "$queue_md" ] || [ "$f" -nt "$queue_md" ]; then queue_md="$f"; fi
done
[ -n "$queue_md" ] || exit 0

fm() { # fm <file> <key>
    awk -v key="$2" '
        NR==1 && /^---$/ { in_fm=1; next }
        in_fm && /^---$/ { exit }
        in_fm && $0 ~ "^" key ":" { sub("^" key ":[[:space:]]*", ""); gsub(/\r/, ""); printf "%s", $0; exit }
    ' "$1"
}

step=$(fm "$queue_md" step)
case "$step" in plan|run) : ;; *) exit 0 ;; esac
queue_id=$(fm "$queue_md" queue_id)
[ -n "$queue_id" ] || queue_id=$(basename "$(dirname "$queue_md")")

IFS=$'\t' read -r total done needs_you cur_num cur_ticket cur_n1home < <(awk -F'|' '
    BEGIN { total=0; done=0; needs=0; cur_num="" }
    { for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
    $2 ~ /^[0-9]+$/ && NF >= 9 {
        total++
        st = $8
        if (st == "awaiting-human") needs++
        if (st == "pending" || st == "in-progress" || st == "awaiting-human") {
            # still open, not counted as done
        } else {
            done++
        }
        if (cur_num == "" && (st == "in-progress" || st == "awaiting-human")) {
            cur_num = $2; cur_ticket = $3; cur_n1home = $6
        }
    }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\n", total, done, needs, cur_num, (cur_ticket==""?"-":cur_ticket), (cur_n1home==""?"-":cur_n1home) }
' "$queue_md")

[ "$cur_ticket" = "-" ] && cur_ticket="" && cur_n1home=""

line="$queue_id ${done:-0}/${total:-0}"
[ "${needs_you:-0}" -gt 0 ] 2>/dev/null && line="$line · ${needs_you} needs you"

if [ -n "$cur_ticket" ]; then
    cur_step=$(fm "$cur_n1home/memory/$cur_ticket/overview.md" step)
    started=$(awk -F'|' -v tk="$cur_ticket" '
        /^## Runs/ { f = 1; next }
        f { t = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if (t == tk) { s = $3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); ts = s } }
        END { print ts }' "$queue_md")
    elapsed=""
    if [ -n "$started" ]; then
        started_epoch=$(date -u -d "$started" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || echo 0)
        if [ "$started_epoch" -gt 0 ] 2>/dev/null; then
            secs=$(( $(date +%s) - started_epoch ))
            if [ "$secs" -lt 60 ]; then elapsed="<1m"
            elif [ "$secs" -lt 3600 ]; then elapsed="$((secs / 60))m"
            else elapsed="$((secs / 3600))h$(((secs % 3600) / 60))m"
            fi
        fi
    fi
    line="$line · $cur_ticket${cur_step:+ $cur_step}"
    [ -n "$elapsed" ] && line="$line · $elapsed"
fi

line="$line · —"
printf '%s\n' "$line"

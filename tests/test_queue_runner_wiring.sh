#!/usr/bin/env bash
# Fast text-only wiring tests: skills/n1-queue, scripts and references text pins for the queue runner (no runner spawn).
# Run with test_queue_preview_reason.sh for skills/n1-queue text changes. Shared setup: tests/queue_runner_lib.sh (N1-621).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"
source "$REPO_ROOT/lib/memory.sh"

# NP-203: plan/run split wiring in the n1-queue skill text.
test_plan_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    has() { grep -qE -- "$1" "$2" && echo yes || echo no; }
    assert_eq "plan-wiring: SKILL.md parses --plan" "yes" "$(has '\-\-plan' "$s/SKILL.md")"
    assert_eq "plan-wiring: SKILL.md parses --run <queue-id>" "yes" "$(has '\-\-run <queue-id>' "$s/SKILL.md")"
    assert_eq "plan-wiring: SKILL.md validates the queue id" "yes" "$(has 'A-Za-z0-9' "$s/SKILL.md")"
    assert_eq "plan-wiring: dry-run still stops in preview" "yes" "$(has 'Dry run -- nothing launched' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview resolves duplicates at plan time" "yes" "$(has 'CONTEXT=queue-plan' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview orders overlaps via helper" "yes" "$(has 'n1_queue_overlap_order' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview pre-scans the stop list" "yes" "$(has 'alwaysAskOn' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run writes step: planned" "yes" "$(has '^step: planned' "$s/steps/run.md")"
    assert_eq "plan-wiring: run stamps planned_at" "yes" "$(has 'planned_at' "$s/steps/run.md")"
    assert_eq "plan-wiring: run has Decisions section" "yes" "$(has '^## Decisions' "$s/steps/run.md")"
    assert_eq "plan-wiring: --run applies staleness gate" "yes" "$(has 'n1_queue_stale' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview computes the schedule (N1-303)" "yes" "$(has 'n1_queue_overlap_preds$' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run.md re-pins max_concurrent on re-plan" "yes" "$(has 'max_concurrent "\$\(n1_queue_max_concurrent\)"' "$s/steps/run.md")"
    assert_eq "plan-wiring: Start/Edit refresh rewrites the schedule" "yes" "$(sed "/^## Write plan/q" "$s/steps/run.md" | grep -cF 'n1_queue_schedule_write "$QUEUE_DIR' | awk '{print ($1>=2)?"yes":"no"}')"
    assert_eq "plan-wiring: stale re-plan prints the re-pin" "yes" "$(has 'Re-pinned max_concurrent' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview prints the concurrency/usage-limit note" "yes" "$(has 'Parallel workers share your usage limits' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run.md pins max_concurrent in frontmatter" "yes" "$(has '^max_concurrent: <MAX_CONCURRENT>$' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md has the Schedule section" "yes" "$(has '^## Schedule$' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md writes the schedule via helper" "yes" "$(has 'n1_queue_schedule_write' "$s/steps/run.md")"
    assert_eq "plan-wiring: --run keeps the stored value when config differs" "yes" "$(has 'Using planned max_concurrent' "$s/steps/run.md")"
    assert_eq "plan-wiring: saved plan prints its schedule" "yes" "$(has 'n1_queue_plan_waves' "$s/steps/run.md")"
    assert_eq "plan-wiring: queue steps never write overview.md" "no" \
        "$(cat "$s/steps/intake.md" "$s/steps/preview.md" "$s/steps/run.md" | grep -qE 'n1_write_frontmatter[^|]*overview' && echo yes || echo no)"
    assert_eq "plan-wiring: staleness re-plan re-orders every pending row (CR-1)" "yes" "$(has 'Re-run overlap order globally' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview passes blockers to overlap order (N1-524)" "yes" "$(grep -qF "'<BLOCKER2-or-empty>' | n1_queue_overlap_order" "$s/steps/preview.md" && echo yes || echo no)"
    assert_eq "plan-wiring: re-plan passes blockers to overlap order (N1-524)" "yes" "$(grep -qF "'<BLOCKER2-or-empty>' | n1_queue_overlap_order" "$s/steps/run.md" && echo yes || echo no)"
    assert_eq "plan-wiring: re-plan reorders held rows too (N1-524)" "yes" "$(grep -qF 'n1_queue_blocker_of "$QUEUE_FILE" <#>' "$s/steps/run.md" && echo yes || echo no)"
    assert_eq "plan-wiring: staleness recheck uses the sha256 hash helper, not cksum" "yes" "$(has 'n1_queue_content_hash' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md no longer pipes through cksum" "no" "$(has 'cksum <' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview snapshot uses the sha256 hash helper, not cksum" "yes" "$(has 'n1_queue_content_hash' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview.md no longer pipes through cksum" "no" "$(has 'cksum <' "$s/steps/preview.md")"
    assert_eq "plan-wiring: intake validates ticket keys before path use (SEC-L4)" "yes" "$(has '\^\[A-Z\]\[A-Z0-9_\]\*-\[0-9\]\+\$' "$s/steps/intake.md")"

    # SEC-1: the capture hook writes the title/desc files from the fetch; the title is never interpolated into a shell string.
    assert_eq "plan-wiring: preview marks the snapshot fetch for the capture hook (N1-326)" "yes" "$(grep -qF 'n1_desc_mark queue "<KEY>" "<QUEUE_ID>"' "$s/steps/preview.md" && echo yes || echo no)"
    assert_eq "plan-wiring: preview checks missing desc files before the snapshot (N1-326)" "yes" "$(grep -qF 'echo "REFETCH <KEY>"' "$s/steps/preview.md" && echo yes || echo no)"
    assert_eq "plan-wiring: run.md marks the re-plan fetch for the capture hook (N1-326)" "yes" "$(grep -qF 'n1_desc_mark queue "<KEY>" "<QUEUE_ID>"' "$s/steps/run.md" && echo yes || echo no)"
    local fw
    for fw in intake preview run; do
        assert_eq "plan-wiring: $fw.md never model-writes desc/<KEY> files (N1-326)" "0" \
            "$(grep -F 'desc/<KEY>' "$s/steps/$fw.md" | grep -cE 'file-write( mechanism|,)' || true)"
    done
    assert_eq "plan-wiring: preview no longer passes a bare <title> string to content_hash" "no" "$(has 'n1_queue_content_hash "<title>"' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run.md writes the fresh title to a file before hashing" "yes" "$(has '\.title' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md no longer passes a bare <title> string to content_hash" "no" "$(has 'n1_queue_content_hash "<title>"' "$s/steps/run.md")"

    # SEC-4: initial Plan/Decisions rows are built through the sanitizing write helpers, not prose alone.
    assert_eq "plan-wiring: write plan fills Title via n1_queue_row_title" "yes" "$(has 'n1_queue_row_title' "$s/steps/run.md")"
    assert_eq "plan-wiring: write plan fills Decisions row via n1_queue_decisions_write_row" "yes" "$(has 'n1_queue_decisions_write_row' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md passes no free text as a quoted literal" "no" "$(has "'<(title|reason|notes)[^>]*>'|changed: <status>" "$s/steps/run.md")"

    # NP-225: blocker/duplicate/touches re-checks must not be re-gated behind the content-hash CHANGED branch.
    assert_eq "NP-225: blocker check re-runs unconditionally on re-plan" "yes" "$(has 'Blocker check \(unconditional' "$s/steps/run.md")"
    assert_eq "NP-225: duplicate check re-runs unconditionally on re-plan" "yes" "$(has 'Duplicate check \(unconditional' "$s/steps/run.md")"
    assert_eq "NP-225: touches extraction re-runs unconditionally on re-plan" "yes" "$(has 'Touches extraction \(unconditional' "$s/steps/run.md")"
    assert_eq "NP-225: duplicate re-check uses interactive plan-time resolution, not the annotate-only context" "yes" "$(has 'Duplicate check \(unconditional.*CONTEXT=queue-plan' "$s/steps/run.md")"
    assert_eq "NP-225: the CHANGED (content-hash) branch no longer re-runs the blocker/duplicate checks itself" "no" \
        "$(has 'CHANGED.: re-plan this ticket only:.*Blocker check.*Duplicate check' "$s/steps/run.md")"

    # NP-225 CR-1: the per-row loop must read the Decisions row once and flush it once,
    # never call n1_queue_decisions_write_row (a full-row replace) from the duplicate check
    # or touches extraction steps directly — that would blank the other 4 fields each time.
    assert_eq "NP-225 CR-1: per-row loop reads the Decisions row once before duplicate check" "yes" \
        "$(has 'n1_queue_decisions_row \"\$QUEUE_FILE\" \"<KEY>\"' "$s/steps/run.md")"
    assert_eq "NP-225 CR-1: duplicate check no longer writes the Decisions row directly" "no" \
        "$(has 'Duplicate check \(unconditional.*n1_queue_decisions_write_row' "$s/steps/run.md")"
    assert_eq "NP-225 CR-1: touches extraction no longer writes the Decisions row directly" "no" \
        "$(has 'Touches extraction \(unconditional.*n1_queue_decisions_write_row' "$s/steps/run.md")"
}

# N1-423: explicit ticket list input and the required-input gate.
test_list_input_wiring() {
    local s="$REPO_ROOT/skills/n1-queue" in="$REPO_ROOT/skills/n1-queue/steps/input.md"
    has() { grep -qE -- "$1" "$2" && echo yes || echo no; }
    hasF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "list-input: description lists the ticket operand" "yes" \
        "$(sed -n '3p' "$s/SKILL.md" | grep -qF '[<ticket|url>...]' && echo yes || echo no)"
    assert_eq "list-input: argument-hint lists the ticket operand" "yes" \
        "$(sed -n '4p' "$s/SKILL.md" | grep -qF '[<ticket|url>...]' && echo yes || echo no)"
    assert_eq "list-input: step 2 routes to input.md" "yes" \
        "$(grep -E '^2\. \*\*Saved plan' "$s/SKILL.md" | grep -qE 'steps/input\.md' && echo yes || echo no)"
    assert_eq "list-input: SKILL.md no longer reads the default tag" "no" "$(hasF 'n1_queue_val tag' "$s/SKILL.md")"
    assert_eq "list-input: input.md never reads the default tag" "no" "$(hasF 'n1_queue_val tag' "$in")"
    assert_eq "list-input: URLs go through n1_extract_ticket_from_url" "yes" "$(hasF 'n1_extract_ticket_from_url' "$in")"
    assert_eq "list-input: list keys are validated" "yes" "$(hasF '^[A-Z][A-Z0-9_]*-[0-9]+$' "$in")"
    assert_eq "list-input: tag/story ids are validated" "yes" "$(hasF '^[A-Za-z0-9][A-Za-z0-9._-]*$' "$in")"
    assert_eq "list-input: mixed input stops (names --goal, N1-441)" "yes" "$(hasF 'Pass one input: a ticket list, --tag, --story or --goal.' "$in")"
    assert_eq "list-input: --tag with --story is mixed input" "yes" "$(hasF 'includes `--tag` with `--story`' "$in")"
    assert_eq "list-input: no valid key stops" "yes" "$(hasF 'No valid ticket keys in the list.' "$in")"
    assert_eq "list-input: missing-input prompt is free text, not an option list" "no" "$(has '^   > [0-9]\. ' "$in")"
    assert_eq "list-input: intake has List mode" "yes" "$(has '^## List mode$' "$s/steps/intake.md")"
    assert_eq "list-input: list mode skips the already-run check" "yes" \
        "$(sed -n '/^## List mode$/,/^## /p' "$s/steps/intake.md" | grep -qF 'no already-run check' && echo yes || echo no)"
    assert_eq "list-input: list mode excludes invalid items" "yes" \
        "$(sed -n '/^## List mode$/,/^## /p' "$s/steps/intake.md" | grep -qF 'invalid ticket key' && echo yes || echo no)"
    assert_eq "list-input: list mode excludes unreadable keys" "yes" \
        "$(sed -n '/^## List mode$/,/^## /p' "$s/steps/intake.md" | grep -qF 'reason `not found`' && echo yes || echo no)"
    assert_eq "list-input: Story check covers list mode" "yes" "$(has '^## Story check \(tag and list mode\)$' "$s/steps/intake.md")"
    assert_eq "list-input: plan header allows mode list" "yes" "$(hasF 'mode: tag|story|list' "$s/steps/run.md")"
    assert_eq "list-input: revalidation covers list mode" "yes" "$(hasF 'story and list mode: done-class per intake.md § Story mode' "$s/steps/run.md")"
    local line a b c g
    line=$(grep -m1 "printf '%s-%08x'" "$in")
    a=$(GOAL=; KEYS=" N1-2 N1-10 N1-2"; eval "$line"; printf '%s' "$QUEUE_ID")
    b=$(GOAL=; KEYS=" N1-10 N1-2"; eval "$line"; printf '%s' "$QUEUE_ID")
    c=$(GOAL=; KEYS=" N1-3"; eval "$line"; printf '%s' "$QUEUE_ID")
    g=$(GOAL=goal; KEYS=" N1-2 N1-10"; eval "$line"; printf '%s' "$QUEUE_ID")
    assert_eq "list-input: QUEUE_ID ignores order and duplicates" "$a" "$b"
    assert_eq "list-input: QUEUE_ID is list-<8 hex>" "yes" "$([[ "$a" =~ ^list-[0-9a-f]{8}$ ]] && echo yes || echo no)"
    assert_eq "list-input: different keys give a different QUEUE_ID" "yes" "$([ "$a" != "$c" ] && echo yes || echo no)"
    assert_eq "goal-input: goal QUEUE_ID is goal-<8 hex> (N1-441)" "yes" "$([[ "$g" =~ ^goal-[0-9a-f]{8}$ ]] && echo yes || echo no)"
    assert_eq "goal-input: goal id uses the list checksum of the approved keys (N1-441)" "${a#list-}" "${g#goal-}"
    # Run the item-1 resolve loop from input.md with real items and a stubbed URL extractor.
    local raw blk out
    raw=$(awk '/^```bash$/{b="";f=1;next} /^```$/{if(f&&b~/for ITEM in/){printf "%s",b;exit}f=0} f{b=b $0 "\n"}' "$in" | grep -v '^source ')
    blk=${raw/"for ITEM in '<ITEM_1>' '<ITEM_2>'"/"for ITEM in 'N1-2' 'N1-2' 'N1-12' 'N1-1' 'notakey' 'https://x/browse/N1-7' 'https://x/bad' 'n1-5' 'a|PWN-1|x' 'but' 'maxConcurrent'"}
    out=$(n1_extract_ticket_from_url() { case "$1" in */browse/*) echo "${1##*/}" ;; *) return 1 ;; esac; }
        N1_HOME=/nonexistent; eval "$blk")
    assert_eq "list-input: loop keeps order, dedupes, resolves URLs" "KEYS= N1-2 N1-12 N1-1 N1-7" "$(grep '^KEYS=' <<<"$out")"
    assert_eq "list-input: key-shaped typos and failed URLs go to BAD (N1-440)" "BAD= https:__x_bad n1-5" "$(grep '^BAD=' <<<"$out")"
    assert_eq "list-input: other words go to PROSE, sanitized (N1-440)" "PROSE= notakey a_PWN-1_x but maxConcurrent" "$(grep '^PROSE=' <<<"$out")"
    blk=${raw/"for ITEM in '<ITEM_1>' '<ITEM_2>'"/"for ITEM in 'but' 'change' 'maxConcurrent' 'to' '1' 'in' 'n1' 'config'"}
    out=$(N1_HOME=/nonexistent; eval "$blk")
    assert_eq "list-input: prose-only args yield no keys (N1-440)" "KEYS=|BAD=" "$(grep '^KEYS=' <<<"$out")|$(grep '^BAD=' <<<"$out")"
    assert_eq "list-input: prose-only args are kept as an instruction (N1-440)" "PROSE= but change maxConcurrent to 1 in n1 config" "$(grep '^PROSE=' <<<"$out")"
    # N1-440 rule text
    assert_eq "list-input: never-infer rule (N1-440)" "yes" "$(hasF 'Never pick a tag, story or ticket list from conversation context, memory, config, a schedule or an existing queue dir, and never reuse a queue dir because it looks current.' "$in")"
    assert_eq "list-input: prose alone still asks item 3 (N1-440)" "yes" "$(hasF '(prose alone counts as no input)' "$in")"
    assert_eq "list-input: prose printed as a session instruction (N1-440)" "yes" "$(hasF 'Session instruction (not a ticket selector): ' "$in")"
    assert_eq "list-input: prose never selects input (N1-440)" "yes" "$(hasF 'Never use prose as a ticket key, tag, story ID, path or shell word' "$in")"
    assert_eq "list-input: no-valid-key needs BAD items (N1-440)" "yes" "$(hasF '`KEYS` is empty and `BAD` is not' "$in")"
    assert_eq "list-input: interactive plans get a unique id (N1-440)" "yes" "$(hasF 'QUEUE_ID=$(n1_queue_new_id "$QUEUE_ID")' "$in")"
    assert_eq "list-input: planning pointer written at intake (N1-440)" "yes" "$(hasF 'n1_queue_plan_state write "$QUEUE_ID" intake "$MODE" "$SRC"' "$in")"
    assert_eq "list-input: no bare mkdir -p for interactive ids (N1-440)" "0" "$(grep -c 'mkdir -p "$N1_HOME/queue/$QUEUE_ID"' "$in")"
    # N1-441: --goal input (input.md)
    assert_eq "goal-input: --goal is a flag operand, never a token" "yes" "$(hasF '`--goal "<text>"` (the quoted value, or the words up to the next flag; it is never a token and never reaches bash)' "$in")"
    assert_eq "goal-input: empty goal stops" "yes" "$(hasF 'Goal text is empty.' "$in")"
    assert_eq "goal-input: a flag right after --goal counts as empty (N1-441)" "yes" "$(hasF 'or a flag right after it (for example `--goal --dry-run`)' "$in")"
    assert_eq "goal-input: apostrophe in goal stops" "yes" "$(hasF "Invalid goal: remove the apostrophe (')." "$in")"
    assert_eq "goal-input: item 3 asks for --goal too" "yes" "$(hasF 'no `--story` and no `--goal` (prose alone counts as no input)' "$in")"
    assert_eq "goal-input: MODE has no goal value" "yes" "$(hasF "MODE='<list|tag|story>'" "$in")"
    assert_eq "goal-input: goal mode is saved as mode list" "yes" "$(hasF 'goal mode is `goal-` plus the same checksum of the approved keys and is saved as `mode: list`' "$in")"
    lno() { grep -nF -- "$1" "$in" | head -1 | cut -d: -f1; }
    local q d x
    q=$(lno 'Invalid goal: remove the apostrophe')
    d=$(lno 'read and follow `<N1_ROOT>/skills/n1-queue/steps/goal.md`'); x=$(lno '5. **Queue id and dir.**')
    assert_eq "goal-input: goal stops and goal.md precede item 5, so nothing is written first" "yes" \
        "$([ -n "$q" ] && [ -n "$d" ] && [ -n "$x" ] && [ "$q" -lt "$d" ] && [ "$d" -lt "$x" ] && echo yes || echo no)"
    # N1-441: steps/goal.md
    local gm="$s/steps/goal.md"
    assert_eq "goal-input: goal.md exists" "yes" "$([ -f "$gm" ] && echo yes || echo no)"
    assert_eq "goal-input: Jira pool is To Do only, oldest first" "yes" "$(hasF 'JQL `project = <PROJECT_KEY> AND status = "<TODO_STATUS>" ORDER BY created ASC`' "$gm")"
    assert_eq "goal-input: YouTrack pool is To Do only, oldest first" "yes" "$(hasF 'query `project: {PREFIX} State: {<TODO_STATUS>} sort by: created asc`' "$gm")"
    assert_eq "goal-input: pool capped by queue.maxTickets" "yes" "$(hasF 'n1_queue_val maxTickets' "$gm")"
    assert_eq "goal-input: pool keys validated (SEC-L4)" "yes" "$(hasF '^[A-Z][A-Z0-9_]*-[0-9]+$' "$gm")"
    assert_eq "goal-input: ranking reads no ticket" "no" "$(hasF 'READ_OP' "$gm")"
    assert_eq "goal-input: ranking marks no ticket" "no" "$(hasF 'n1_desc_mark' "$gm")"
    assert_eq "goal-input: goal.md runs no bash" "no" "$(has '^```bash' "$gm")"
    assert_eq "goal-input: reason is one sanitized line" "yes" "$(hasF '`|` and newlines replaced by a space, at most 80 characters' "$gm")"
    assert_eq "goal-input: empty pool stops" "yes" "$(hasF 'No To Do tickets in the pool.' "$gm")"
    assert_eq "goal-input: no match stops" "yes" "$(hasF 'No To Do ticket matches the goal.' "$gm")"
    assert_eq "goal-input: edit to zero stops" "yes" "$(hasF 'No tickets selected.' "$gm")"
    assert_eq "goal-input: Approve option" "yes" "$(has '^- \*\*Approve\*\* -> ' "$gm")"
    assert_eq "goal-input: Edit option" "yes" "$(has '^- \*\*Edit\*\* -> ' "$gm")"
    assert_eq "goal-input: Cancel option" "yes" "$(has '^- \*\*Cancel\*\* -> \*\*STOP\.\*\*' "$gm")"
    assert_eq "goal-input: option list follows the recommended-option rule" "yes" "$(hasF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$gm")"
    assert_eq "goal-input: no Recommended label" "no" "$(hasF '(Recommended)' "$gm")"
    assert_eq "goal-input: returns GOAL=goal" "yes" "$(hasF '`GOAL=goal`' "$gm")"
    assert_eq "goal-input: GOAL placeholder is the literal word, not the goal text" "yes" "$(hasF "GOAL='<the literal word goal in goal mode, else empty; never the goal text>'" "$in")"
    # N1-441: SKILL.md surface
    assert_eq "goal-input: description lists --goal" "yes" "$(sed -n '3p' "$s/SKILL.md" | grep -qF '[--story <ID>] [--goal <text>] [--plan]' && echo yes || echo no)"
    assert_eq "goal-input: argument-hint lists --goal" "yes" "$(sed -n '4p' "$s/SKILL.md" | grep -qF '[--story <ID>] [--goal <text>] [--plan]' && echo yes || echo no)"
    assert_eq "goal-input: Input section parses --goal" "yes" "$(hasF '`--goal "<text>"` (goal mode: rank To Do tickets, user approves)' "$s/SKILL.md")"
}

# N1-298: --story <Epic> expands each child into its Sub-tasks; --story <Story> is unchanged.
test_story_epic_wiring() {
    local s="$REPO_ROOT/skills/n1-queue/steps"
    hasF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    hasX() { grep -qxF -- "$1" "$2" && echo yes || echo no; }
    # Epic branch
    assert_eq "epic-wiring: intake has the Jira-only Epic expansion paragraph" "yes" "$(hasF '**Epic expansion (Jira only).**' "$s/intake.md")"
    assert_eq "epic-wiring: Epic branch keys on root issue type Epic" "yes" "$(hasF 'returned issue type `Epic` for the story ID' "$s/intake.md")"
    assert_eq "epic-wiring: per-child search copies the story JQL form" "yes" "$(hasF 'JQL `parent = <STORY_KEY> ORDER BY created ASC`' "$s/intake.md")"
    assert_eq "epic-wiring: child keys are key-validated before the search" "yes" "$(hasF 'Apply § Key validation to `<STORY_KEY>` before the search' "$s/intake.md")"
    assert_eq "epic-wiring: any child search error stops the whole intake" "yes" "$(hasF '**STOP** the whole intake (no partial plan)' "$s/intake.md")"
    assert_eq "epic-wiring: childless child stays one row" "yes" "$(hasF 'Reason `epic child`' "$s/intake.md")"
    assert_eq "epic-wiring: expanded Sub-tasks carry their Story key" "yes" "$(hasF 'Reason `epic subtask of <STORY_KEY>`' "$s/intake.md")"
    assert_eq "epic-wiring: all-Done child is excluded" "yes" "$(hasF 'done-before-run (all subtasks done)' "$s/intake.md")"
    assert_eq "epic-wiring: depth fixed, Sub-tasks never searched" "yes" "$(hasF 'never search a Sub-task for children' "$s/intake.md")"
    assert_eq "epic-wiring: YouTrack story mode unchanged" "yes" "$(hasF 'YouTrack has no Epic path here' "$s/intake.md")"
    assert_eq "epic-wiring: Output lists the Epic Reason values" "yes" "$(hasF '`epic subtask of <STORY_KEY>` and `epic child` for Epic-mode candidates' "$s/intake.md")"
    # Unchanged Story path (byte-identical lines)
    assert_eq "epic-wiring: story JQL line unchanged" "yes" "$(hasX '- **Jira:** call `mcp__<TRACKER_MCP>__<SEARCH_OP>` with JQL `parent = <STORY_ID> ORDER BY created ASC`. Include `cloudId`.' "$s/intake.md")"
    assert_eq "epic-wiring: zero-subtask STOP line unchanged" "yes" "$(hasX '- **Zero subtasks** (parsed empty result, any status): print "no subtasks — run /n1:n1-start <STORY_ID>" and **STOP** (no queue is built).' "$s/intake.md")"
    assert_eq "epic-wiring: story subtask Reason kept" "yes" "$(hasF '`story subtask` for story-mode candidates found via subtask enumeration' "$s/intake.md")"
    # Preview hierarchy (display-only, schema unchanged)
    assert_eq "epic-wiring: preview prints Hierarchy only for epic Reasons (contains, not starts-with)" "yes" "$(hasF 'When any candidate'"'"'s Reason contains `epic subtask of ` or `epic child`' "$s/preview.md")"
    assert_eq "epic-wiring: preview Hierarchy line format" "yes" "$(hasX 'Epic <SRC> > Story <STORY_KEY> <CHILD_TITLE>: #3, #4, #5' "$s/preview.md")"
    assert_eq "epic-wiring: Hierarchy uses post-reorder numbers and is display-only" "yes" "$(hasF 'Grouping is display-only' "$s/preview.md")"
    assert_eq "epic-wiring: Prompt re-print includes the Hierarchy block" "yes" "$(hasF 'Print the plan table again (Reason now carries Order notes) and the Hierarchy block when it applies' "$s/preview.md")"
}

# NP-231: every N1 description write in a queue child goes through the hash chain.
test_desc_chain_wiring() {
    local r="$REPO_ROOT" f d="$REPO_ROOT/references/desc-hash-chain.md" pa="$REPO_ROOT/references/description-quality.md"
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    for f in references/title-form-repair.md references/description-quality.md skills/n1-start/steps/brainstorm.md \
             skills/n1-start/steps/investigation-deliverable.md; do
        assert_eq "chain-wiring: $f routes its description write through desc-hash-chain.md" "yes" "$(_hasF 'references/desc-hash-chain.md' "$r/$f")"
    done
    assert_eq "chain-wiring: product-analyst wires both write paths (Empty/Skeletal step 3, Weak step 2)" "yes" "$(_hasF 'Empty/Skeletal step 3, Weak step 2' "$pa")"
    assert_eq "chain-wiring: procedure is gated on N1_QUEUE_RUN_ID" "yes" "$(_hasF '[ -n "${N1_QUEUE_RUN_ID:-}" ]' "$d")"
    assert_eq "chain-wiring: pre-write text is hashed from files (SEC-1)" "yes" "$(_hasF 'n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt"' "$d")"
    assert_eq "chain-wiring: post-write text is re-fetched and hashed from files" "yes" "$(_hasF 'n1_queue_content_hash "$M/.desc-post.title" "$M/.desc-post.txt"' "$d")"
    assert_eq "chain-wiring: records only via the gated helper" "yes" "$(_hasF 'n1_desc_hash_record "<ID>" "$PRE" "$POST"' "$d")"
    assert_eq "chain-wiring: a title change clears POST before the record (SEC-1/SEC-5)" "yes" "$(_hasF 'cmp -s "$M/.desc-pre.title" "$M/.desc-post.title" || POST=""' "$d")"
    assert_eq "chain-wiring: forbids appending to .desc-hashes any other way" "yes" "$(_hasF 'Never append to `.desc-hashes` any other way' "$d")"
    assert_eq "chain-wiring: procedure runs no raw append to .desc-hashes" "0" "$(grep -cE '>>[^|]*desc-hashes' "$d" 2>/dev/null || true)"
    assert_eq "chain-wiring: Gate clears stale pre/post scratch files (CR-1/SEC-1)" "2" "$(grep -cF 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.*' "$d" 2>/dev/null || true)"
    # product-analyst: skip markers unchanged; the queue brief never skips enrichment.
    assert_eq "chain-wiring: product-analyst skip markers unchanged" "yes" "$(_hasF 'already contains the marker `*Structured by N1*` or `*Restructured by N1*`, skip enrichment' "$pa")"
    assert_eq "chain-wiring: Briefed marker never on a skip line" "0" "$(grep -F 'skip enrichment' "$pa" | grep -cF 'Briefed' || true)"
    assert_eq "chain-wiring: product-analyst grades briefed tickets normally" "yes" "$(_hasF '`*Briefed by N1 (queue plan)*` (n1-queue'"'"'s plan-time brief) is not an idempotency marker' "$pa")"

    # TQ-3 (NP-231 cycle 2): order assertions so removing the SEC-1/SEC-4 cleanup fails a test.
    local gate_rm chain_echo after_record after_rm
    gate_rm=$(line_of "$d" 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.*' || true)
    chain_echo=$(line_of "$d" 'echo CHAIN' || true)
    assert_eq "chain-wiring: Gate clears scratch files before the CHAIN check" "yes" "$([ -n "$gate_rm" ] && [ -n "$chain_echo" ] && [ "$gate_rm" -lt "$chain_echo" ] && echo yes || echo no)"
    after_record=$(line_of "$d" 'n1_desc_hash_record "<ID>" "$PRE" "$POST"' || true)
    after_rm=$(grep -nF 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.*' "$d" | tail -1 | cut -d: -f1)
    assert_eq "chain-wiring: After's final rm -f runs after the record call" "yes" "$([ -n "$after_record" ] && [ -n "$after_rm" ] && [ "$after_rm" -gt "$after_record" ] && echo yes || echo no)"

    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless-predecision.md" guard_clear_before guard_hash guard_clear_after
    guard_clear_before=$(line_of "$h" 'rm -f "$N1_HOME/memory/$ID"/.guard-live.*' || true)
    guard_hash=$(line_of "$h" 'NEW_HASH=$(n1_queue_content_hash "$M/.guard-live.title" "$M/.guard-live.txt")' || true)
    assert_eq "chain-wiring: guard clears live-fetch files before the hash" "yes" "$([ -n "$guard_clear_before" ] && [ -n "$guard_hash" ] && [ "$guard_clear_before" -lt "$guard_hash" ] && echo yes || echo no)"
    guard_clear_after=$(line_of "$h" 'rm -f "$M"/.guard-live.*' || true)
    assert_eq "chain-wiring: guard clears live-fetch files after computing NEW_HASH" "yes" "$([ -n "$guard_hash" ] && [ -n "$guard_clear_after" ] && [ "$guard_clear_after" -gt "$guard_hash" ] && echo yes || echo no)"

    # N1-164: refined-block Intake check in desc-hash-chain.md.
    assert_eq "chain-wiring: Intake check section exists" "yes" "$(_hasF '## Intake check (refined description block)' "$d")"
    assert_eq "chain-wiring: Intake check hashes the live title/description from files (SEC-1)" "yes" "$(_hasF 'NEW_HASH=$(n1_queue_content_hash "$M/.guard-live.title" "$M/.guard-live.txt")' "$d")"
    assert_eq "chain-wiring: Intake check decision line" "yes" "$(_hasF 'if [ -n "$NEW_HASH" ] && n1_desc_hash_is_trusted "<ID>" "$NEW_HASH"; then echo MATCH; else echo MISMATCH; fi' "$d")"
    assert_eq "chain-wiring: Intake check MISMATCH ignores the description block" "yes" "$(_hasF 'ignore the description block (treat it as absent)' "$d")"
    assert_eq "chain-wiring: Gate also clears stale .guard-live files" "1" "$(grep -cF 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.* "$M"/.guard-live.*' "$d" 2>/dev/null || true)"
    local intake_hash intake_rm
    intake_hash=$(line_of "$d" 'NEW_HASH=$(n1_queue_content_hash "$M/.guard-live.title" "$M/.guard-live.txt")' || true)
    intake_rm=$(line_of "$d" 'rm -f "$M"/.guard-live.*' || true)
    assert_eq "chain-wiring: Intake check clears live files after computing NEW_HASH" "yes" "$([ -n "$intake_hash" ] && [ -n "$intake_rm" ] && [ "$intake_rm" -gt "$intake_hash" ] && echo yes || echo no)"

    # N1-326: the capture hook writes the scratch files; each fetch is marked first and nothing is model-written.
    local mk_pre mk_post mk_guard pre_hash post_hash unmark
    mk_pre=$(line_of "$d" 'n1_desc_mark pre "<ID>"' || true)
    mk_post=$(line_of "$d" 'n1_desc_mark post "<ID>"' || true)
    mk_guard=$(line_of "$d" 'n1_desc_mark guard "<ID>"' || true)
    pre_hash=$(line_of "$d" 'n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt"' || true)
    post_hash=$(line_of "$d" 'n1_queue_content_hash "$M/.desc-post.title" "$M/.desc-post.txt"' || true)
    unmark=$(line_of "$d" 'n1_desc_unmark "<ID>"' || true)
    assert_eq "chain-wiring: Before marks its fetch before the hash (N1-326)" "yes" "$([ -n "$mk_pre" ] && [ -n "$pre_hash" ] && [ "$mk_pre" -lt "$pre_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: After marks its re-fetch after Before's mark and before the hash (N1-326)" "yes" "$([ -n "$mk_post" ] && [ -n "$mk_pre" ] && [ "$mk_pre" -lt "$mk_post" ] && [ "$mk_post" -lt "$post_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: Intake check marks its fetch before the hash (N1-326)" "yes" "$([ -n "$mk_guard" ] && [ -n "$intake_hash" ] && [ "$mk_guard" -lt "$intake_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: Gate drops a pending marker before the CHAIN check (N1-326)" "yes" "$([ -n "$unmark" ] && [ "$gate_rm" -lt "$unmark" ] && [ "$unmark" -lt "$chain_echo" ] && echo yes || echo no)"
    assert_eq "chain-wiring: no model file-write of tracker text left (N1-326)" "0" "$(grep -cE 'file-write( mechanism|,)' "$d" || true)"
    local mk_g
    mk_g=$(line_of "$h" 'n1_desc_mark guard "$ID"' || true)
    assert_eq "chain-wiring: headless guard marks its re-fetch between clear and hash (N1-326)" "yes" "$([ -n "$mk_g" ] && [ "$guard_clear_before" -lt "$mk_g" ] && [ "$mk_g" -lt "$guard_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: headless guard never model-writes .guard-live (N1-326)" "0" "$(grep -F '.guard-live' "$h" | grep -cE 'file-write( mechanism|,)' || true)"
}

# NP-231: thin tickets get a plan-time brief instead of a word-count exclusion.
test_brief_wiring() {
    local s="$REPO_ROOT/skills/n1-queue" b c
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "brief: intake no longer excludes on word count" "no" "$(grep -qE '30 words|description too thin' "$s/steps/intake.md" && echo yes || echo no)"
    assert_eq "brief: intake's only content exclusion reason" "yes" "$(_hasF 'no usable content: empty description, vague title' "$s/steps/intake.md")"
    assert_eq "brief: intake checks the title from a file (SEC-1)" "yes" "$(_hasF 'n1_title_vague "<QUEUE_DIR>/desc/<KEY>.title"' "$s/steps/intake.md")"
    assert_eq "brief: intake reuses product-analyst tiers" "yes" "$(_hasF 'references/description-quality.md' "$s/steps/intake.md")"
    assert_eq "brief: intake never re-briefs a briefed ticket" "yes" "$(_hasF '*Briefed by N1 (queue plan)*' "$s/steps/intake.md")"
    assert_eq "brief: preview writes the marked brief" "yes" "$(_hasF '*Briefed by N1 (queue plan)*' "$s/steps/preview.md")"
    assert_eq "brief: preview re-fetches briefed tickets before the snapshot" "yes" "$(_hasF 'Re-fetch each briefed candidate' "$s/steps/preview.md")"
    b=$(line_of "$s/steps/preview.md" '*Briefed by N1 (queue plan)*' || true)
    c=$(line_of "$s/steps/preview.md" 'n1_queue_content_hash' || true)
    assert_eq "brief: Desc Checksum is taken after the brief" "yes" "$([ -n "$b" ] && [ -n "$c" ] && [ "$b" -lt "$c" ] && echo yes || echo no)"
    assert_eq "brief: preview shows briefs before Start" "yes" "$(_hasF 'Brief <KEY>:' "$s/steps/preview.md")"
    assert_eq "brief: --run re-plan re-runs Plan-Resolve 1 so the checksum stays post-brief" "yes" "$(_hasF 'preview.md § Plan-Resolve 1' "$s/steps/run.md")"
    assert_eq "brief: intake marks each candidate fetch for the capture hook (N1-326)" "yes" "$(_hasF 'n1_desc_mark queue "<KEY>" "<QUEUE_ID>"' "$s/steps/intake.md")"
    assert_eq "brief: a missing captured title keeps the candidate (N1-326 D8)" "yes" "$(_hasF 'echo MISSING' "$s/steps/intake.md")"
}

# N1-271: --retry is routed, documented and wired to the helper; a resumed escalated child re-asks.
test_retry_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "retry-wiring: argument-hint offers --retry" "yes" "$(grep -q '^argument-hint:.*\[--retry <ticket>\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "retry-wiring: description usage offers --retry" "yes" "$(grep -q '^description:.*\[--retry <ticket>\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "retry-wiring: Input parses --retry" "yes" "$(_hasF ', --retry <ticket>, --stop [<id>], --close [<id>], ' "$s/SKILL.md")"
    assert_eq "retry-wiring: step 1 routes --retry" "yes" "$(_hasF 'If `--retry`: read and follow `<N1_ROOT>/skills/n1-queue/steps/retry.md`. **STOP.**' "$s/SKILL.md")"
    assert_eq "retry-wiring: step calls the helper" "yes" "$(_hasF 'n1_queue_retry "$QUEUE_FILE" "$RETRY_TICKET"' "$s/steps/retry.md")"
    assert_eq "retry-wiring: step validates the ticket id first" "yes" "$(_hasF '^[A-Za-z][A-Za-z0-9_]*-[0-9]+$' "$s/steps/retry.md")"
    assert_eq "retry-wiring: resumed escalated child re-asks" "yes" "$(_hasF 'N1_ORCA_RESUME=1' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: resume re-asks only the last escalation" "yes" "$(_hasF 'last `## Escalations` item' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: resume makes the step reset the first overview.md write" "yes" "$(_hasF 'The step reset is the first overview.md write' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: resume never resets to a runner-terminal step" "yes" "$(_hasF 'If that step is `pr`, `ci` or `done` (terminal for the queue runner poll' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: architecture documents the resumable exception" "yes" "$(_hasF 'n1_orca_worktree_resumable' "$REPO_ROOT/references/architecture.md")"
}

# N1-536: --run on a done/halted/interrupted queue re-reads the tracker before launching. Bugs caught: done/halted
# still stopping with "No saved plan"; the helper not called; the tag-mode TODO_STATUS test used instead of the
# done-class list; released rows skipping the blocker check; a done queue with nothing left launched; the re-read
# placed before the busy guard (tracker calls on a live queue); RESUME=1 not covering the relaunch.
test_rerun_wiring() {
    local r="$REPO_ROOT/skills/n1-queue/steps/run.md"
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "rerun-wiring: routes done, halted and interrupted" "yes" "$(_hasF '`STEP` is `done` or `halted`, or `INTERRUPTED=yes`' "$r")"
    assert_eq "rerun-wiring: Re-read subsection" "yes" "$(_hasF '### Re-read (step done, halted or interrupted run)' "$r")"
    assert_eq "rerun-wiring: lists the re-read rows" "yes" "$(_hasF "n1_queue_pending_rows \"\$QUEUE_DIR/queue.md\" 'failed|escalated|skip|pending|held'" "$r")"
    assert_eq "rerun-wiring: done-class list in every mode" "yes" "$(_hasF 'one of `done`, `closed`, `resolved`, `fixed`, `verified` (intake.md § Story mode status classification), in every queue mode' "$r")"
    assert_eq "rerun-wiring: calls the helper" "yes" "$(_hasF 'n1_queue_rerun_release "$QUEUE_DIR/queue.md"' "$r")"
    assert_eq "rerun-wiring: blocker check on released rows" "yes" "$(_hasF '**Blocker check (every `released` row):**' "$r")"
    assert_eq "rerun-wiring: nothing left stops, step unchanged" "yes" "$(_hasF 'Nothing left to run for `<QUEUE_ID>`; the step is unchanged.' "$r")"
    assert_eq "rerun-wiring: interrupted run always relaunches" "yes" "$(_hasF '`INTERRUPTED=yes`: go to § Launch with `RESUME=1` whatever `LEFT` is.' "$r")"
    assert_eq "rerun-wiring: Launch RESUME covers the relaunch" "yes" "$(_hasF 'or § Re-read relaunches a done or halted queue' "$r")"
    assert_eq "rerun-wiring: other steps still stop" "yes" "$(_hasF 'No saved plan for `<QUEUE_ID>`' "$r")"
    assert_eq "rerun-wiring: planned STALE path kept" "yes" "$(_hasF '`STALE=yes` (planned more than `STALE_HOURS` hours ago' "$r")"
    local bg rr; bg=$(grep -n -m1 -F '**Busy guard' "$r" | cut -d: -f1); rr=$(grep -n -m1 -F '### Re-read (' "$r" | cut -d: -f1)
    local wp; wp=$(grep -n -m1 -F '## Write plan (' "$r" | cut -d: -f1)
    assert_eq "rerun-wiring: re-read precedes Write plan" "yes" "$([ -n "$rr" ] && [ -n "$wp" ] && [ "$rr" -lt "$wp" ] && echo yes || echo no)"
    assert_eq "rerun-wiring: bg run order wording" "yes" "$(_hasF 'the bg backend runs rows in plan order.' "$r")"
    assert_eq "rerun-wiring: busy guard precedes the re-read" "yes" "$([ -n "$bg" ] && [ -n "$rr" ] && [ "$bg" -lt "$rr" ] && echo yes || echo no)"
    # N1-609: hand merges are recorded before the release pass; LEFT counts story pr rows a relaunch can still land.
    assert_eq "rerun-wiring: re-read reconciles hand merges" "yes" "$(_hasF 'n1_queue_reconcile "$QUEUE_DIR/queue.md" || true' "$r")"
    local rcl rll; rcl=$(grep -n -m1 -F 'n1_queue_reconcile "$QUEUE_DIR/queue.md"' "$r" | cut -d: -f1)
    rll=$(grep -n -m1 -F 'n1_queue_rerun_release "$QUEUE_DIR/queue.md"' "$r" | cut -d: -f1)
    assert_eq "rerun-wiring: reconcile precedes the release pass" "yes" "$([ -n "$rcl" ] && [ -n "$rll" ] && [ "$rcl" -lt "$rll" ] && echo yes || echo no)"
    assert_eq "rerun-wiring: LEFT counts resumable story pr rows" "yes" "$(_hasF 'n1_queue_pr_resume_rows "$QUEUE_DIR/queue.md"' "$r")"
    assert_eq "rerun-wiring: summary names recorded merges" "yes" "$(_hasF 'recorded as merged: <KEYs>' "$r")"
}

# N1-481: --close routing, operand parsing and the abandon gate.
test_close_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "close-wiring: argument-hint offers --close" "yes" "$(grep -q '^argument-hint:.*\[--close \[<id>\]\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "close-wiring: description usage offers --close" "yes" "$(grep -q '^description:.*\[--close \[<id>\]\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "close-wiring: step 1 routes --close" "yes" "$(_hasF 'If `--close`: read and follow `<N1_ROOT>/skills/n1-queue/steps/close.md`. **STOP.**' "$s/SKILL.md")"
    assert_eq "close-wiring: QUEUE_ID takes the --close id" "yes" "$(_hasF '(under `--stop`/`--close`, its `<id>` argument when given)' "$s/SKILL.md")"
    assert_eq "close-wiring: input.md treats the id as an operand" "yes" "$(_hasF '`--stop`/`--close [<id>]`' "$s/steps/input.md")"
    assert_eq "close-wiring: step calls the helper" "yes" "$(_hasF 'n1_queue_close "$QUEUE_FILE"' "$s/steps/close.md")"
    assert_eq "close-wiring: abandon re-call" "yes" "$(_hasF 'n1_queue_close "$QUEUE_FILE" abandon' "$s/steps/close.md")"
    assert_eq "close-wiring: headless refused" "yes" "$(_hasF '--close needs an interactive session.' "$s/steps/close.md")"
    assert_eq "close-wiring: abandon gate has no recommendation" "yes" "$(_hasF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$s/steps/close.md")"
}

# N1-524: --discard routing, required id and the saved-plan helper call.
test_discard_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "discard-wiring: argument-hint offers --discard" "yes" "$(grep -q '^argument-hint:.*\[--discard <id>\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "discard-wiring: description usage offers --discard" "yes" "$(grep -q '^description:.*\[--discard <id>\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "discard-wiring: step 1 routes --discard" "yes" "$(_hasF 'If `--discard`: read and follow `<N1_ROOT>/skills/n1-queue/steps/discard.md`. **STOP.**' "$s/SKILL.md")"
    assert_eq "discard-wiring: id required" "yes" "$(_hasF '--discard needs a queue id.' "$s/steps/discard.md")"
    assert_eq "discard-wiring: id validated before interpolation" "yes" "$(_hasF '^[A-Za-z0-9][A-Za-z0-9._-]*$' "$s/steps/discard.md")"
    assert_eq "discard-wiring: step calls the saved-plan helper" "yes" "$(_hasF "n1_queue_plan_discard '<QUEUE_ID>' saved" "$s/steps/discard.md")"
    assert_eq "discard-wiring: refusal points to --close" "yes" "$(_hasF 'Use --close for a started queue.' "$s/steps/discard.md")"
    assert_eq "discard-wiring: architecture documents --discard" "yes" "$(_hasF 'n1-queue --discard <id>' "$REPO_ROOT/references/architecture.md")"
}

# N1-61: placeholder titles and form-dump descriptions are repaired at intake.
test_form_repair_wiring() {
    local pa="$REPO_ROOT/references/title-form-repair.md" m='*Normalized by N1*'
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "repair: Normalized counts as already enriched" "yes" "$(_hasF '`Normalized by N1` (Title & Form Repair' "$REPO_ROOT/references/description-quality.md")"
    assert_eq "repair: title and description go in one editTicket call" "yes" "$(_hasF '`issueIdOrKey`, `summary`, `description`' "$pa")"
    assert_eq "repair: queue children drop the title part" "yes" "$(_hasF 'On `CHAIN`, drop the title part' "$pa")"
    assert_eq "repair: Normalized block uses plain bullets" "0" "$(grep -A8 -F "$m" "$pa" | grep -cF -- '- [ ]' || true)"
    local q="$REPO_ROOT/skills/n1-queue/steps" d="$REPO_ROOT/references/desc-hash-chain.md" r s
    assert_eq "repair: queue intake treats Normalized as Adequate" "yes" "$(_hasF '`Normalized by N1` (with or without' "$q/intake.md")"
    assert_eq "repair: queue preview applies the product-analyst rules" "yes" "$(_hasF 'title-form-repair.md` § Title & Form Repair' "$q/preview.md")"
    assert_eq "repair: repaired candidates are re-fetched before the snapshot" "yes" "$(_hasF 'Re-fetch each briefed candidate and each repaired one' "$q/preview.md")"
    r=$(line_of "$q/preview.md" '**Repair (every candidate' || true)
    s=$(line_of "$q/preview.md" 'n1_queue_content_hash' || true)
    assert_eq "repair: repair runs before the Desc Checksum" "yes" "$([ -n "$r" ] && [ -n "$s" ] && [ "$r" -lt "$s" ] && echo yes || echo no)"
    assert_eq "repair: hash chain no longer claims N1 never writes the title" "no" "$(_hasF 'N1 never writes the title' "$d")"
    assert_eq "repair: queue repair re-fetches and skips a changed ticket" "yes" "$(_hasF 'repair skipped (changed)' "$q/preview.md")"
    assert_eq "repair: product-analyst guards whole-field writes" "yes" "$(_hasF '**Stale-write guard:**' "$REPO_ROOT/references/description-quality.md")"
    assert_eq "repair: queue brief re-fetches and skips a changed ticket" "yes" "$(_hasF 'brief skipped (changed)' "$q/preview.md")"
}

# --- NP-199: release procedure wiring ------------------------------------------
test_release_wiring() {
    local s="$REPO_ROOT/skills"
    assert_eq "wiring: release procedure exists" "yes" \
        "$([ -f "$s/n1-queue/procedures/release-tag.md" ] && echo yes || echo no)"
    assert_eq "wiring: procedure writes flag" "yes" \
        "$(grep -q 'queue_tag_removed true' "$s/n1-queue/procedures/release-tag.md" 2>/dev/null && echo yes || echo no)"
    assert_eq "wiring: intake uses already-run check" "yes" \
        "$(grep -q 'n1_queue_already_run' "$s/n1-queue/steps/intake.md" && echo yes || echo no)"
    assert_eq "wiring: report releases rows" "yes" \
        "$(grep -q 'n1_queue_release_rows' "$s/n1-queue/steps/report.md" && grep -q 'release-tag.md' "$s/n1-queue/steps/report.md" && echo yes || echo no)"
    assert_eq "wiring: headless escalation releases tag" "yes" \
        "$(grep -q 'release-tag.md' "$s/n1-start/procedures/autonomy-headless.md" && grep -q 'to re-queue this ticket' "$s/n1-start/procedures/autonomy-headless.md" && echo yes || echo no)"
    assert_eq "wiring: PR step releases tag" "yes" \
        "$(grep -q 'release-tag.md' "$s/n1-pr/steps/02-push-create.md" && echo yes || echo no)"
    # Non-queue PR runs must not fall back to the config default tag (CR-1).
    assert_eq "wiring: PR step tag has no config fallback" "yes" \
        "$(grep -qF '"${N1_QUEUE_TAG:-}"' "$s/n1-pr/steps/02-push-create.md" && ! grep -q 'n1_queue_val' "$s/n1-pr/steps/02-push-create.md" && echo yes || echo no)"
    assert_eq "wiring: PR step skips release on empty tag" "yes" \
        "$(grep -q 'Empty `TAG` -> skip' "$s/n1-pr/steps/02-push-create.md" && echo yes || echo no)"
}

# N1-55: ask-mode child mirrors its question and accepts a relayed answer; n1-queue exposes --answer.
test_answer_wiring() {
    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless-ask.md"
    local s="$REPO_ROOT/skills/n1-queue/SKILL.md" r="$REPO_ROOT/skills/n1-queue/steps/report.md"
    assert_eq "answer-wiring: child writes question file" "yes" "$(grep -qF '.question-%s.json' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: child removes question file on answer" "yes" "$(grep -qF 'rm -f "$N1_QUEUE_DIR/.question-$ID.json"' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: child accepts relayed answer" "yes" "$(grep -qF '[n1-queue answer] ' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: SKILL documents --answer" "yes" "$(grep -qF -- '--answer <ticket> <text>' "$s" && echo yes || echo no)"
    assert_eq "answer-wiring: report calls n1_queue_answer" "yes" "$(grep -qF 'n1_queue_answer "$N1_HOME"' "$r" && echo yes || echo no)"
    assert_eq "answer-wiring: question schema carries rationale (RULE-1)" "yes" "$(grep -qF '"recommended","rationale"}' "$h" && grep -qF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: question schema documents optional alternatives (N1-216)" "yes" "$(grep -qF '"alternatives": {"<option label>": "works when <condition>"}' "$h" && grep -qF 'references/question-format.md' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: per-ticket answer file cleared before write" "yes" "$(grep -qF 'AF="$N1_HOME/queue/.answer-<ticket>.txt"; rm -f "$AF"' "$r" && echo yes || echo no)"
    assert_eq "answer-wiring: answer written via file-write mechanism" "yes" "$(grep -qF 'file-write mechanism' "$r" && echo yes || echo no)"
}

# NP-203: queue children apply plan-time pre-decisions; release gate never consults them.
test_headless_plan_wiring() {
    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless-predecision.md" l="$REPO_ROOT/skills/n1-start/ledger.md"
    assert_eq "headless-plan: looks up the Decisions row" "yes" "$(grep -q 'n1_queue_decisions_row "\$N1_QUEUE_DIR/queue.md"' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: logs [plan]" "yes" "$(grep -qF '[plan]' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: release gate excluded" "yes" "$(grep -q 'release confirmation gate never consults' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: ledger documents [plan]" "yes" "$(grep -qF '`[plan]`' "$l" && echo yes || echo no)"
    assert_eq "headless-plan: verifies queue.md run_id matches N1_QUEUE_RUN_ID (SEC-L1)" "yes" \
        "$(grep -q 'run_id 2>/dev/null)" = "\$N1_QUEUE_RUN_ID"' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: recomputes the content hash before honouring a pre-decision (SEC-1)" "yes" \
        "$(grep -qF 'n1_queue_content_hash' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: falls through to escalation on hash mismatch (SEC-1)" "yes" \
        "$(grep -qF 'MISMATCH' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: title and desc are written to files, never a bare shell string (SEC-1)" "yes" \
        "$(grep -q 'n1_queue_content_hash "\$M/.guard-live.title" "\$M/.guard-live.txt"' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: MATCH needs a non-empty live hash in the trusted set (SEC-5, NP-231)" "yes" \
        "$(grep -qF 'if [ -n "$NEW_HASH" ] && n1_desc_hash_is_trusted "$ID" "$NEW_HASH"; then echo MATCH; else echo MISMATCH; fi' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: trusted set names N1's recorded writes (.desc-hashes)" "yes" \
        "$(grep -qF '.desc-hashes' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: single-value equality against OLD_HASH is gone" "no" \
        "$(grep -qF '[ "$NEW_HASH" = "$OLD_HASH" ]' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: points at the chain procedure" "yes" \
        "$(grep -qF 'references/desc-hash-chain.md' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: checks for post-plan human comments (SEC-2)" "yes" \
        "$(grep -qF 'Comment check (SEC-2)' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: a post-plan comment falls through like MISMATCH (SEC-2)" "yes" \
        "$(grep -q 'created after .planned_at.: treat this exactly like .MISMATCH' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: guard re-fetch is marked for the capture hook (N1-326)" "yes" \
        "$(grep -qF 'n1_desc_mark guard "$ID"' "$h" && echo yes || echo no)"
}

# N1-293: --status and the story summary read ## Final PRs; docs name the human-merge policy and both events.
test_final_pr_wiring() {
    local r="$REPO_ROOT/skills/n1-queue/steps/report.md" a="$REPO_ROOT/references/architecture.md" u="$REPO_ROOT/skills/n1-queue/steps/run.md"
    assert_eq "final wiring: --status prints Final PRs" yes "$(grep -qF 'Final PRs (repo, PR, draft, mergeable, note):' "$r" && echo yes || echo no)"
    assert_eq "final wiring: summary reads Final PRs" yes "$(grep -qF 'FINAL=$(n1_queue_final_prs "$QUEUE_FILE" "$(dirname "$QUEUE_FILE")/events.jsonl" "$RUN_ID")' "$r" && echo yes || echo no)"
    assert_eq "final wiring: final lines above per-child lines" yes "$(grep -qF 'above the per-child lines' "$r" && echo yes || echo no)"
    assert_eq "final wiring: halted summary lists merged children" yes "$(grep -qF 'merged into `story/<STORY_ID>`' "$r" && echo yes || echo no)"
    assert_eq "final wiring: events documented" yes "$(grep -qF '`final_pr_opened`' "$a" && grep -qF '`final_pr_failed`' "$a" && echo yes || echo no)"
    assert_eq "final wiring: gated merge policy in run step" yes "$(grep -qF 'The runner merges the final PR only when' "$u" && echo yes || echo no)"
    assert_eq "final wiring: gated merge policy in architecture" yes "$(grep -qF 'The runner merges the final PR only when' "$a" && echo yes || echo no)"
    assert_eq "final wiring: no never-merge text left" no "$(grep -qF 'never merges the final PR' "$u" "$a" && echo yes || echo no)"
    assert_eq "final wiring: merge event documented" yes "$(grep -qF '`final_pr_merge`' "$a" && echo yes || echo no)"
    assert_eq "final wiring: summary says merged or waits" yes \
        "$(grep -qF 'waits for a human (<reason>)' "$r" && grep -qF 'Final PR merge: by the runner' "$r" && echo yes || echo no)"
}

# N1-183: launcher wiring (setsid with nohup fallback, liveness busy guard, interrupted resume/status).
test_lifecycle_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    has() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "wiring: runner launched with setsid" yes "$(has 'setsid bash "$N1_ROOT/scripts/n1-queue-run.sh"' "$s/steps/run.md")"
    assert_eq "wiring: nohup fallback when setsid is absent" yes "$(has 'command -v setsid' "$s/steps/run.md")"
    assert_eq "wiring: busy guard uses runner liveness" yes "$(has 'n1_queue_runner_alive "$OLD_PID"' "$s/steps/run.md")"
    assert_eq "wiring: --run detects an interrupted run" yes "$(has 'INTERRUPTED=yes' "$s/steps/run.md")"
    assert_eq "wiring: resume keeps the run id" yes "$(has 'if [ "<RESUME>" = 1 ]' "$s/steps/run.md")"
    assert_eq "wiring: --status reports interrupted runs" yes "$(has 'n1_queue_interrupted_note "$QUEUE_FILE"' "$s/steps/report.md")"
    assert_eq "wiring: --status reports dispatch skips (N1-309)" yes "$(has 'n1_queue_dispatch_skips' "$s/steps/report.md")"
    assert_eq "wiring: --status lists review-FAIL rows as awaiting (N1-616)" yes "$(has 'n1_queue_review_failed_rows "$QUEUE_FILE"' "$s/steps/report.md")"
    assert_eq "wiring: run.md streams the session watch (N1-359)" yes "$(has "the watch command's output lines to this session" "$s/steps/run.md")"
    assert_eq "wiring: report.md streams the adopted watch (N1-359)" yes "$(has "the watch command's output lines to this session" "$s/steps/report.md")"
    assert_eq "wiring: run.md re-arms the watch at the deadline (N1-359)" yes "$(has "start the identical command again" "$s/steps/run.md")"
    assert_eq "wiring: SKILL.md documents resume" yes "$(has 'resumes an interrupted run' "$s/SKILL.md")"
    assert_eq "N1-339: runner contains no worktree removal" 0 "$(grep -cE 'git worktree remove|n1_orca_rm|n1_finish_cleanup|n1_clean_ticket|worktree rm' "$REPO_ROOT/scripts/n1-queue-run.sh")"
    assert_eq "N1-339: chain_merged launches chain_clean" yes "$(grep -A6 '^chain_merged()' "$REPO_ROOT/scripts/n1-queue-run.sh" | grep -q 'chain_clean' && echo yes || echo no)"
    assert_eq "N1-339: chain_clean called from three merged paths" 3 "$(grep -c 'chain_clean "' "$REPO_ROOT/scripts/n1-queue-run.sh")"
}

# N1-185 AC3: run.md held-ticket wording (finish.md and session-start covered in test_orchestrator_guardrails.sh and test_hooks.sh).
test_merge_wording() {
    local has; has() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "wording: held tickets start on a user or chain merge" yes \
        "$(has "merged (by the user, or by the runner's fullAuto chain)" "$REPO_ROOT/skills/n1-queue/steps/run.md")"
    assert_eq "wording: SKILL.md names the story runner merge (N1-292)" yes \
        "$(has 'the runner itself merges each green, reviewed child PR into `story/<STORY_ID>`' "$REPO_ROOT/skills/n1-queue/SKILL.md")"
    assert_eq "wording: run.md story release (N1-292)" yes \
        "$(has 'once the runner merged the blocker into the story branch' "$REPO_ROOT/skills/n1-queue/steps/run.md")"
    assert_eq "wording: architecture documents story_merge (N1-292)" yes \
        "$(has 'Story mode (N1-292): the runner itself merges' "$REPO_ROOT/references/architecture.md")"
    assert_eq "wording: architecture lists ticket_done (N1-292)" yes \
        "$(has '`ticket_done` (N1-292' "$REPO_ROOT/references/architecture.md")"
}

# N1-291: every default-branch site reads n1_story_base; bump-skip and PR-base wording present.
test_story_base_wiring() {
    local ws="$REPO_ROOT/skills/n1-start/procedures/workspace-isolation.md"
    assert_eq "story-wiring: workspace-isolation calls n1_story_base in adopt and ensure" "2" "$(grep -c 'n1_story_base' "$ws")"
    assert_eq "story-wiring: adopt rebases onto the story tip" "yes" "$(grep -qF 'rebase "origin/$SB"' "$ws" && echo yes || echo no)"
    assert_eq "story-wiring: ensure cuts the branch from BASE" "yes" "$(grep -qF 'git branch <TARGET> "$BASE"' "$ws" && echo yes || echo no)"
    assert_eq "story-wiring: ensure keeps checkout of the default" "yes" "$(grep -qF 'git checkout $DEFAULT' "$ws" && echo yes || echo no)"
    assert_eq "story-wiring: adopt keeps the story-base STOP rule" "yes" \
        "$(grep -qF 'Story child: `story-base:` output → STOP and escalate (headless: pause with a recorded escalation).' "$ws" && echo yes || echo no)"
    local f
    for f in lib/review-step.sh skills/n1-start/steps/implementation.md lib/qa-step.sh \
             skills/n1-start/procedures/cross-repo.md skills/n1-review/steps/01-analyze.md; do
        assert_eq "story-wiring: $f calls n1_story_base" "yes" "$(grep -q 'n1_story_base' "$REPO_ROOT/$f" && echo yes || echo no)"
    done
    assert_eq "story-wiring: qa passes story base to break-check" "yes" \
        "$(grep -qF '"${SB:-${BC_DEF:-main}}"' "$REPO_ROOT/lib/qa-step.sh" && echo yes || echo no)"
    assert_eq "story-wiring: implementation bump skip" "yes" \
        "$(grep -q 'Story child: make no version-bump commit' "$REPO_ROOT/skills/n1-start/steps/implementation.md" && echo yes || echo no)"
    local pp="$REPO_ROOT/skills/n1-pr/steps/01-prepare.md" pc="$REPO_ROOT/skills/n1-pr/steps/02-push-create.md"
    assert_eq "story-wiring: prepare reads story base for DEFAULT_BRANCH and rules BASE" "3" "$(grep -c 'n1_story_base' "$pp")"
    assert_eq "story-wiring: prepare bump skip" "yes" "$(grep -q 'Story child or queue child: make no version-bump commit' "$pp" && echo yes || echo no)"
    assert_eq "story-wiring: rebase target via DEFAULT_BRANCH" "yes" "$(grep -qF 'git rebase "origin/$DEFAULT_BRANCH"' "$pc" && echo yes || echo no)"
    assert_eq "story-wiring: PR base via DEFAULT_BRANCH" "yes" "$(grep -qF -- '--base "$DEFAULT_BRANCH"' "$pc" && echo yes || echo no)"
    assert_eq "story-wiring: every push-create snippet re-derives the base from n1_story_base (SEC-1)" "4" "$(grep -c 'DEFAULT_BRANCH="\$SB"' "$pc")"
    assert_eq "story-wiring: adopt checkout re-anchors branch-point (CR-2)" "yes" \
        "$(grep -qF 'rev-parse "origin/$SB" > "$BP"' "$REPO_ROOT/skills/n1-start/procedures/workspace-isolation.md" && echo yes || echo no)"
    local sc="$REPO_ROOT/skills/n1-pr/procedures/story-child.md"
    assert_eq "story-wiring: story-child names the story branch" "yes" "$(grep -q 'never the default branch' "$sc" 2>/dev/null && echo yes || echo no)"
    assert_eq "story-wiring: prepare points story children at story-child.md under its trigger" "yes" \
        "$(grep -F 'skills/n1-pr/procedures/story-child.md' "$pp" | grep -qF '`STORY` not `none`' && echo yes || echo no)"
    assert_eq "story-wiring: push-create names story-child.md" "yes" "$(grep -qF 'procedures/story-child.md' "$pc" && echo yes || echo no)"
    assert_eq "story-wiring: story-child.md is not read at entry" "no" \
        "$(grep -qF 'story-child.md' "$REPO_ROOT/skills/n1-pr/SKILL.md" && echo yes || echo no)"
}

# N1-290: run.md documents the runner's story-branch step; its halt text matches the runner's.
test_story_branch_wiring() {
    local r="$REPO_ROOT/skills/n1-queue/steps/run.md" k="$REPO_ROOT/scripts/n1-queue-run.sh"
    _sbF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "story-branch wiring: run.md names the reader helper" "yes" "$(_sbF 'n1_queue_story_branch_get' "$r")"
    assert_eq "story-branch wiring: run.md quotes the halt" "yes" "$(_sbF 'HALTED: story branch story/<STORY_ID> could not be created or pushed in <repo>' "$r")"
    assert_eq "story-branch wiring: runner emits that halt" "yes" "$(_sbF 'HALTED: $RUN_MODE branch $RUN_MODE/$STORY_ID could not be created or pushed in $SB_REPO' "$k")"
}

# N1-440: tag attribute and planning-state wiring in run.md, runner and report.
test_queue_id_wiring() {
    local s="$REPO_ROOT/skills/n1-queue/steps"
    hasF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "id-wiring: plan frontmatter carries tag" "yes" "$(hasF 'tag: <--tag value in tag mode, else empty>' "$s/run.md")"
    assert_eq "id-wiring: saved plan advances state" "yes" "$(hasF 'n1_queue_plan_state step saved' "$s/run.md")"
    assert_eq "id-wiring: launch clears planning state" "yes" "$(hasF 'n1_queue_plan_state clear' "$s/run.md")"
    assert_eq "id-wiring: --plan stop clears planning state" "yes" "$(hasF 'n1_queue_plan_state clear`, then print "Plan saved' "$s/run.md")"
    assert_eq "id-wiring: report reads tag attribute" "yes" "$(hasF 'TAG=$(n1_read_frontmatter "$QUEUE_FILE" tag)' "$s/report.md")"
    assert_eq "id-wiring: runner reads tag attribute" "yes" "$(hasF 'N1_QUEUE_TAG=$(n1_read_frontmatter "$QUEUE" tag)' "$REPO_ROOT/scripts/n1-queue-run.sh")"
    # --run in a new session: input.md never ran, so the Hierarchy block's SRC comes from the saved frontmatter.
    assert_eq "id-wiring: saved plan restores SRC from frontmatter" "yes" "$(hasF 'SRC=$(n1_read_frontmatter "$QUEUE_FILE" story_id 2>/dev/null)' "$s/run.md")"
}

# N1-447: the chain push is lease-only; the runner tail and n1-finish (queue final PR path) call the chain script;
# run.md and architecture.md document it.
test_queue_chain_wiring() {
    local c="$REPO_ROOT/scripts/n1-queue-chain.sh" f7="$REPO_ROOT/skills/n1-finish/steps/07-queue-chain.md"
    assert_eq "chain-wiring: push pinned by a lease on the fetched tip" 1 "$(grep -cF -- '--force-with-lease=refs/heads/$OWN:$old' "$c")"
    assert_eq "chain-wiring: no unleased force push" 0 "$(grep -E 'push' "$c" | grep -cE -- '(^|[[:space:]])(-f|--force)([[:space:]]|$)|[[:space:]]\+HEAD' || true)"
    assert_eq "chain-wiring: final_prs runs the chain for a queue" 1 "$(grep -cF 'scripts/n1-queue-chain.sh" --own "queue/$RUN_STORY_ID" "$QUEUE"' "$REPO_ROOT/scripts/n1-queue-run.sh")"
    assert_eq "chain-wiring: n1-finish queue path points to step 7" yes \
        "$(grep -qF 'steps/07-queue-chain.md' "$REPO_ROOT/skills/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    assert_eq "chain-wiring: step 7 runs before the deploy watch and the Step 6 summary (N1-462)" yes \
        "$(grep -qF 'before Step 3' "$f7" && grep -qF 'then Step 6' "$REPO_ROOT/skills/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    assert_eq "chain-wiring: step 7 runs --all and ignores its exit" yes \
        "$(grep -qF 'scripts/n1-queue-chain.sh" --pred "<merged final PR url>" --all || true' "$f7" && echo yes || echo no)"
    assert_eq "chain-wiring: run.md documents it" yes \
        "$(grep -qF '**Queue chain (N1-447).**' "$REPO_ROOT/skills/n1-queue/steps/run.md" && echo yes || echo no)"
    assert_eq "chain-wiring: architecture documents it" yes \
        "$(grep -qF '**Queue chain (N1-447).**' "$REPO_ROOT/references/architecture.md" && echo yes || echo no)"
    assert_eq "close-wiring: step 7 lists landed children (N1-532)" yes \
        "$(grep -qF 'n1_queue_final_landed "<merged final PR url>"' "$f7" && echo yes || echo no)"
    assert_eq "close-wiring: step 7 finishes each child after the tracker move" yes \
        "$(grep -qF 'n1_queue_finish_child "<T>" "<child PR url>" "<merged final PR url>"' "$f7" && echo yes || echo no)"
    assert_eq "close-wiring: step 1 names the child close" yes \
        "$(grep -qF '§ Close landed children' "$REPO_ROOT/skills/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    assert_eq "close-wiring: a closed final PR lists children left open" yes \
        "$(grep -qF 'left open:' "$REPO_ROOT/skills/n1-finish/steps/02-merge.md" && echo yes || echo no)"
}

test_queue_integration_wiring() {
    local r="$REPO_ROOT/scripts/n1-queue-run.sh"
    assert_eq "queue-wiring: no story-only RUN_MODE gate" 0 "$(grep -c '\[ "\$RUN_MODE" = story \]' "$r" || true)"
    assert_eq "queue-wiring: six RUN_MODE integration gates" 6 "$(grep -c '\[ -n "\$RUN_MODE" \]' "$r" || true)"
    assert_eq "queue-wiring: final_pr passes the kind to body and cmd" 2 "$(grep -c '"\$body" "\$draft" "\$RUN_MODE")\|"\$SBID" "\$body" "\$RUN_MODE")' "$r" || true)"
    assert_eq "queue-wiring: n1-finish close step skips queue/ heads" yes \
        "$(grep -qF 'starts with `queue/`' "$REPO_ROOT/skills/n1-finish/steps/04-close-ticket.md" && echo yes || echo no)"
    assert_eq "queue-wiring: queue final PR watches the deploy and gates the child close (N1-462)" yes \
        "$(F="$REPO_ROOT/skills/n1-finish/steps"; ! grep -qF 'not watched; delivery not run (queue final PR)' "$F/04-close-ticket.md" "$F/06-cleanup.md" "$REPO_ROOT/skills/n1-queue/steps/run.md" \
            && grep -qF '## Queue deploy (N1-462)' "$F/07-queue-chain.md" \
            && grep -qF 'Deployment failed after merging <merged final PR url>: <run URL>' "$F/07-queue-chain.md" \
            && grep -qF 'skipped (queue final PR)' "$F/03-deploy.md" && grep -qF 'skipped (queue final PR)' "$F/06-cleanup.md" \
            && grep -qF '**Queue final PR (N1-462):**' "$F/03b-ssh-deploy.md" \
            && grep -qF 'watches the deploy on the merge commit' "$REPO_ROOT/skills/n1-queue/steps/run.md" && echo yes || echo no)"
    assert_eq "queue-wiring: final_merge launches n1-finish for queue final PRs only (N1-462)" yes \
        "$(grep -qF '[ "$RUN_MODE" = queue ] || return 0' "$r" && grep -qF 'final_finish "$REPO" "$url" "$N1H"' "$r" && echo yes || echo no)"
    assert_eq "queue-wiring: session-start skips queue-keyed deploy-pending dirs (N1-462)" yes \
        "$(grep -qF '[[ "$tid" == queue-* ]] && continue' "$REPO_ROOT/hooks/session-start.sh" && echo yes || echo no)"
    assert_eq "queue-wiring: n1-pr bump skip names queue children" yes \
        "$(grep -qF 'Story child or queue child' "$REPO_ROOT/skills/n1-pr/steps/01-prepare.md" && echo yes || echo no)"
    assert_eq "queue-wiring: run.md documents the queue integration branch" yes \
        "$(grep -qF '**Queue integration branch (N1-446).**' "$REPO_ROOT/skills/n1-queue/steps/run.md" && echo yes || echo no)"
    assert_eq "queue-wiring: architecture documents it" yes \
        "$(grep -qF 'Queue integration branch (N1-446)' "$REPO_ROOT/references/architecture.md" && echo yes || echo no)"
}


n1_only_filter
test_plan_wiring
test_list_input_wiring
test_story_epic_wiring
test_desc_chain_wiring
test_brief_wiring
test_retry_wiring
test_rerun_wiring
test_close_wiring
test_discard_wiring
test_form_repair_wiring
test_release_wiring
test_answer_wiring
test_headless_plan_wiring
test_final_pr_wiring
test_lifecycle_wiring
test_merge_wording
test_story_base_wiring
test_story_branch_wiring
test_queue_id_wiring
test_queue_chain_wiring
test_queue_integration_wiring

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

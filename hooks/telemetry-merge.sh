#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${1:?Usage: telemetry-merge.sh <run_id> <telemetry_dir>}"
TELEM_DIR="${2:?Usage: telemetry-merge.sh <run_id> <telemetry_dir>}"

STEPS_FILE="${TELEM_DIR}/raw/steps/${RUN_ID}.jsonl"
AGENTS_FILE="${TELEM_DIR}/raw/agents/${RUN_ID}.jsonl"
OUT_DIR="${TELEM_DIR}/runs"
OUT_FILE="${OUT_DIR}/${RUN_ID}.jsonl"

mkdir -p "$OUT_DIR"

# Read n1_version from lock file; derive ticket_id from directory path
N1_VERSION=""
TICKET_ID=""
LOCK_FILE="${TELEM_DIR}/telemetry.lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_CONTENT=$(cat "$LOCK_FILE")
    if command -v jq >/dev/null 2>&1; then
        N1_VERSION=$(echo "$LOCK_CONTENT" | jq -r '.n1_version // empty' 2>/dev/null || true)
    else
        N1_VERSION=$(echo "$LOCK_CONTENT" | grep -o '"n1_version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true)
    fi
fi
MEMORY_DIR=$(dirname "$TELEM_DIR")
TICKET_ID=$(basename "$MEMORY_DIR")

# Derive project name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
N1_HOME=$(n1_home)
if [ -n "$N1_HOME" ]; then
    PROJECT_NAME=$(basename "$N1_HOME")
else
    PROJECT_ROOT="${TELEM_DIR%%/.n1/*}"
    PROJECT_NAME="${PROJECT_ROOT##*/}"
fi

if command -v jq >/dev/null 2>&1; then

    # --- Static agent-to-step mapping ---
    STATIC_MAP='{
        "n1:product-analyst": ["ticket"],
        "n1:planner": ["plan"],
        "n1:code-reviewer": ["review"],
        "n1:security-reviewer": ["review"],
        "n1:codex-adapter": ["review"],
        "n1:tech-writer": ["pr"]
    }'

    # --- Parse step events: pair start/end by step_number ---
    STEPS_JSON="[]"
    if [ -f "$STEPS_FILE" ]; then
        STEPS_JSON=$(jq -s '
            [.[] | select(.layer == "step")] | group_by(.step_number) | map(
                (map(select(.started_at)) | first) as $start |
                (map(select(.completed_at)) | first) as $end |
                {
                    step: ($start // $end).step,
                    step_number: ($start // $end).step_number,
                    started_at: ($start.started_at // null),
                    completed_at: ($end.completed_at // null),
                    duration_s: (if $start.started_at and $end.completed_at then
                        (($end.completed_at | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
                         ($start.started_at | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
                    else null end),
                    outcome: ($end.outcome // "interrupted"),
                    loop_iteration: ($end.loop_iteration // null),
                    metadata: ($end.metadata // {})
                }
            ) | sort_by(.step_number)
        ' "$STEPS_FILE" 2>/dev/null || echo "[]")
    fi

    # --- Extract decision events ---
    DECISIONS_JSON="[]"
    if [ -f "$STEPS_FILE" ]; then
        DECISIONS_JSON=$(jq -s '[.[] | select(.event == "decision")]' "$STEPS_FILE" 2>/dev/null || echo "[]")
    fi

    # --- Extract outcome events ---
    OUTCOMES_JSON="[]"
    if [ -f "$STEPS_FILE" ]; then
        OUTCOMES_JSON=$(jq -s '[.[] | select(.event == "outcome")]' "$STEPS_FILE" 2>/dev/null || echo "[]")
    fi

    # --- Parse agent events: pair start/stop by agent_id ---
    AGENTS_RAW="[]"
    if [ -f "$AGENTS_FILE" ]; then
        AGENTS_RAW=$(jq -s '
            group_by(.agent_id) | map(
                (map(select(.event == "start")) | first) as $start |
                (map(select(.event == "stop")) | first) as $stop |
                {
                    agent_id: ($start // $stop).agent_id,
                    agent_type: ($start // $stop).agent_type,
                    started_at: ($start.started_at // null),
                    completed_at: ($stop.completed_at // null),
                    duration_s: (if $start.started_at and $stop.completed_at then
                        (($stop.completed_at | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
                         ($start.started_at | sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
                    else null end),
                    transcript_path: ($stop.transcript_path // null)
                }
            )
        ' "$AGENTS_FILE" 2>/dev/null || echo "[]")
    fi

    # --- Parse each transcript file ---
    AGENTS_JSON=$(echo "$AGENTS_RAW" | jq --argjson steps "$STEPS_JSON" --argjson smap "$STATIC_MAP" '
        [.[] | . as $agent |
            # Determine step via static map or temporal correlation
            ($smap[$agent.agent_type] // null) as $static_steps |
            (if $static_steps and ($static_steps | length) == 1 then
                $static_steps[0]
            elif $agent.started_at then
                # Temporal: find the step whose time window contains agent start
                ($steps | map(select(
                    .started_at and
                    .started_at <= $agent.started_at and
                    (.completed_at == null or .completed_at >= $agent.started_at)
                )) | first // null | .step // null)
            else null end) as $step |

            # Transcript parsing happens in bash below — placeholder nulls
            {
                agent_id: $agent.agent_id,
                agent_type: $agent.agent_type,
                step: $step,
                started_at: $agent.started_at,
                completed_at: $agent.completed_at,
                duration_s: $agent.duration_s,
                model: null,
                input_tokens: null,
                output_tokens: null,
                cache_read_tokens: null,
                cache_creation_tokens: null,
                api_calls: null,
                tool_calls: null,
                tools_used: null,
                parse_error: null,
                _transcript_path: $agent.transcript_path
            }
        ]
    ' 2>/dev/null || echo "[]")

    AGENT_COUNT=$(echo "$AGENTS_JSON" | jq 'length')
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        TPATH=$(echo "$AGENTS_JSON" | jq -r ".[$i]._transcript_path // empty")
        AID=$(echo "$AGENTS_JSON" | jq -r ".[$i].agent_id // empty")
        # Prefer the subagent's own transcript over the parent session transcript
        # (events recorded before the agent-stop hook resolved per-agent paths).
        case "$TPATH" in
            *"/subagents/"*) : ;;
            *)  if [ -n "$TPATH" ] && [ -n "$AID" ]; then
                    CAND="${TPATH%.jsonl}/subagents/agent-${AID}.jsonl"
                    [ -f "$CAND" ] && TPATH="$CAND"
                fi ;;
        esac
        if [ -n "$TPATH" ] && [ -f "$TPATH" ]; then
            TRANSCRIPT_DATA=$(jq -s '
                [.[] | select(.type == "assistant" and .message)] |
                {
                    model: (map(.message.model // empty) | first // null),
                    input_tokens: (map(.message.usage.input_tokens // 0) | add // 0),
                    output_tokens: (map(.message.usage.output_tokens // 0) | add // 0),
                    cache_read_tokens: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
                    cache_creation_tokens: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
                    api_calls: length,
                    tool_calls: ([.[] | .message.content[]? | select(.type == "tool_use")] | length),
                    tools_used: ([.[] | .message.content[]? | select(.type == "tool_use") | .name] | group_by(.) | map({(.[0]): length}) | add // {})
                }
            ' "$TPATH" 2>/dev/null || echo '{"parse_error":"transcript_parse_failed"}')

            AGENTS_JSON=$(echo "$AGENTS_JSON" | jq --argjson idx "$i" --argjson td "$TRANSCRIPT_DATA" '
                .[$idx] |= (
                    if $td.parse_error then . + {parse_error: $td.parse_error}
                    else . + {
                        model: $td.model,
                        input_tokens: $td.input_tokens,
                        output_tokens: $td.output_tokens,
                        cache_read_tokens: $td.cache_read_tokens,
                        cache_creation_tokens: $td.cache_creation_tokens,
                        api_calls: $td.api_calls,
                        tool_calls: $td.tool_calls,
                        tools_used: $td.tools_used
                    } end
                )
            ')
        elif [ -n "$TPATH" ]; then
            AGENTS_JSON=$(echo "$AGENTS_JSON" | jq --argjson idx "$i" '
                .[$idx].parse_error = "transcript_not_found"
            ')
        fi
    done

    # Remove internal _transcript_path field
    AGENTS_JSON=$(echo "$AGENTS_JSON" | jq '[.[] | del(._transcript_path)]')

    # --- Extract run envelope (merge open + close) ---
    RUN_ENVELOPE='{}'
    if [ -f "$STEPS_FILE" ]; then
        RUN_ENVELOPE=$(jq -s '
            (map(select(.layer == "envelope")) | first // {}) as $open |
            (map(select(.layer == "envelope_close")) | first // {}) as $close |
            $open + $close
        ' "$STEPS_FILE" 2>/dev/null || echo '{}')
    fi

    # --- Build summary ---
    SUMMARY=$(jq -n \
        --argjson steps "$STEPS_JSON" \
        --argjson agents "$AGENTS_JSON" \
        '{
            total_duration_s: ([$steps[].duration_s | select(. != null)] | add // 0),
            total_input_tokens: ([$agents[].input_tokens | select(. != null)] | add // 0),
            total_output_tokens: ([$agents[].output_tokens | select(. != null)] | add // 0),
            total_cache_read_tokens: ([$agents[].cache_read_tokens | select(. != null)] | add // 0),
            cache_efficiency: (
                ([$agents[].cache_read_tokens | select(. != null)] | add // 0) as $cr |
                ([$agents[].input_tokens | select(. != null)] | add // 0) as $it |
                if ($it + $cr) > 0 then (($cr * 100 / ($it + $cr)) | round / 100) else 0 end
            ),
            agent_spawns: ($agents | length),
            steps_completed: ([$steps[] | select(.outcome == "pass" or .outcome == "skip")] | length),
            steps_skipped: ([$steps[] | select(.outcome == "skip")] | length),
            review_fix_cycles: ([$steps[] | select(.step == "fix") | .loop_iteration // 0] | max // 0),
            qa_fix_cycles: ([$steps[] | select(.step == "qa" and .loop_iteration != null and .loop_iteration > 0)] | length)
        }
    ')

    # --- Assemble final record ---
    jq -n -c \
        --argjson envelope "$RUN_ENVELOPE" \
        --argjson steps "$STEPS_JSON" \
        --argjson agents "$AGENTS_JSON" \
        --argjson summary "$SUMMARY" \
        --argjson decisions "$DECISIONS_JSON" \
        --argjson outcomes "$OUTCOMES_JSON" \
        --arg run_id "$RUN_ID" \
        --arg n1_version "$N1_VERSION" \
        --arg project "$PROJECT_NAME" \
        '{
            schema_version: 1,
            run_id: $run_id,
            session_id: ($envelope.session_id // null),
            n1_version: $n1_version,
            project: $project,
            ticket_id: ($envelope.ticket_id // null),
            branch: ($envelope.branch // null),
            started_at: ($envelope.started_at // null),
            completed_at: ($envelope.completed_at // null),
            final_outcome: ($envelope.final_outcome // null),
            estimated_tier: ($envelope.estimated_tier // null),
            config_snapshot: ($envelope.config_snapshot // null),
            steps: $steps,
            agents: $agents,
            decisions: $decisions,
            outcomes: $outcomes,
            summary: $summary
        }
    ' > "$OUT_FILE"

else
    # No jq — try the python implementation before degrading to a minimal record.
    # Probe that the interpreter actually runs (pyenv-win shims can exist but fail).
    PY=""
    for cand in python3 python; do
        if command -v "$cand" >/dev/null 2>&1 &&             [ "$(printf x | "$cand" -c "import sys; print(sys.stdin.read())" 2>/dev/null)" = "x" ]; then
            PY="$cand"
            break
        fi
    done
    if [ -n "$PY" ] && "$PY" "${SCRIPT_DIR}/telemetry-merge.py" "$RUN_ID" "$TELEM_DIR" \
            --n1-version "$N1_VERSION" --project "$PROJECT_NAME" 2>/dev/null; then
        echo "telemetry-merge: jq not available, merged via python fallback" >&2
    else
        # Neither jq nor python — write a minimal record with raw file references
        echo "{\"schema_version\":1,\"run_id\":\"${RUN_ID}\",\"project\":\"${PROJECT_NAME}\",\"n1_version\":\"${N1_VERSION}\",\"ticket_id\":\"${TICKET_ID}\",\"parse_error\":\"jq_not_available\",\"raw_steps\":\"${STEPS_FILE}\",\"raw_agents\":\"${AGENTS_FILE}\"}" > "$OUT_FILE"
        echo "telemetry-merge: jq and python not available, wrote minimal record" >&2
    fi
fi

echo "Telemetry merged: ${OUT_FILE}" >&2

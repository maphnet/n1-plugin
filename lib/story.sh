#!/usr/bin/env bash
# N1 story workflow helpers

_N1_STORY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_N1_STORY_LIB_DIR}/config.sh"

N1_STORY_VALID_STEPS="intake analysis discovery design review publish decompose"

n1_parse_repos_arg() {
    local input="$1"
    case "$input" in
        *--repos\ *)
            local repos_val="${input##*--repos }"
            repos_val="${repos_val%% --*}"
            local rest="${input%%--repos*}"
            rest="${rest%% }"
            rest="${rest% }"
            local remaining="${input##*--repos }"
            remaining="${remaining#* }"
            if [ "$remaining" != "${input##*--repos }" ]; then
                rest="$rest $remaining"
            fi
            printf 'repos=%s id=%s' "$repos_val" "$rest"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

n1_story_step_dependencies() {
    local step="$1"
    case "$step" in
        intake)     printf '' ;;
        analysis)   printf 'ticket.md' ;;
        discovery)  printf 'ticket.md analysis.md' ;;
        design)     printf 'ticket.md analysis.md discovery.md' ;;
        review)     printf 'story-design.md story-overview.md' ;;
        publish)    printf 'ticket.md story-design.md story-overview.md' ;;
        decompose)  printf 'story-design.md story-overview.md' ;;
        *)          return 1 ;;
    esac
}

n1_story_step_number() {
    local step="$1"
    case "$step" in
        intake)     printf '1' ;;
        analysis)   printf '2' ;;
        discovery)  printf '3' ;;
        design)     printf '4' ;;
        review)     printf '5' ;;
        publish)    printf '6' ;;
        decompose)  printf '7' ;;
        *)          return 1 ;;
    esac
}

n1_parse_story_step_arg() {
    local input="$1"
    case "$input" in
        *--step\ *)
            local step_name="${input##*--step }"
            step_name="${step_name%% *}"
            local id_part="${input%%--step*}"
            id_part="${id_part%% }"
            id_part="${id_part% }"
            for valid in $N1_STORY_VALID_STEPS; do
                if [ "$step_name" = "$valid" ]; then
                    printf 'step=%s id=%s' "$step_name" "$id_part"
                    return 0
                fi
            done
            printf 'Invalid step name '\''%s'\''. Valid steps: %s\n' "$step_name" "$N1_STORY_VALID_STEPS" >&2
            return 2
            ;;
        *)
            return 1
            ;;
    esac
}

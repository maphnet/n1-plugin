# Review: cross-repo context (`RELATED_ENABLED=true`)

Read from `steps/review.md` before spawning reviewers. Append the printed `XREPO_REVIEW_CONTEXT` to both reviewer prompts.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/related.sh"
XREPO_REGISTERED=$(while IFS=$'\t' read -r slug reason _; do [ -z "$slug" ] && continue; printf '\n- %s (%s)' "$slug" "$reason"; done < <(n1_related_projects "$N1_HOME/config.json"))
SELF_SLUG=$(basename "$(n1_home)")
XREPO_KNOWN=$(for cfg in "${HOME}"/.n1/*/config.json; do [ -f "$cfg" ] || continue; peer=$(basename "$(dirname "$cfg")"); [ "$peer" = "$SELF_SLUG" ] && continue; printf '%s\n' "$peer"; done | tr '\n' ',' | sed 's/,$//')
XREPO_REVIEW_CONTEXT="REGISTERED RELATED PROJECTS:${XREPO_REGISTERED:-(none)}
N1-registered on this machine: ${XREPO_KNOWN}
Check diff for imports/API calls/env vars/service names pointing to N1-registered projects NOT above. Flag each [XREPO-N] (Low, non-blocking)."
echo "XREPO_REVIEW_CONTEXT=$XREPO_REVIEW_CONTEXT"
```

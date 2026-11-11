# Analysis: cross-repo context (`RELATED_ENABLED=true`)

Read from `steps/analysis.md` before the SA spawn. Run this fence now; append the printed `RELATED_CONTEXT` (empty: nothing) where the step says `append $RELATED_CONTEXT`. The sections below apply after the SA returns.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/context.sh"; n1_read_context
RELATED_CONTEXT=""
if [ "$LITE_MODE" != "true" ]; then
    MAX_AGE=72h; RELATED_LINES=""
    while IFS=$'\t' read -r slug reason repo_path; do [ -z "$slug" ] && continue
        RELATED_LINES="${RELATED_LINES}
- ${slug} (${reason}): map=$(n1_project_map_check_freshness "$(n1_related_project_map "$slug")" "$MAX_AGE" || echo cold) mapPath=$(n1_related_project_map "$slug") repo=${repo_path}"
    done < <(n1_related_projects "$N1_HOME/config.json")
    [ -n "$RELATED_LINES" ] && RELATED_CONTEXT="RELATED PROJECTS:${RELATED_LINES}
Fresh→read mapPath. Stale/cold→generate map (schema_version:1,generated_at,git_sha,git_sha_short,generator:solution-architect), emit XREPO_MAP_GENERATED:<slug>. Add '### Cross-Repo Context'."
fi
echo "RELATED_CONTEXT=$RELATED_CONTEXT"
```

## After the post-SA fence (the `n1_analysis_finalize` call)

Parse `XREPO_SUGGEST: <slug> <reason>` lines from `$N1_HOME/memory/$ID/sa-return.md`: `n1_related_add` + B-tier `[auto]` ledger row per slug.

## After Gate 1

**Headless:** `procedures/autonomy-headless.md § Headless Guard`.

## End of step (after the last step fence, `UNKNOWNS=`)

When `RELATED_ENABLED=true`: read `cross_repo_explored` signal; extract comma-separated XREPO_PROJECTS from `### Cross-Repo Context`; count `XREPO_MAPS_GENERATED`+`XREPO_DISCOVERY_NEW` lines in `$N1_HOME/memory/$ID/sa-return.md`; end the step: `n1_step_end "analysis" 2 success "{\"cross_repo_explored\":${XREPO_EXPLORED_BOOL:-false},\"cross_repo_projects\":\"${XREPO_PROJECTS}\",\"cross_repo_maps_generated\":${XREPO_MAPS_GENERATED},\"cross_repo_discovery_new\":${XREPO_DISCOVERY_NEW}}"`.

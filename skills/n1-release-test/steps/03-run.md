# Step 3: Automated Run

```bash
source ~/.n1/preamble.sh
DIR="$N1_HOME/releases/<LABEL>"
rm -f "$DIR/release-test-results.md"
[ -f "$N1_HOME/dev-access.md" ] && echo "access:yes" || echo "access:no"
IFS=$'\t' read -r VERIFIER_MODEL VERIFIER_EFFORT < <(n1_resolve_agent post-deploy-verifier)
echo "model=$VERIFIER_MODEL effort=$VERIFIER_EFFORT"
git rev-parse HEAD
```

Do not dispatch when the output shows `access:no` or when the plan has no `auto` or `assisted` case. Print "Automated run skipped: <reason>." and go to Step 4.

Otherwise dispatch persona `post-deploy-verifier` with that model and effort and wait for it to finish. Give it these absolute paths: `$DIR/release-test-plan.md`, `$DIR/release.diff`, `$N1_HOME/config.json`, `$N1_HOME/dev-access.md`, and the output path `$DIR/release-test-results.md`. Also give the HEAD commit SHA printed above and list the in-scope ticket IDs. State in the prompt that the plan path selects Release Mode.

A missing or malformed results file is not a failure of this step: Step 4 reports each `auto` case as `UNVERIFIED`. No PASS is inferred.

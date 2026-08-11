# CI/CD Deployment Detection

Reference consumed by n1-release and n1-init for GitHub Actions deployment pipeline detection.

## Detection Steps

1. Check if `.github/workflows/` exists. If not → **Category 1** (no workflows).
2. Read all `.yml`/`.yaml` files in `.github/workflows/`.
3. For each workflow file, identify:
   - **Triggers**: the `on:` block — look for `push`, `pull_request`, `release`, `workflow_dispatch`, `workflow_call`.
   - **Environments**: `jobs.<id>.environment:` (both bare string and `name:` sub-field forms). Match against: `dev`, `development`, `staging`, `stage`, `prod`, `production`.
   - **Deployment indicators**: step names or `run:` commands matching deployment keywords — `deploy`, `publish`, `aws`, `gcloud`, `az`, `kubectl`, `docker push`, `ssh`, `rsync`, `scp`, `helm`, `terraform`, `cdk`, `fly deploy`, `railway`, `vercel`, `netlify`.

## Classification Categories

Based on the detection, classify into exactly one category:

| # | Category | Condition |
|---|----------|-----------|
| 1 | **No workflows** | `.github/workflows/` does not exist or is empty |
| 2 | **No deployment workflows** | Workflows exist but none match deployment indicators |
| 3 | **Dev-only deployment** | Deployment workflow found, targets only dev/staging environments, no `on: release` trigger |
| 4 | **Prod without release trigger** | Deployment workflow targets prod but triggers on push/manual only, not `on: release` |
| 5 | **Release-triggered deployment** | Deployment workflow has `on: release` (any type filter) AND targets a prod environment |

Apply categories in order — first match wins. When a workflow has multiple jobs targeting different environments, classify by the highest-environment job (prod > staging > dev).

## Environment Detection Patterns

Check these locations for environment names:
- `jobs.<id>.environment: <name>` (bare string)
- `jobs.<id>.environment:` with `name: <name>` sub-field
- Environment variable references: `ENV=prod`, `ENVIRONMENT=production`, `DEPLOY_ENV=staging`
- Step names containing environment identifiers: "Deploy to production", "Push to staging"

Map to tiers:
- **Dev tier**: `dev`, `development`, `develop`
- **Staging tier**: `staging`, `stage`, `stg`, `qa`, `uat`, `preprod`, `pre-prod`
- **Prod tier**: `prod`, `production`, `prd`, `live`

## Output Format

Report a structured summary to the calling skill:
- **Category** (1-5) and its label
- **Workflow files** found with:
  - Filename
  - Triggers detected
  - Environments detected
  - Whether it contains deployment indicators
- **Best reuse candidate** (if category 3 or 4): the workflow file most suitable for adding a release trigger or cloning for prod

## Scaffolding Options by Category

### Category 1 (no workflows) / Category 2 (no deployment workflows)

Offer to create a new workflow file (e.g. `deploy-prod.yml`) triggered on `release: types: [published]`. Write it conversationally using project context — inspect existing files (Dockerfile, package.json, go.mod, etc.), build commands, registry patterns, and environment/secrets usage.

### Category 3 (dev-only deployment)

Present what was found. Offer two paths:
1. **Add release trigger to existing workflow** — add `on: release` and a prod environment conditional alongside the existing dev flow.
2. **Create a separate prod workflow** — write a new `deploy-prod.yml` reusing build steps from the dev workflow but targeting prod, triggered on release.

User picks one.

### Category 4 (prod without release trigger)

Present what was found. Offer two paths:
1. **Add release trigger** — add `release: types: [published]` to the existing workflow's `on:` block.
2. **Create a separate release workflow** — write a new workflow that calls the existing one via `workflow_call` or duplicates its prod job, triggered on release.

User picks one.

### Category 5 (release-triggered deployment exists)

No action needed. Report: "Deployment pipeline found: `<filename>` — triggered on release, targets `<environment>`."

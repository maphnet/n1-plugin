<!-- Purpose: Prerequisites, PR mode resolution, collect information, documentation update, generate PR content (Steps 1-3). -->

## Prerequisites

```bash
CURRENT_BRANCH=$(git branch --show-current)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
```

- On default branch → "Switch to a feature branch first." **STOP.**
- Uncommitted changes → commit first (summarize, ask confirmation).

## PR Mode Resolution

Read `git.prMode` via `n1_config_val '.git.prMode'`:
1. `git.prMode` present → use directly (`"draft"` | `"ready"`)
2. Else `git.draftPR` is `false` → `"ready"`
3. Else → `"draft"`

## Step 1: Collect Information

### Git context:
```bash
git log ${DEFAULT_BRANCH}..HEAD --oneline
git diff ${DEFAULT_BRANCH}...HEAD --stat
```

### N1 memory (if available):

Do NOT read full reports — tech-writer receives paths and reads them itself. Extract only:
- `overview.md` — read in full (small: ticket title, status, key decisions)
- Verdict lines via single Bash call:

```bash
grep -m1 -iE 'verdict' "$N1_HOME/memory/$ID/review.md" 2>/dev/null || true
grep -m1 -iE 'verdict|overall' "$N1_HOME/memory/$ID/qa.md" 2>/dev/null || true
grep -m1 -iE 'verdict|result' "$N1_HOME/memory/$ID/local-testing.md" 2>/dev/null || true
```

Missing grep results are non-blocking — they feed report text only.

### N1 config:
Read from `$N1_HOME/config.json`: `tracker.prefix`, `tracker.mcp`, `git.defaultBranch`, `git.branchPattern`.

### Extract ticket ID:
Parse from branch name using `git.branchPattern` (e.g. branch `TRID-510` + pattern `{prefix}-{id}` → `TRID-510`).

## Step 2: Documentation Update

**Spawn agent:** tech-writer (Phase 1 only). Resolve model for `tech-writer`.

### Doc config:
From `$N1_HOME/config.json` optional `docs` section: `docs.include` (globs), `docs.exclude` (globs), `docs.autoUpdate` (bool, default `false`).

### Mode:
- Called with `docUpdateMode: "autonomous"` (from n1-start) → `autonomous`
- `docs.autoUpdate` is `true` → `autonomous`
- Otherwise → `confirm`

### Spawn tech-writer Phase 1 with:
Default branch, paths to `implementation.md` (if available), git diff stat, doc config (`include`/`exclude`), doc update mode.

### If `confirm` mode:
**Autonomy gate:** if `$(n1_autonomy_val 'mechanicalPrompts')` is `auto`, skip the prompt — apply updates and append a Decision Ledger row per `skills/n1-start/ledger.md` (step `pr`, category `mechanical`, tier `C`, tag `[auto]`, reason `mechanicalPrompts=auto`). Pipeline invocations already bypass via `docUpdateMode: "autonomous"`.

Otherwise present updates and ask: "Apply or skip? (apply/skip)"

### If `autonomous` mode:
Tech-writer applies and commits without prompting.

### No stale docs found:
Proceed to Step 3.

## Step 3: Generate PR Content

The PR body goes to a file, so it never passes through the orchestrator's own output. Create the file first:

```bash
source ~/.n1/preamble.sh
ID="<ticket ID from Step 1, or empty>"
case "$ID" in *[!A-Za-z0-9_-]*) ID="";; esac
mkdir -p "$N1_HOME/scratch"
find "$N1_HOME/scratch" -maxdepth 1 -name 'pr-body-*' -mtime +1 -delete 2>/dev/null
PR_BODY_FILE=$(mktemp "$N1_HOME/scratch/pr-body-${ID:-pr}.XXXXXX") || { echo "pr:body-file unavailable"; exit 1; }
echo "pr:body-file=$PR_BODY_FILE"
```

`pr:body-file unavailable` → stop: "PR body file unavailable — PR not created."

**If PR title and body provided as input** (e.g. from n1-start): use the title directly, write the body to the `pr:body-file=` path with the file-write mechanism, skip tech-writer, and go to **Check the body file**.

**Otherwise (standalone):**

**Spawn agent:** tech-writer. Resolve model.

**Collect inferred-criteria context:**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/config.sh"
DQ=$(n1_read_frontmatter "$N1_HOME/memory/$ID/ticket.md" "description_quality" 2>/dev/null || echo "adequate")
[ -z "$DQ" ] && DQ="adequate"
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm')
BRAINSTORM_GATE_SKIPPED=false
[ "${BRAINSTORM_MODE:-ask}" = "auto" ] && BRAINSTORM_GATE_SKIPPED=true
```

Spawn tech-writer with: ticket ID, paths to `overview.md`/`review.md`/`qa.md`/`local-testing.md` (if exists)/`ticket.md` (if exists), git diff stat, Phase 1 doc update report, `description_quality: $DQ`, `brainstorm_gate_skipped: $BRAINSTORM_GATE_SKIPPED`, `body_file: <the pr:body-file= path>`.

It writes the body to `body_file` and returns the `### Title` plus one line `pr body written: <path>`.

**Check the body file:**

```bash
source ~/.n1/preamble.sh
PR_BODY_FILE="<the path from pr:body-file=>"
[ -s "$PR_BODY_FILE" ] && echo "pr:body ok" || echo "pr:body missing"
```

`pr:body missing` after tech-writer → dispatch tech-writer once more with the same inputs and re-run the check. If it is still missing (or missing on the input path) → stop: "PR body missing — PR not created." Otherwise `gh pr create --body-file` would create a PR with an empty body.

**Autonomy gate:** if `$(n1_autonomy_val 'mechanicalPrompts')` is `auto`, skip the prompt — create PR as composed, append Decision Ledger row (step `pr`, category `mechanical`, tier `C`, tag `[auto]`, reason `mechanicalPrompts=auto`). Pipeline invocations already bypass.

Otherwise: present the title and the body file contents, ask **"Create PR with this content? (yes/edit/cancel)"**. On `edit`, rewrite the body file with the file-write mechanism; title edits stay inline.

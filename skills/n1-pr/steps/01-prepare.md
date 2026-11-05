<!-- Purpose: Prerequisites, PR mode resolution, collect information, documentation update, generate PR content (Steps 1-3). -->

## Prerequisites

```bash
CURRENT_BRANCH=$(git branch --show-current)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
```

- On default branch → "Switch to a feature branch first." **STOP.**
- Uncommitted changes → commit first (summarize, ask confirmation).

## Codex Review (pre-push)

Runs once, before docs, PR body, rebase and push, so Codex fixes land in the first push (N1-405). Skipped, failed and timed-out reviews record a receipt and never block PR creation. Only a scope-gate `kept=` (unvetted commits that could not be reset) ends n1-pr before the push.

```bash
source ~/.n1/preamble.sh
ID='<the ticket ID, or empty>'
case "$ID" in *[!A-Za-z0-9_-]*) ID="";; esac
DEFAULT_BRANCH='<DEFAULT_BRANCH from Prerequisites>'
case "$DEFAULT_BRANCH" in ''|*[!A-Za-z0-9._/-]*) DEFAULT_BRANCH=main;; esac
git fetch -q origin "$DEFAULT_BRANCH" </dev/null 2>/dev/null || true   # step 2 fetches later; a stale origin ref would widen the reviewed diff and the scope allowlist
BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null) || BASE=""
echo "base=$BASE"
[ -z "$ID" ] || rm -f "$N1_HOME/memory/$ID/codex-triage.md" "$N1_HOME/memory/$ID/codex-review.md"
bash "$N1_ROOT/scripts/codex-pr-review.sh" "$BASE" "$ID"
```

Wait for completion (auth 10 s, `N1_CODEX_AUTH_TIMEOUT`; review 900 s, `N1_CROSS_HOST_REVIEW_TIMEOUT`). Remember the `codex_review_outcome` word and `base=`. The raw output is in `memory/<ID>/codex-review.md`; never read it.
- `ran`, `crossHostReview_autoTriage=true`, `findings:file=<path>` and a non-empty ID: read `<N1_ROOT>/skills/n1-pr/procedures/codex-triage.md` and follow it. It passes the path to the triage persona (never read that file yourself) and returns here.
- `ran` with `findings:unavailable`, no findings line, `crossHostReview_autoTriage=false`, or an empty ID: warn inline and remember the follow-up item `Codex review findings: see ticket memory codex-review.md` for the step 3 Report.
- Anything else continues.

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

### Rules for tech-writer:
Run once; copy the printed output verbatim as RULES_BLOCK (shell variables do not persist between snippets). Empty output = no rules.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/rules.sh"
BASE=$(n1_config_val '.git.defaultBranch'); BASE="${BASE:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}"; BASE="${BASE:-main}"
git rev-parse --verify -q "origin/$BASE" >/dev/null && BASE="origin/$BASE"
RULES_DIR=$(n1_rules_dir)
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    MATCHING=$(n1_rules_for_agent "tech-writer" "$(git diff --name-only "$BASE...HEAD" 2>/dev/null)" "$RULES_DIR")
    if [ -n "$MATCHING" ]; then n1_rules_render $MATCHING; fi
fi
```

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

### Record the pre-docs head:
```bash
source ~/.n1/preamble.sh
ID="<ticket ID from Step 1, or empty>"
case "$ID" in *[!A-Za-z0-9_-]*) ID="";; esac
[ -z "$ID" ] || [ ! -d "$N1_HOME/memory/$ID" ] || git rev-parse HEAD > "$N1_HOME/memory/$ID/docs-from-sha"
```

### Spawn tech-writer Phase 1 with:
Default branch, paths to `implementation.md` (if available), git diff stat, doc config (`include`/`exclude`), doc update mode, `RULES_BLOCK` (verbatim; omit when empty).

### If `confirm` mode:
**Autonomy gate:** if `$(n1_autonomy_val 'mechanicalPrompts')` is `auto`, skip the prompt — apply updates and append a Decision Ledger row per `skills/n1-start/ledger.md` (step `pr`, category `mechanical`, tier `C`, tag `[auto]`, reason `mechanicalPrompts=auto`). Pipeline invocations already bypass via `docUpdateMode: "autonomous"`.

Otherwise present updates and ask: "Apply or skip? (apply/skip)"

### If `autonomous` mode:
Tech-writer applies and commits without prompting.

### After the doc updates are applied or skipped:
Record the post-docs head so `n1_review_pin set` accepts the doc commit without a re-review (no commit: the record is a no-op link):
```bash
source ~/.n1/preamble.sh
ID="<ticket ID from Step 1, or empty>"
case "$ID" in *[!A-Za-z0-9_-]*) ID="";; esac
n1_head_record "$(cat "$N1_HOME/memory/${ID:-}/docs-from-sha" 2>/dev/null)"
```

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

**If PR title and body provided as input:** write the title (one line) to `<the pr:body-file= path>.title` and the body to the `pr:body-file=` path with the file-write mechanism, skip tech-writer, and go to **Check the body file**.

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

Spawn tech-writer with: ticket ID, paths to `overview.md`/`review.md`/`qa.md`/`local-testing.md` (if exists)/`ticket.md` (if exists), git diff stat, Phase 1 doc update report, `description_quality: $DQ`, `brainstorm_gate_skipped: $BRAINSTORM_GATE_SKIPPED`, `body_file: <the pr:body-file= path>`, `RULES_BLOCK` (verbatim; omit when empty).

It writes the body to `body_file` and the title to `<body_file>.title`, and returns the `### Title` plus one line `pr body written: <path>`.

**Check the body file:**

```bash
source ~/.n1/preamble.sh
PR_BODY_FILE="<the path from pr:body-file=>"
case "$PR_BODY_FILE" in "$N1_HOME"/scratch/pr-body-*/*) echo "PR body path invalid"; exit 1;; "$N1_HOME"/scratch/pr-body-*) ;; *) echo "PR body path invalid"; exit 1;; esac
[ -s "$PR_BODY_FILE" ] && [ -s "$PR_BODY_FILE.title" ] && echo "pr:body ok" || echo "pr:body missing"
```

`pr:body missing` after tech-writer → dispatch tech-writer once more with the same inputs (including `RULES_BLOCK`) plus `phase: 2` (skip Phase 1; the docs are already updated and committed) and re-run the check. If it is still missing (or missing on the input path) → stop: "PR body missing — PR not created." Otherwise `gh pr create --body-file` would create a PR with an empty body.

**Autonomy gate:** if `$(n1_autonomy_val 'mechanicalPrompts')` is `auto`, skip the prompt — create PR as composed, append Decision Ledger row (step `pr`, category `mechanical`, tier `C`, tag `[auto]`, reason `mechanicalPrompts=auto`). Pipeline invocations already bypass.

Otherwise: present the title and the body file contents, ask **"Create PR with this content? (yes/edit/cancel)"**. On `edit`, rewrite the body file with the file-write mechanism; on a title edit, rewrite `$PR_BODY_FILE.title` the same way.

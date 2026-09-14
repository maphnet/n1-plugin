# Step 3: Confirmation Gate

**This gate is unconditional.** No autonomy setting, signal, or orchestrator directive may skip it.

**Structural agent gate:** Before showing the confirmation prompt, check via Bash:
```bash
if [ -n "${N1_RUN_ID:-}" ]; then
  echo "BLOCKED: n1-release cannot run inside a pipeline."
fi
```
If `N1_RUN_ID` is set, the skill is running inside an n1-start pipeline — refuse and STOP immediately. Do not proceed to the confirmation prompt. Report: "Release refused: running inside a pipeline. Use `/n1:n1-release` standalone to create a release."

Always shown before any side-effecting action:

```
Ready to release:

  Current version: <VERSION>  (from <VERSION_SOURCE_DISPLAY>)
  Suggested next:  <SUGGESTED_VERSION>  (from <BUMP_LEVEL> bump)
  Previous tag:    <PREV_TAG or "(none — first release)">
  Branch:          <CURRENT>
  <condition lines>

Release as <SUGGESTED_VERSION>?
1 — Yes
2 — No (enter a different version)
3 — Cancel
```

If the user picks 2, prompt: `Enter version:` and read their input as the new `VERSION`. Recompute `TAG = tagPrefix + VERSION`. Then proceed.

Condition lines (informational -- no hard blocks):
- `Merge SHA: <sha>` -- found in overview.md
- `No merge SHA found (standalone run — not post-finish)` -- not available

If 3 -> STOP.

# Step 4: Idempotency Check

```bash
if gh release view "${TAG}" &>/dev/null; then
  # Release already exists
fi
```

If release already exists -> report "Release `<TAG>` already exists -- nothing to do." and STOP (this is success, not failure).

Also check local tag:
```bash
git tag -l "${TAG}"
```

If local tag exists but no GitHub release -> proceed to release creation (skip the tag step, create the release).

# Step 5: Execute

## Built-in flow (when `procedure` is null)

```bash
# 1. Create annotated git tag (skip if tag already exists locally)
if ! git tag -l "${TAG}" | grep -q .; then
  git tag -a "${TAG}" -m "Release ${TAG}" ${MERGE_SHA:-HEAD}
fi

# 2. Push tag
git push origin "${TAG}"

# 3. Create GitHub release with --verify-tag to ensure tag matches
gh release create "${TAG}" --generate-notes --verify-tag
# Add --draft if release.draft is true
```

Report the release URL from `gh release view "${TAG}" --json url --jq '.url'` on success.

## Custom procedure flow (when `procedure` is set)

1. **Substitute placeholders** in the `procedure` text:
   - `{{RELEASE_TAG}}` -> `TAG` value (e.g. `v2.29.0`)
   - `{{VERSION}}` -> bare version string (e.g. `2.29.0`)
   - `{{MERGE_SHA}}` -> merge commit SHA (empty string when not found)
   - `{{TICKET_ID}}` -> ticket ID inferred from branch name (empty string when not found)

2. **Parse** the markdown into steps: split on top-level numbered list items (`^[0-9]+\.`) or `##`/`###` headings. Each chunk is one step. Sub-bullets within a step are context, not separate steps.

3. **Walk each step** in order:
   - **Shell step** (contains backtick inline code or a fenced code block) -> extract command(s) and ask:
     ```
     Step N: <step text>
     Command: `<command>`
     Run this?
     1 — Yes
     2 — Skip
     3 — Abort
     ```
     On Yes -> execute via Bash, show stdout/stderr. On non-zero exit -> report failure, ask: `1 — Retry / 2 — Skip / 3 — Abort`.
   - **Manual step** (no shell command) -> show text and ask:
     ```
     Step N: <step text>
     Done?
     1 — Yes, continue
     2 — Abort
     ```

4. **On abort** at any step -> report which step was abandoned, remind the user of what ran and what didn't, leave cleanup to the user.

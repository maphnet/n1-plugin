#!/usr/bin/env bash
# NP-226: the shared deployment-actions procedure parses and ticks PR bodies, and every call site references it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=references/deployment-actions.md
unset N1_QUEUE_RUN_ID N1_HEADLESS

check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first occurrence of a precedes first occurrence of b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
snippet() { # first ```bash block after the heading line $1 in $P
    awk -v h="$1" 'index($0, h) == 1 {f = 1; next} f && /^```bash/ {b = 1; next} b && /^```/ {exit} b' "$P" 2>/dev/null
}

# --- procedure structure and guards
check "procedure has Parse section" "^## § Parse" "$P"
check "procedure has Walk section" "^## § Walk" "$P"
check "procedure has Tick section" "^## § Tick" "$P"
check "procedure has Conflicts section" "^## § Conflicts" "$P"
check "procedure has Unwatched Deploy section" "^## § Unwatched Deploy" "$P"
check "procedure has Runbook section" "^## § Runbook" "$P"
check "walk is an unconditional gate" "never auto-resolve" "$P"
check "walk offers Yes/Skip/Abort" "3 — Abort" "$P"
check "queue/headless detection" "N1_QUEUE_RUN_ID.*N1_HEADLESS" "$P"
check "runbook parks the ticket via deploy_pending" "deploy_pending true" "$P"
check "tick re-fetches before editing" "Re-fetch right before the edit" "$P"
check "tick writes via gh pr edit --body-file" "gh pr edit .*--body-file -" "$P"
check "architecture.md documents the procedure" "references/deployment-actions\.md" references/architecture.md

# --- behavior: § Parse and § Tick against a stubbed gh (CRLF body, ticked item, items outside the section)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "pr view") cat "$GH_BODY" ;;
    "pr edit") cat > "$GH_EDITED" ;;
esac
EOF
chmod +x "$T/bin/gh"
printf '## Summary\r\n- [ ] not an action\r\n\r\n## Deployment Actions\r\n\r\n### Before deploy\r\n- [ ] Manual: set secret STRIPE_KEY\r\n- [x] `echo already-done`\r\n\r\n### After deploy\r\n- [ ] `npm run backfill -- --since "2026-01-01"`\r\n\r\n## Ticket\r\n- [ ] also not an action\r\n' > "$T/body.md"
export GH_BODY="$T/body.md" GH_EDITED="$T/edited.md"
TSV="$T/a.tsv"
run() { PATH="$T/bin:$PATH" bash -c "$(snippet "$1" | sed -e '/preamble\.sh/d' -e 's|^PRS=.*|PRS="7"|' -e "s|^OUT=.*|OUT=\"$TSV\"|" -e 's|^K=.*|K=2|')"; }

out=$(run "## § Parse")
check "parse prints mode:walk interactively" "^mode:walk$" <(printf '%s\n' "$out")
check "parse counts unticked items" "^unticked:2$" <(printf '%s\n' "$out")
[ "$(sed -n 1p "$TSV" 2>/dev/null)" = "$(printf '7\tbefore\tbefore\tManual: set secret STRIPE_KEY')" ] \
    && echo "PASS: parse row 1 (before, manual)" || { echo "FAIL: parse row 1"; FAIL=1; }
[ "$(sed -n 2p "$TSV" 2>/dev/null)" = "$(printf '7\tafter\tafter\t`npm run backfill -- --since "2026-01-01"`')" ] \
    && echo "PASS: parse row 2 (after, shell, CR stripped)" || { echo "FAIL: parse row 2"; FAIL=1; }
out=$(export N1_HEADLESS=1; run "## § Parse")
check "parse prints mode:runbook when headless" "^mode:runbook$" <(printf '%s\n' "$out")

out=$(run "## § Tick")
check "tick reports success" "^ticked:#7$" <(printf '%s\n' "$out")
check "tick flips exactly the chosen item" '^- \[x\] `npm run backfill -- --since "2026-01-01"`$' "$T/edited.md"
check "tick leaves other items unticked" '^- \[ \] Manual: set secret STRIPE_KEY$' "$T/edited.md"
[ "$(grep -c $'\r' "$T/edited.md" 2>/dev/null)" = "0" ] && echo "PASS: tick writes LF-only body" || { echo "FAIL: tick left CR"; FAIL=1; }

# --- behavior: § Command extraction (bytes identical for quotes and $; >2 backticks -> manual)
TSV2="$T/cmd.tsv"
printf '9\tafter\tafter\t`echo "$VAR value"`\n9\tafter\tafter\tRun `cmd1` then `cmd2`\n' > "$TSV2"
run2() { PATH="$T/bin:$PATH" bash -c "$(snippet "$1" | sed -e '/preamble\.sh/d' -e "s|^OUT=.*|OUT=\"$TSV2\"|" -e "s|^K=.*|K=$2|")"; }

out=$(run2 "## § Command" 1)
check "command extraction reports shell" "^shell$" <(printf '%s\n' "$out")
[ "$(cat "$TSV2.cmd" 2>/dev/null)" = 'echo "$VAR value"' ] \
    && echo 'PASS: command bytes identical (quotes and $)' || { echo 'FAIL: command bytes differ'; FAIL=1; }

out=$(run2 "## § Command" 2)
check "command extraction falls back to manual for >2 backticks" "^manual$" <(printf '%s\n' "$out")

# --- behavior: § Command classification (SEC-7): Manual: prefix always manual; shell requires leading
# backtick + exactly two backticks + non-empty command; shell classification followed by a manual item
# leaves no stale .cmd file; empty backticks -> manual
TSV5="$T/cmd2.tsv"
printf '9\tafter\tafter\tManual: set env var `X`\n' > "$TSV5"
printf '9\tafter\tafter\t`echo "$HOME" '"'"'q'"'"'`\n' >> "$TSV5"
printf '9\tafter\tafter\t``\n' >> "$TSV5"
run5() { PATH="$T/bin:$PATH" bash -c "$(snippet "## § Command" | sed -e '/preamble\.sh/d' -e "s|^OUT=.*|OUT=\"$TSV5\"|" -e "s|^K=.*|K=$1|")"; }

out=$(run5 2)
check "command: leading-backtick two-backtick item classified shell" "^shell$" <(printf '%s\n' "$out")
[ "$(cat "$TSV5.cmd" 2>/dev/null)" = 'echo "$HOME" '"'"'q'"'"'' ] \
    && echo 'PASS: command bytes identical for quotes and apostrophes' || { echo 'FAIL: command bytes differ (quotes/apostrophes)'; FAIL=1; }

out=$(run5 1)
check "command: Manual: prefix always classified manual" "^manual$" <(printf '%s\n' "$out")
[ ! -f "$TSV5.cmd" ] && echo "PASS: shell-then-manual clears the .cmd file" || { echo "FAIL: .cmd file left behind after a manual item"; FAIL=1; }

out=$(run5 3)
check "command: empty backticks classified manual" "^manual$" <(printf '%s\n' "$out")

# --- behavior: § Tick is phase-scoped, and reports tick-missing without editing when the item is not found in that phase
cat > "$T/body-phase.md" <<'EOF'
## Deployment Actions

### Before deploy
- [ ] `echo same`

### After deploy
- [ ] `echo same`
EOF
export GH_BODY="$T/body-phase.md" GH_EDITED="$T/edited-phase.md"
rm -f "$T/edited-phase.md"
TSV3="$T/phase.tsv"
printf '8\tafter\tafter\t`echo same`\n' > "$TSV3"
run3() { PATH="$T/bin:$PATH" bash -c "$(snippet "## § Tick" | sed -e '/preamble\.sh/d' -e "s|^OUT=.*|OUT=\"$TSV3\"|" -e 's|^K=.*|K=1|')"; }

out=$(run3)
check "tick is phase-scoped: reports success" "^ticked:#8$" <(printf '%s\n' "$out")
[ "$(grep -A1 '^### After deploy' "$T/edited-phase.md" | tail -1)" = '- [x] `echo same`' ] \
    && echo "PASS: tick is phase-scoped: flips only the after-deploy line" || { echo "FAIL: tick did not flip the after-deploy line"; FAIL=1; }
[ "$(grep -A1 '^### Before deploy' "$T/edited-phase.md" | tail -1)" = '- [ ] `echo same`' ] \
    && echo "PASS: tick is phase-scoped: before-deploy line untouched" || { echo "FAIL: tick flipped the wrong phase"; FAIL=1; }

printf '8\tafter\tafter\t`echo different`\n' > "$TSV3"
rm -f "$T/edited-phase.md"
out=$(run3)
check "tick detects no match" "^tick-missing:#8$" <(printf '%s\n' "$out")
[ ! -f "$T/edited-phase.md" ] && echo "PASS: tick-missing never calls gh pr edit" || { echo "FAIL: tick-missing still edited the PR"; FAIL=1; }

# --- behavior (finding 1): § Edit moves execution phase (column 3) only; § Tick still matches on the
# original PR-body phase (column 2), so a before->after move at the gate still ticks the before-deploy line.
cat > "$T/body-move.md" <<'EOF'
## Deployment Actions

### Before deploy
- [ ] `echo moved`

### After deploy
EOF
export GH_BODY="$T/body-move.md" GH_EDITED="$T/edited-move.md"
rm -f "$T/edited-move.md"
TSV4="$T/move.tsv"
printf '8\tbefore\tbefore\t`echo moved`\n' > "$TSV4"
edit4() { PATH="$T/bin:$PATH" bash -c "$(snippet "**Edit**" | sed -e '/preamble\.sh/d' -e "s|^OUT=.*|OUT=\"$TSV4\"|" -e 's|^K=.*|K=1|' -e 's|^P=.*|P=after|')"; }
edit4
[ "$(sed -n 1p "$TSV4")" = "$(printf '8\tbefore\tafter\t`echo moved`')" ] \
    && echo "PASS: edit moves phase column only, orig phase untouched" || { echo "FAIL: edit did not preserve orig phase"; FAIL=1; }
run4() { PATH="$T/bin:$PATH" bash -c "$(snippet "## § Tick" | sed -e '/preamble\.sh/d' -e "s|^OUT=.*|OUT=\"$TSV4\"|" -e 's|^K=.*|K=1|')"; }
out=$(run4)
check "tick after move still succeeds" "^ticked:#8$" <(printf '%s\n' "$out")
[ "$(grep -A1 '^### Before deploy' "$T/edited-move.md" | tail -1)" = '- [x] `echo moved`' ] \
    && echo "PASS: tick after move flips the Before deploy line (where the text actually lives)" || { echo "FAIL: tick after move did not flip Before deploy"; FAIL=1; }

# --- agents
TW=agents/tech-writer.md
check "tech-writer template has Deployment Actions" "^## Deployment Actions" "$TW"
check "tech-writer template has Before deploy" "^### Before deploy" "$TW"
check "tech-writer template has After deploy" "^### After deploy" "$TW"
check "tech-writer scans the diff for vars/secrets" '\(vars\|secrets\)' "$TW"
check "tech-writer never writes secret values" "Secret values never appear" "$TW"
check "tech-writer omits the section when empty" "Omit .## Deployment Actions. entirely" "$TW"
PA=agents/product-analyst.md
check "product-analyst ticket.md has Deployment Actions" "^### Deployment Actions" "$PA"
check "product-analyst copies it verbatim" "Deployment Actions rule" "$PA"

# --- n1-finish
F2=skills/n1-finish/steps/02-merge.md
check "finish Step 2 parses deployment actions" "deployment-actions\.md. § Parse" "$F2"
check "finish Step 2 walks before-deploy items" "PHASE=before" "$F2"
check "finish Step 2 queue/headless writes the runbook" "§ Runbook" "$F2"
check "finish Step 2 aborted walk blocks the merge" "Merge blocked" "$F2"
before "finish: deployment actions precede gh pr merge" "deployment-actions.md" "gh pr merge <n> --auto" "$F2"
F4=skills/n1-finish/steps/04-close-ticket.md
check "finish Step 4 walks after-deploy items" "PHASE=after" "$F4"
check "finish Step 4 asks when no deploy was watched" "§ Unwatched Deploy" "$F4"
check "finish Step 4 clears deploy_pending" "deploy_pending false" "$F4"
before "finish: after-deploy follows the delivery gate" "03b-ssh-deploy.md" "deployment-actions.md" "$F4"

# --- n1-release
R1=skills/n1-release/steps/01-resolve-metadata.md
check "release collects actions before the tag exists" "deployment-actions\.md. § Parse" "$R1"
check "release maps pending batch SHAs to PRs" "merged_sha" "$R1"
check "release scans merge-commit PR refs too" "Merge pull request #" "$R1"
check "release writes the shared TSV" "release-actions\.tsv" "$R1"
R2=skills/n1-release/steps/02-confirm-execute.md
check "release gate renders conflicts" "§ Conflicts" "$R2"
check "release gate offers editing actions" "4 — Edit deployment actions" "$R2"
before "release: before-deploy walk precedes the tag" "PHASE=before" "git tag -a" "$R2"
before "release: before-deploy runbook mode precedes the tag" "mode:runbook" "git tag -a" "$R2"
R4=skills/n1-release/steps/04-report.md
check "release has Step 8b" "^# Step 8b: After-deploy Actions" "$R4"
check "release Step 8b handles runbook mode" "mode:runbook" "$R4"
check "release asks when no deploy was watched" "§ Unwatched Deploy" "$R4"
before "release: after-deploy follows the deploy watch" "Deployment succeeded" "PHASE=after" "$R4"
check "release: disabled deploy watch still reaches Step 8b" 'Deploy watch disabled\." Go to Step 8b' "$R4"
check "release: deploymentCheck false still reaches Step 8b" 'skip detection\. Go to Step 8b' "$R4"

exit $FAIL

#!/usr/bin/env bash
# N1-239: n1-release writes stakeholder release notes (Slack block, Confluence page, GitHub Release body section).
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R3B=skills/n1-release/steps/03b-release-notes.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first occurrence of a precedes first occurrence of b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
expect() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi
}

# --- 03b content
if [ -f "$R3B" ]; then echo "PASS: 03b-release-notes.md exists"; else echo "FAIL: 03b-release-notes.md missing"; FAIL=1; fi
check "03b supports notes-only mode" 'MODE=notes-only' "$R3B"
check "03b finds or creates the Release notes parent" 'title = "Release notes"' "$R3B"
check "03b stores the Confluence url in the notes file" 'confluence_url:' "$R3B"
check "03b stores the Confluence page id in the notes file" 'confluence_page_id:' "$R3B"
check "03b looks pages up via searchArticles" 'operations\.searchArticles' "$R3B"
check "03b resolves a missing space id via lookupSpace" 'operations\.lookupSpace' "$R3B"
check "03b treats ok:false as a warning" 'ok:false' "$R3B"
check "03b passes the current page version to updateArticle" 'current version from getArticle' "$R3B"
check "03b keeps ticket keys out of stakeholder text" 'No ticket keys' "$R3B"
check "03b folds internal work into one line" 'Internal improvements' "$R3B"
check "03b handles headless notes-only runs" 'N1_HEADLESS' "$R3B"
expect "03b confirmation marks exactly one option (Recommended)" "1" "$(grep -c '(Recommended' "$R3B" 2>/dev/null)"
lacks "03b has no checkbox lines" '^[[:space:]]*- \[[ xX]\]' "$R3B"

# --- behavior: the GitHub Release body snippet against a stubbed gh
SNIPPET=$(awk 'index($0, "## 5c-7. GitHub Release body") == 1 {f = 1; next} f && /^```bash/ {b = 1; next} b && /^```/ {exit} b' "$R3B" 2>/dev/null | sed 's/<TAG>/v1.2.0/g')
if [ -n "$SNIPPET" ]; then echo "PASS: release body snippet present"; else echo "FAIL: release body snippet missing"; FAIL=1; fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.n1" "$T/n1/releases" "$T/n1/scratch"
: > "$T/home/.n1/preamble.sh"   # N1_HOME comes from the environment below
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "release view") [ -f "$GH_BODY" ] && cat "$GH_BODY" ;;
    "release edit") while [ $# -gt 0 ]; do [ "$1" = --notes-file ] && cp "$2" "$GH_BODY"; shift; done; echo edit >> "$GH_EDITS" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"

MARK='<!-- n1:release-notes:end -->'
URL=https://example.atlassian.net/wiki/spaces/P/pages/123
NOTES="$T/n1/releases/v1.2.0.md"
write_notes() { # <stakeholder sentence> [confluence url]
    { echo "# Publius assistant 1.2.0 release notes"
      if [ -n "${2:-}" ]; then echo "confluence_url: $2"; echo "confluence_page_id: 123"; fi
      printf '\n## Slack\n\n*New*\n• %s\n\n## Full\n\n### New\n- %s\n\n### Internal changelog\n- N1-5 Search rewrite ([#12](https://github.com/o/r/pull/12))\n' "$1" "$1"
    } > "$NOTES"
}
run_split() { (export HOME="$T/home" N1_HOME="$T/n1" GH_BODY="$T/body.md" GH_EDITS="$T/edits"; PATH="$T/bin:$PATH" bash -c "$SNIPPET" 2>/dev/null) }
edits() { if [ -f "$T/edits" ]; then wc -l < "$T/edits" | tr -d ' '; else echo 0; fi; }
lines() { grep -cxF -- "$1" "$T/body.md" 2>/dev/null; }   # exact-line count
hits() { grep -cF -- "$1" "$T/body.md" 2>/dev/null; }     # substring count

write_notes "Search finds documents faster." "$URL"
expect "no GitHub Release -> body untouched" "body:no-release" "$(run_split)"
expect "no GitHub Release -> no edit" "0" "$(edits)"

printf '\n' > "$T/body.md"
expect "empty body -> updated" "body:updated" "$(run_split)"
expect "empty body: stakeholder section comes first" "### New" "$(head -1 "$T/body.md")"
expect "empty body: one marker" "1" "$(lines "$MARK")"
expect "link line present when published" "1" "$(lines "Full release notes: $URL")"
expect "internal changelog stays out of the body" "0" "$(hits 'N1-5')"
expect "Slack block stays out of the body" "0" "$(hits '*New*')"
expect "repeat run -> unchanged" "body:unchanged" "$(run_split)"
expect "repeat run -> no second edit" "1" "$(edits)"

printf "## What's Changed\r\n* Search rewrite by @a in #12\r\n" > "$T/body.md"
expect "generated notes without marker -> updated" "body:updated" "$(run_split)"
expect "generated notes kept once" "1" "$(lines "## What's Changed")"
expect "generated notes sit below the marker" "## What's Changed" "$(awk -v m="$MARK" 'f && NF {print; exit} $0 == m {f = 1}' "$T/body.md")"
expect "CRLF stripped" "0" "$(grep -c $'\r' "$T/body.md")"

write_notes "Sign-in works after a password reset." "$URL"
expect "changed notes -> updated" "body:updated" "$(run_split)"
expect "old section replaced, not duplicated" "0" "$(hits 'Search finds documents faster.')"
expect "new section present" "1" "$(hits 'Sign-in works after a password reset.')"
expect "still one marker" "1" "$(lines "$MARK")"
expect "generated notes still once" "1" "$(lines "## What's Changed")"
B1=$(cat "$T/body.md"); run_split >/dev/null
expect "third run leaves the body byte-identical" "$B1" "$(cat "$T/body.md")"

write_notes "Sign-in works after a password reset."
run_split >/dev/null
expect "no link line when publishing was skipped" "0" "$(hits 'Full release notes:')"

rm -f "$NOTES"
expect "missing notes file -> body untouched" "body:no-notes" "$(run_split)"

exit $FAIL

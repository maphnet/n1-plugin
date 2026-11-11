<!-- Purpose: Read current dev-access state, ask the enable question and the fields, write dev-access.md and finishWork.postDeployVerification.enabled. -->

# Step 1: Dev Access

## 1.1 Read current state

```bash
source ~/.n1/preamble.sh
command -v jq >/dev/null 2>&1 || { echo jq:missing; exit 1; }
CFG=$(n1_config_file)
jq empty "$CFG" 2>/dev/null || { echo "config:invalid $CFG"; exit 1; }
echo "enabled=$(n1_config_val '.finishWork.postDeployVerification.enabled')"
echo "gate=$(n1_post_deploy_verification_enabled)"
F="$N1_HOME/dev-access.md"
if [ -f "$F" ]; then
  echo "dev-access:present headings:$(grep -cxE '## (URL or entry point|Non-secret authentication or setup|Allowed commands and data constraints|Observability hints)' "$F")"
else
  echo dev-access:absent
fi
echo dev-providers:
jq -r '.observability.providers // {} | to_entries[] | select(.value.env == "dev") | "\(.key)\t\(.value.mcp // "-")"' "$CFG"
```

- `jq:missing` or `config:invalid`: print "Cannot read the N1 config (<token>). Fix it, then re-run /n1:n1-config." **STOP.** Nothing is written.
- `enabled=` empty: not set; the effective value is `gate=` (legacy smoke fallback). `enabled=` with a value other than `true` or `false`: treat it as not set; 1.6 replaces it with a boolean.
- `dev-access:present headings:4`: read `$N1_HOME/dev-access.md`. The text under each of the four `##` headings is that field's current value.
- `dev-access:present` with fewer than 4 headings: the file was edited by hand and cannot be parsed. Read it, show it whole as the current content, and ask every field in 1.4 fresh (an empty answer does not keep anything). Before 1.5 writes, keep a copy:
  ```bash
  source ~/.n1/preamble.sh
  cp "$N1_HOME/dev-access.md" "$N1_HOME/dev-access.md.bak" && echo bak:written
  ```
- Each line after `dev-providers:` is `<name><TAB><mcp>`. No lines means no dev providers.

Show:
```
Current dev access:
  Post-deploy verification → <true | false | not set (legacy smoke fallback: <gate>)>
  dev-access.md            → <present | absent | present, unparsed>
  URL or entry point       → <value or —>
  Non-secret setup         → <value or —>
  Allowed commands         → <value or —>
  Observability hints      → <one line per provider, or —>
```

## 1.2 Enable question

```
Enable post-deploy verification after a successful deployment?
It checks ticket acceptance criteria on the development environment and records an informational result; it never blocks ticket close.

No recommendation. The options are equivalent given the available evidence; select based on team preference.

1 — Yes: ask for dev-environment access details
2 — No
```

An empty answer keeps the current value (`true` → 1, `false` → 2); with no current value it means 2.

## 1.3 No

Run 1.6 with `V=false`, then 1.7. Do not create `dev-access.md`. An existing `dev-access.md` stays untouched: switching from true to false changes only the flag. **STOP** after 1.7.

## 1.4 Yes: field questions

Ask each question separately. Show the current value with it; an empty answer keeps the current value. Begin the first question with: "Do not enter secrets (passwords, tokens, API keys, private keys, cookies). Name where a secret lives instead, e.g. `API token: 1Password item dev-api`."

1. "Dev URL or entry point? (development URL, application entry point, or both)"
2. "Non-secret authentication or setup? (required role, local profile, VPN, test account name, or `none`)"
3. "Allowed commands and data constraints? (safe read-only commands, permitted test data, prohibited actions)"

If an answer looks like a credential (a `password=`, `token=` or `secret=` assignment, an `Authorization:` or `Bearer ` value, a `-----BEGIN` key block, or a long random-looking token), do not store it. Say "That looks like a secret; it was not saved." and ask the same question again.

**Observability selectors.** For each dev provider from 1.1, ask:

"Selector for `<name>` (`<mcp>`)? <hint>. An empty answer keeps the current selector, or records `no selector` when there is none; `-` sets `no selector`."

`<hint>` by provider name or mcp, case-insensitive: contains `loki` → "Loki stream selector, e.g. `{app=~\"api|worker\"}`"; contains `sentry` → "Sentry environment, e.g. `development`"; contains `langfuse` → "Langfuse project or tag"; otherwise "the filter that scopes it to dev".

Store selectors verbatim. They contain quotes, braces and pipes; never pass them through a shell command.

With no dev providers, the section body is `none`.

## 1.5 Write dev-access.md

Write the file with the file write or edit action, not through a shell command, so values with quotes and braces are stored verbatim.

**New file** (`dev-access:absent`, or unparsed after `bak:written`): write exactly

```markdown
# Development Access

## URL or entry point
<answer 1>

## Non-secret authentication or setup
<answer 2>

## Allowed commands and data constraints
<answer 3>

## Observability hints
- <provider>: <selector or no selector>
```

(one `- <provider>: ...` line per dev provider, or the single line `none`).

**Existing file with 4 headings:** edit in place. Replace the text of a section only when its value changed. The title, unchanged sections and any text outside the four sections stay byte-identical. In `## Observability hints`, replace or add only the `- <provider>: ...` lines of the providers asked in 1.4 (a lone `none` line is replaced); keep every other line. When nothing changed, do not touch the file.

Then run 1.6 with `V=true`.

## 1.6 Set the flag

Substitute `true` or `false` for `<true|false>`:

```bash
source ~/.n1/preamble.sh
V=<true|false>
case "$V" in true|false) ;; *) echo flag:invalid; exit 1 ;; esac
CFG=$(n1_config_file)
if jq --argjson v "$V" '.finishWork.postDeployVerification.enabled = $v' "$CFG" > "$CFG.tmp"; then
  mv "$CFG.tmp" "$CFG" && echo "flag:$V gate=$(n1_post_deploy_verification_enabled)"
else
  rm -f "$CFG.tmp"; echo flag:write-failed; exit 1
fi
```

The write keeps every sibling (`mergeMethod`, `mergeOnFinish`, `deployWatch`) and creates `finishWork` when absent. `flag:invalid` or `flag:write-failed`: report it and **STOP**; the config is unchanged and `dev-access.md` stays as written, so a re-run completes it. `gate=` must equal `V`; otherwise report the mismatch.

## 1.7 Summary

```
Dev access updated.
  Post-deploy verification → <true | false>
  dev-access.md            → <created | updated (<changed sections>) | unchanged | not created | kept (flag off)>
  Observability selectors  → <N of M dev providers>
Edit $N1_HOME/dev-access.md by hand at any time, or re-run /n1:n1-config.
```

Do not print field values or file contents in the summary.

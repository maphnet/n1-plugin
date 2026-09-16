<!-- Purpose: Configure per-agent model overrides (only when user explicitly requests customization). -->

## Agent Model Configuration

Use default models from agent frontmatter. **Do NOT ask** about model customization unless the user explicitly requested it when invoking n1-init.

**On Claude Code only:** if the user requested customization, derive the defaults table by reading the `model:` field from each agent's frontmatter in `<N1_ROOT>/agents/*.md`, display it, and accept per-agent overrides (valid values: opus, sonnet, haiku) — only store overrides that differ from the frontmatter default.

To read an agent's default model from frontmatter:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
def=$(awk 'NR==1&&/^---$/{x=1;next} x&&/^---$/{exit} x&&/^model:/{sub(/^model:[ \t]*/,"");gsub(/\r/,"");print;exit}' "$N1_ROOT/agents/<name>.md")
```

**On Codex (`HOST` = `codex`):** resolve every displayed persona through the combined runtime contract, rather than a flat CLI default:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
n1_resolve_agent <persona> <step-context>
```

Its tab-separated result is the model and reasoning effort to display. With no explicit override, frontmatter roles map through the shared tier policy: Opus roles resolve to `gpt-5.6-sol`, Sonnet roles resolve to `gpt-5.6-terra`, and Haiku roles resolve to `gpt-5.6-luna`. The resulting effort has a medium effort floor. This is a resolved policy, not a claim that frontmatter model names are passed unchanged to Codex.

For the customization prompt, show each persona's resolved model/effort pair for its ordinary step context. Codex accepts a host-keyed `<persona>=<Codex model>[/effort]` override; it is evaluated by the same resolver, rather than against the Claude-only `opus`/`sonnet`/`haiku` validation. Then ask:

```
Persona models for Codex (resolved defaults shown per persona):
No recommendation. The options are equivalent given the available evidence; select based on team preference.
  1 — Keep defaults for all personas
  2 — Override some (enter `persona=model[/effort]`, e.g. code-reviewer=gpt-5.6-sol/high)
```

An explicit `low` effort is accepted as input only so N1 can surface the policy conflict: it warns and resolves to `medium`; never promise that it will run at low. An explicit `gpt-6-astra` override is opt-in but dormant unless a runtime workflow supplies one of the canonical authorized contexts; configuration alone never selects Astra.

Store overrides as host-keyed objects, preserving any Claude value:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
CFG="$N1_HOME/config.json"
# for each "<persona>=<model>[/<effort>]" the user entered:
jq --arg p "<persona>" --arg m "<model>" --arg e "<effort-or-empty>" '
  .models[$p] = (
    (if (.models[$p] | type) == "string" then {"claude-code": .models[$p]} else (.models[$p] // {}) end)
    + {codex: (if $e == "" then $m else {model: $m, reasoning_effort: $e} end)}
  )' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
```

The prune snippets in this section compare against the *Claude* frontmatter default; run them only when `HOST` is `claude-code`, and skip entries whose value is an object.

### On reconfiguration (n1-init re-run):

**`--related` flag:** When invoked as `n1-init --related`, skip all other configuration steps and run only the Related Projects Configuration section below. Read the existing config to preserve all other settings.

Ensure `repoPath` is present and current:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
CFG="$N1_HOME/config.json"
COMMON=$(git rev-parse --git-common-dir); case "$COMMON" in .git) REPO_PATH=$(git rev-parse --show-toplevel) ;; *) REPO_PATH=$(dirname "$COMMON") ;; esac
CUR=$(jq -r '.repoPath // empty' "$CFG")
if [ "$CUR" != "$REPO_PATH" ]; then
  jq --arg p "$REPO_PATH" '.repoPath = $p' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  echo "repoPath set to $REPO_PATH"
fi
```

Prune every `models.<agent>` entry whose value equals the agent's frontmatter default, then print what was pruned. This is idempotent — running it multiple times has no additional effect. Run only when `HOST` is `claude-code`; skip entries whose value is an object (host-keyed).

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"; [ "$(n1_host)" = "claude-code" ] || exit 0
CFG="$N1_HOME/config.json"
for f in "$N1_ROOT"/agents/*.md; do a=$(basename "$f" .md)
  def=$(awk 'NR==1&&/^---$/{x=1;next} x&&/^---$/{exit} x&&/^model:/{sub(/^model:[ \t]*/,"");gsub(/\r/,"");print;exit}' "$f")
  cur=$(jq -r ".models[\"$a\"] // empty" "$CFG")
  [ "$(printf '%s' "$cur" | cut -c1)" = "{" ] && continue
  if [ -n "$cur" ] && [ "$cur" = "$def" ]; then
    jq "del(.models[\"$a\"])" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    echo "pruned models.$a=$cur (equals frontmatter default)"
  fi
done
```

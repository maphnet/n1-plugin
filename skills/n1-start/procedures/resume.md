# Procedure: Resume

## Post-Compaction Recovery

Session-start injects authoritative ORCHESTRATOR STATE; use it, never compacted config/routing values. Nonempty Task context prints resume Gate 1. If missing, re-resolve N1_HOME:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/config.sh"
   N1_HOME=$(n1_home)
   cat "$N1_HOME/config.json"
   ```

## Memory Check

Check if `$N1_HOME/memory/<input>/overview.md` exists.

**Exists:** read step from frontmatter.
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md")
```
Investigation skips workspace isolation; otherwise run it. Read counters:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/frontmatter.sh"
n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
```
Repeat for tq/review/clean/local-test/ci counters; print Gate 1 and read Context:
```bash
CONTEXT_SECTION=$(sed -n '/^## Context$/,/^## /{/^## Context$/d;/^## /d;p}' "$N1_HOME/memory/$ID/overview.md")
```
If empty: skip Gate 1 silently. Else populate template from frontmatter and print.

**Not exists:** fresh start. Create `$N1_HOME/memory/<ID>/`.

## Loop-Counter Durability

Overview frontmatter is authoritative for counters and completed steps. Write artifacts before step/checkbox updates; overwrites are idempotent.

**Dependency integrity guard:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md analysis.md
```
(Pass declared dependency files for current step.) Missing/empty dependency → STOP and report.

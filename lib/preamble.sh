#!/usr/bin/env bash
# N1 common preamble — resolves N1_ROOT, sources core libs, sets N1_HOME.
#
# Usage in skill bash snippets:
#   source "$N1_ROOT/lib/preamble.sh"
#
# Snippets needing specialized libs (memory, treestate, breakcheck, classify,
# related, poll, context) still source those explicitly after this line.

# Resolve plugin root — N1_ROOT must be set by the harness or discoverable
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
[ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')

source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/step.sh"       # also loads telemetry.sh, frontmatter.sh, signals.sh
source "$N1_ROOT/lib/validation.sh"

N1_HOME=$(n1_home)

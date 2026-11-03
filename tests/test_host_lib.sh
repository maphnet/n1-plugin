#!/usr/bin/env bash
# lib/host.sh: Claude Code is the only host (N1-63).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/lib/host.sh"
PASS=0; FAIL=0
eq()    { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
has()   { case "$3" in *"$2"*) echo "PASS: $1"; PASS=$((PASS+1));; *) echo "FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1));; esac; }
lacks() { case "$3" in *"$2"*) echo "FAIL: $1 (unexpected '$2' in: $3)"; FAIL=$((FAIL+1));; *) echo "PASS: $1"; PASS=$((PASS+1));; esac; }

eq "host: constant in an empty env" claude-code "$(env -i PATH="$PATH" bash -c "source '$REPO_ROOT/lib/host.sh'; n1_host")"
eq "host: ignores stale N1_HOST/CODEX_THREAD_ID" claude-code "$(N1_HOST=codex CODEX_THREAD_ID=x n1_host)"
eq "session id: N1_SESSION_ID wins" abc "$(N1_SESSION_ID=abc CLAUDE_CODE_SESSION_ID=def n1_session_id)"
eq "session id: CLAUDE_CODE_SESSION_ID fallback" def "$(unset N1_SESSION_ID; CLAUDE_CODE_SESSION_ID=def n1_session_id)"
eq "session id: CODEX_THREAD_ID ignored" "" "$(unset N1_SESSION_ID CLAUDE_CODE_SESSION_ID; CODEX_THREAD_ID=x n1_session_id)"
eq "worktree root: default" .claude/worktrees "$(n1_worktree_root)"
eq "agent type" n1:developer "$(n1_agent_type developer)"
eq "persona name: n1: stripped" developer "$(n1_persona_name n1:developer)"
eq "persona name: n1- is not a persona" "" "$(n1_persona_name n1-developer)"
eq "plugin version: Claude Code manifest" "$(jq -r .version "$REPO_ROOT/.claude-plugin/plugin.json")" "$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT" n1_plugin_version)"

cmd=$(N1_SESSION_ID=parent n1_headless_cmd n1-start T-1 sonnet /tmp/out /repo high)
has   "headless: claude -p transport" "claude -p " "$cmd"
has   "headless: model" "--model sonnet" "$cmd"
has   "headless: effort" "--effort high" "$cmd"
has   "headless: repo cd" "cd /repo && " "$cmd"
has   "headless: parent linkage" "N1_PARENT_SESSION_ID=parent" "$cmd"
has   "headless: closed stdin + log" "< /dev/null > /tmp/out 2>&1" "$cmd"
lacks "headless: no N1_HOST export" "N1_HOST" "$cmd"
lacks "headless: no codex" "codex" "$cmd"

# ---- n1_mcp_http_url (N1-314): repo .mcp.json -> ~/.claude.json projects[<main checkout>] -> user scope ----
U=$(mktemp -d); trap 'rm -rf "$U"' EXIT
git init -q "$U/main" && git -C "$U/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
    && git -C "$U/main" worktree add -q "$U/wt" -b wt 2>/dev/null
url() { (cd "$U/wt" && HOME="$U/home" n1_mcp_http_url "$1"); }
mkdir -p "$U/home"
eq "mcp url: no ~/.claude.json -> rc 1" "1" "$(url jc >/dev/null; echo $?)"
jq -n --arg m "$U/main" --arg w "$U/wt" '{mcpServers:{jc:{type:"http",url:"http://127.0.0.1:9/user"},sx:{type:"stdio",command:"x"}},
    projects:{($m):{mcpServers:{jc:{type:"http",url:"http://127.0.0.1:9/main"}}}, ($w):{mcpServers:{jc:{type:"http",url:"http://127.0.0.1:9/wt"}}}}}' > "$U/home/.claude.json"
eq "mcp url: main checkout project entry, not the worktree key" "http://127.0.0.1:9/main" "$(url jc)"
printf '{"mcpServers":{"jc":{"type":"http","url":"http://127.0.0.1:9/repo"}}}' > "$U/wt/.mcp.json"
eq "mcp url: repo .mcp.json first" "http://127.0.0.1:9/repo" "$(url jc)"
printf '{"mcpServers":{"jc":{"command":"jc-mcp"}}}' > "$U/wt/.mcp.json"
eq "mcp url: first entry by name decides (stdio -> rc 1)" "1" "$(url jc >/dev/null; echo $?)"
rm "$U/wt/.mcp.json"
jq 'del(.projects)' "$U/home/.claude.json" > "$U/c" && mv "$U/c" "$U/home/.claude.json"
eq "mcp url: user scope last" "http://127.0.0.1:9/user" "$(url jc)"
eq "mcp url: stdio entry -> rc 1, no output" "1|" "$(o=$(url sx); echo "$?|$o")"
eq "mcp url: unknown name -> rc 1" "1" "$(url nope >/dev/null; echo $?)"
jq '.mcpServers.jc.url = "file:///etc/passwd"' "$U/home/.claude.json" > "$U/c" && mv "$U/c" "$U/home/.claude.json"
eq "mcp url: non-http url -> rc 1" "1" "$(url jc >/dev/null; echo $?)"

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

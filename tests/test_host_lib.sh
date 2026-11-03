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

# ---- n1_mcp_http_url (N1-314, SEC-3): ~/.claude.json projects[<main checkout>] -> approved repo .mcp.json -> user scope; loopback only ----
U=$(mktemp -d); trap 'rm -rf "$U"' EXIT
git init -q "$U/main" && git -C "$U/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
    && git -C "$U/main" worktree add -q "$U/wt" -b wt 2>/dev/null
url() { (cd "$U/wt" && HOME="$U/home" n1_mcp_http_url "$1"); }
cj() { jq -n --arg m "$U/main" "$1 | .projects = {(\$m): (.projects // {})}" > "$U/home/.claude.json"; }
mkdir -p "$U/home"
eq "mcp url: no ~/.claude.json -> rc 1" "1" "$(url jc >/dev/null; echo $?)"
cj '{mcpServers:{jc:{type:"http",url:"http://127.0.0.1:9/user"},sx:{type:"stdio",command:"x"}},projects:{mcpServers:{jc:{type:"http",url:"http://localhost:9/main"}}}}'
eq "mcp url: main checkout project entry beats user scope" "http://localhost:9/main" "$(url jc)"
printf '{"mcpServers":{"jc":{"type":"http","url":"http://127.0.0.1:9/repo"}}}' > "$U/wt/.mcp.json"
eq "mcp url: local scope beats .mcp.json" "http://localhost:9/main" "$(url jc)"
cj '{mcpServers:{jc:{type:"http",url:"http://127.0.0.1:9/user"}}}'
eq "mcp url: unapproved .mcp.json ignored, user scope used" "http://127.0.0.1:9/user" "$(url jc)"
cj '{projects:{enabledMcpjsonServers:["jc"]}}'
eq "mcp url: approved .mcp.json used" "http://127.0.0.1:9/repo" "$(url jc)"
cj '{projects:{enableAllProjectMcpServers:true}}'
eq "mcp url: enableAllProjectMcpServers approves" "http://127.0.0.1:9/repo" "$(url jc)"
cj '{projects:{enableAllProjectMcpServers:true,disabledMcpjsonServers:["jc"]}}'
eq "mcp url: disabled server not used" "1" "$(url jc >/dev/null; echo $?)"
cj '{projects:{enabledMcpjsonServers:["jc"]}}'
for u in https://attacker.example/mcp http://127.0.0.1.evil.test/mcp http://evil.test:80/@127.0.0.1/ 'http://127.0.0.1@evil.test/' http://127.0.0.1x/ file:///etc/passwd; do
    printf '{"mcpServers":{"jc":{"type":"http","url":"%s"}}}' "$u" > "$U/wt/.mcp.json"
    eq "mcp url: non-loopback $u -> rc 1" "1" "$(url jc >/dev/null; echo $?)"
done
for u in http://127.0.0.1/ http://127.0.0.1:18090/mcp 'https://localhost:1/a?b=c' 'http://[::1]:5/mcp' http://localhost; do
    printf '{"mcpServers":{"jc":{"type":"http","url":"%s"}}}' "$u" > "$U/wt/.mcp.json"
    eq "mcp url: loopback $u accepted" "$u" "$(url jc)"
done
printf '{"mcpServers":{"jc":{"command":"jc-mcp"}}}' > "$U/wt/.mcp.json"
eq "mcp url: first entry by name decides (stdio -> rc 1)" "1" "$(url jc >/dev/null; echo $?)"
rm "$U/wt/.mcp.json"
cj '{mcpServers:{jc:{type:"http",url:"http://127.0.0.1:9/user"},sx:{type:"stdio",command:"x"}}}'
eq "mcp url: stdio entry -> rc 1, no output" "1|" "$(o=$(url sx); echo "$?|$o")"
eq "mcp url: unknown name -> rc 1" "1" "$(url nope >/dev/null; echo $?)"
cj '{mcpServers:{jc:{type:"http",url:"file:///etc/passwd"}}}'
eq "mcp url: non-http url -> rc 1" "1" "$(url jc >/dev/null; echo $?)"

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env python3
"""PreToolUse hook: N1 agent policy.

Case 1 - persona tool restriction. The payload's `agent_type` names an N1 persona
(`n1:<p>`) and the persona's frontmatter has a `tools:` list: deny any tool outside it.
This duplicates native enforcement as a backstop. Denial: exit 2, reason on stderr.

Reviewer personas may Write only their findings file (see _findings_path_ok, SEC-1).

Case 2 - spawn model override. For spawn tools targeting an N1 persona, rewrite `model`
from config `models.<persona>` (string, or a legacy host-keyed object read through its
"claude-code" key).

Case 3 - merge deny (N1-114, N1-146, N1-167). Gates unattended sessions (N1_QUEUE_RUN_ID set or
N1_HEADLESS=1) and sessions with an active N1 run (this session's keyed active-run file, _active_run);
a plain session passes, and a missing/invalid session id or absent active-run file reads as plain (the file's
mere existence counts, under N1 home or any ~/.n1/<slug>/ - _in_run). Unless
merge_authorized (finishWork.mergeOnFinish true, plus autonomy.fullAuto true when unattended), deny
Bash `gh pr merge`; `gh api`/curl/wget when the
command anywhere names a merge API (mergePullRequest, enablePullRequestAutoMerge, mergeBranch,
enqueuePullRequest, repos/<o>/<r>/merges, pulls/<n>/merge, git/refs/heads/<default>) - anywhere, so a
heredoc query body counts, but only with an HTTP-capable command present, so `grep mergePullRequest`
passes; and `git push` targeting git.defaultBranch (default "main"): a refspec
`[refs/heads/]<default>` or `<src>:<default>`, `*` or `:` refspecs, `--all`/`--mirror`/`--branches`
(or prefixes), or a bare/HEAD push while the payload cwd is on the default branch. git.directPush
true allows ordinary default-branch `git push` chunks in interactive N1 runs only (never merges, merge APIs,
`--all`/`--mirror`/wildcard pushes, or force/delete pushes: `+ref`, `-f`, `--force*`, `-d`, `--delete`, `:ref`; a bare push when repo config has remote.*.push|mirror). The
denial tells the user to run the command alone with the `!` prefix. `git merge` is
NOT denied (N1-45). Not a shell parser: quotes/backslashes are stripped (bash does the same, so
`g''h pr m''erge` is caught), `$(`/`<(`/backtick become command-position markers, `${`/`@{`/parens
are blanked, the command is split on ; & | newline, and gh/git/curl/wget count only at command
position (segment start, after VAR=x, wrappers like env/sudo/xargs/timeout N/chroot NEWROOT, `sh -c`,
skipping wrapper value flags in WRAPPER_VALUE_FLAGS: `env -u FOO`, `sudo -nu x`, `--unse FOO`; getopt_long
exact-then-unique-prefix, so `sudo --login gh` keeps gh). Backstop: the first gh/git/curl/wget eaten as a
flag value or NEWROOT also starts a shadow chunk (later gh/git/curl/wget words included, N1-174), so a table gap denies (`env -u git push origin main` is a
known false positive). A chunk runs to segment end; a nested one runs until the next nested one; one shadow
per segment - each token lands in at most three chunks, so the scan is linear in command length (SEC-22). Known gaps: runtime string-building (eval,
base64, variables, aliases), a second eaten program in one segment after a genuine `-u git` (no second
shadow), wrapper options outside WRAPPER_VALUE_FLAGS (`env -S` is a command
string, deliberately not skipped, incl. its backslash-underscore separator), a `$(...)` as a wrapper flag value
(`sudo -u "$(id -un)" gh ...`), wrappers outside WRAPPERS (busybox, flock, unshare), other HTTP
clients, chunks nested three deep, a bare push after `cd` into another checkout on the default branch; known false
positives: heredoc/backtick text whose line starts with gh/git, and grep for a merge API in the
same command as `gh api`.

Case 4 - pipe-masked test status (N1-159). Deny Bash where a test runner (tests/*.sh, pytest, bats,
jest, vitest, npm test, go test, make test) is piped into tail/head/grep and `git commit` follows in the
same `&&`-connected run: the pipeline exit status is the filter's, so a red suite still commits. Only
`&&` gates the commit on that status; `||`, `;` and newline break the chain and are not denied. Every
session, merge-authorized or not. Allowed when the command enables pipefail (`set -o pipefail`,
`set -euo pipefail`) or mentions `PIPESTATUS`. Known gaps: `bash -c`, `$(...)`, subshells, variables/aliases, quoted separators.

Fail-open otherwise: exit 0, no output. An unparseable payload (malformed JSON or not an object) exits 3;
the wrapper (enforce-agent-policy.sh) treats 3 like a crash or a missing interpreter: an n1:code-reviewer /
n1:security-reviewer Write is denied, everything else passes (N1-174).

Usage: enforce-agent-policy.py <config_file> <plugin_root>   (payload on stdin)
"""

import functools
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SPAWN_TOOLS = {"Task", "Agent", "spawn_agent"}
SEGMENT_RE = re.compile(r"[;&|\n]")
MERGE_API = (r"mergepullrequest|enablepullrequestautomerge|mergebranch|enqueuepullrequest"
             r"|\brepos/[^/\s]+/[^/\s]+/merges\b|/pulls/[^/\s]+/merge\b")
SUBST = "\x00"  # command-position marker for $( <( >( and backticks
ASSIGN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# Redirection + operand (>f, > f, 2>f, >>f, <f, &>f, 2>&1, >|f) so the next word keeps command
# position; (?<!...) anchors fd digits to a run start (linear); >( <( $( stay for SUBST.
REDIR_RE = re.compile(r"(?<![\d&])(?:\d*|&)(?:>>?|<)(?!\()\|?[ \t]*&?(?:[^\s;&|()<>`$]|\$(?!\())*")
DURATION_RE = re.compile(r"[0-9.]+[smhd]?$")
REVIEWERS = {"code-reviewer", "security-reviewer"}
PROGRAMS = {"gh", "git", "curl", "wget"}
WRAPPERS = {"env", "command", "exec", "sudo", "doas", "time", "nohup", "xargs", "timeout", "sh", "bash",
            "nice", "ionice", "stdbuf", "setsid", "chroot",
            "{", "!", "if", "then", "else", "elif", "do", "while", "until"}
# Wrapper options whose value is the next token (`env -u FOO git`). Exact per wrapper: a skipped real
# program is a bypass. env -S is absent on purpose: its string expands into the command words.
WRAPPER_VALUE_FLAGS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-a", "--argv0"},
    "sudo": {"-u", "-g", "-h", "-p", "-r", "-t", "-T", "-U", "-D", "-R", "-C", "-a", "-c",
             "--auth-type", "--login-class", "--user", "--group", "--host", "--prompt", "--role", "--type",
             "--command-timeout", "--other-user", "--chdir", "--chroot", "--close-from"},
    "doas": {"-a", "-u", "-C"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "xargs": {"-I", "-E", "-L", "-d", "-a", "-s", "-n", "-P", "--arg-file", "--delimiter",
              "--max-args", "--max-procs", "--max-chars", "--process-slot-var"},
    "exec": {"-a"},
    "bash": {"--rcfile", "--init-file"},  # -o/-O clusters: see shell_operands
    "time": {"-o", "--output", "-f", "--format"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "chroot": {"--userspec", "--groups"},
}
WRAPPER_VALUE_FLAGS["sh"] = WRAPPER_VALUE_FLAGS["bash"]
LEADING_POSITIONALS = {"chroot": 1}  # NEWROOT precedes the command
# No-value long options that collide with a value flag's prefix: getopt_long takes an exact match
# first, then a unique prefix (`sudo --login gh` runs gh; `--login-c x` is --login-class).
WRAPPER_NOVALUE_LONGS = {"sudo": {"--login", "--list"}}
# Short options whose value is only ever attached (`-iR`, `-lN`, `-eEOF`), so the rest of a cluster is their value.
ATTACHED_FLAGS = {"xargs": {"-i", "-l", "-e"}}
GH_VALUE_FLAGS = {"-R", "--repo"}
GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--attr-source"}
UNIT_RE = re.compile(r"(&&\s*|\|\||;|\n)")
RUNNER_RE = re.compile(r"(?:^|/)(?:pytest|bats|jest|vitest)$")
TESTS_DIR_RE = re.compile(r"(?:^|/)tests?/")
PIPEFAIL_RE = re.compile(r"\bset\b[^;&|\n]{0,200}\s-[A-Za-z]*o\s+pipefail\b")
PUSH_VALUE_FLAGS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def persona_of(agent_type: str):
    if agent_type.startswith("n1:"):
        return agent_type[len("n1:"):]
    return None


def model_override(config: dict, persona: str):
    entry = (config.get("models") or {}).get(persona)
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        value = entry.get("claude-code")
        if isinstance(value, str):
            return value or None
        if isinstance(value, dict):
            return value.get("model") or None
    return None


def persona_tools(plugin_root: str, persona: str):
    """Set of tool names from the persona frontmatter, or None when the persona inherits all tools."""
    try:
        text = (Path(plugin_root) / "agents" / f"{persona}.md").read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    m = re.search(r"^tools:\s*(.+)$", text[3:end], re.M)
    if not m:
        return None
    return {t.strip() for t in m.group(1).split(",") if t.strip()}


def _active_run(payload, config_file=""):
    """(realpath N1 home, ticketId) from this session's keyed active-run file, else None (N1-167).
    N1 home = $N1_HOME, else the config dir. Unkeyed active-run.json is ignored (shared across sessions)."""
    cwd = str(payload.get("cwd") or "")
    home = os.environ.get("N1_HOME") or (os.path.dirname(os.path.join(cwd, config_file)) if config_file else "")
    sid = payload.get("session_id")
    if not home or not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        return None
    home = os.path.realpath(os.path.join(cwd, home))
    try:
        ticket = json.loads(Path(home, f"active-run.{sid}.json").read_text(encoding="utf-8")).get("ticketId")
    except (OSError, ValueError, AttributeError):
        return None
    if not isinstance(ticket, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*-[0-9]+", ticket):
        return None
    return home, ticket


def _in_run(payload, config_file=""):
    """merge_deny scope (SEC-2/SEC-3): this session's keyed active-run file exists under the resolved home or any
    ~/.n1/<slug>/ (cwd-independent), whatever its contents. lexists: a dangling link still counts.
    Cross-cwd only for ~/.n1/<slug> homes; a legacy git-config n1.home or in-repo .n1/ home is resolved from cwd (SEC-2)."""
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        return False
    name = f"active-run.{sid}.json"
    cwd = str(payload.get("cwd") or "")
    home = os.environ.get("N1_HOME") or (os.path.dirname(os.path.join(cwd, config_file)) if config_file else "")
    paths = glob.glob(os.path.join(glob.escape(os.path.expanduser("~/.n1")), "*", name))
    if home:
        paths.append(os.path.join(cwd, home, name))
    return any(os.path.lexists(p) for p in paths)


def _findings_path_ok(payload, persona, config_file="") -> bool:
    """Reviewer Write scope (SEC-1/SEC-4): realpath is <N1 home>/memory/<active ticket>/review-<cr|sec>.md for this persona. N1 home and ticket from _active_run. Fail closed."""
    tool_input = payload.get("tool_input")
    path = tool_input.get("file_path") if isinstance(tool_input, dict) else None
    if not isinstance(path, str) or not path.strip():
        return False
    run = _active_run(payload, config_file)
    if run is None:
        return False
    home, ticket = run
    suffix = {"code-reviewer": "cr", "security-reviewer": "sec"}[persona]
    return os.path.realpath(path) == os.path.join(home, "memory", ticket, f"review-{suffix}.md")


def restriction(payload: dict, plugin_root: str, config_file: str = "") -> int:
    persona = persona_of(str(payload.get("agent_type") or ""))
    tool = str(payload.get("tool_name") or "")
    if not persona or not tool:
        return 0
    allowed = persona_tools(plugin_root, persona)
    if allowed is None or tool.startswith("mcp__"):
        return 0
    if tool in allowed:
        if tool == "Write" and persona in REVIEWERS and not _findings_path_ok(payload, persona, config_file):
            sys.stderr.write(f"N1: persona {persona} may Write only its own review-(cr|sec).md for the active ticket under the N1 home\n")
            return 2
        return 0
    sys.stderr.write(f"N1: persona {persona} may not use tool {tool} (allowed: {', '.join(sorted(allowed))})\n")
    return 2


def spawn_override(payload: dict, config: dict) -> int:
    if payload.get("tool_name") not in SPAWN_TOOLS:
        return 0
    tool_input = payload.get("tool_input") or {}
    target = tool_input.get("subagent_type") or tool_input.get("subagent_name") or tool_input.get("agent_type") or ""
    persona = persona_of(str(target))
    if not persona:
        return 0
    override = model_override(config, persona)
    if not override or tool_input.get("model") == override:
        return 0
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": f"n1 config override: models.{persona} = {override}",
            "updatedInput": {**tool_input, "model": override},
        }
    }))
    return 0


def _positionals(tokens, value_flags):
    """(positional, flag-value) pairs: tokens not starting with '-', skipping values of value_flags."""
    out, skip, cwd = [], False, None
    for i, tok in enumerate(tokens):
        if skip:
            skip = False
        elif tok in value_flags:
            skip = True
            if tok == "-C" and i + 1 < len(tokens):
                cwd = tokens[i + 1]
        elif not tok.startswith("-"):
            out.append(tok)
    return out, cwd


def shell_operands(tok):
    """bash/dash take no attached values: every o/O in a -/+ cluster consumes one following word."""
    return sum(c in "oO" for c in tok[1:]) if tok[0] in "-+" and not tok.startswith("--") else 0


def _needs_value(flags, tok, attached=(), novalue=()):
    """True when wrapper option tok takes the next token: an exact flag, or a --long prefix that is
    unique against flags + novalue (getopt_long: exact wins, then a unique prefix; ambiguous ones error
    in the real tool, so they keep command position), or a short cluster ending in a value letter
    (`-iu FOO`, `sudo -nu x`; `-uFOO` carries its value). A letter in `attached` ends the scan: the rest
    of the cluster is its value (`xargs -iI git ...` runs git, so `-I` there must not skip)."""
    if tok in flags:
        return True
    if tok.startswith("--"):
        if len(tok) <= 2 or "=" in tok or tok in novalue:
            return False
        hits = [f for f in (*flags, *novalue) if f.startswith(tok)]
        return len(hits) == 1 and hits[0] in flags
    for i, ch in enumerate(tok[1:], 1):
        if tok[0] + ch in flags:
            return i == len(tok) - 1
        if tok[0] + ch in attached:
            return False
    return False


@functools.lru_cache(maxsize=None)
def _current_branch(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() or None


def _repo_push_config(cwd):
    """True unless git reports no remote.*.push|mirror in cwd (rc 1); lookup failure counts as set (N1-167 Codex High)."""
    try:
        r = subprocess.run(["git", "-C", cwd, "config", "--get-regexp", r"^remote\..*\.(push|mirror)$"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return True
    return r.returncode != 1


def _destructive_flag(a):
    if a.startswith("--"):
        n = a.split("=")[0]
        return len(n) > 3 and any(f.startswith(n) or n.startswith(f) for f in ("--force", "--delete"))
    return len(a) > 1 and a[0] == "-" and ("f" in a[1:] or "d" in a[1:])


CONFIG_PUSH_RE = re.compile(r"remote\..*\.(push|mirror)", re.I)
GIT_CONFIG_ENV_RE = re.compile(r"GIT_CONFIG_(COUNT|KEY_|VALUE_|PARAMETERS)", re.I)


def _config_push(tokens):
    """True when the chunk injects push config (-c/--config-env remote.*.push|mirror, GIT_CONFIG_* env), N1-167 SEC-1."""
    return any(GIT_CONFIG_ENV_RE.match(t) or (CONFIG_PUSH_RE.match(t) and tokens[i - 1] in ("-c", "--config-env")) or
               (t.startswith("--config-env=") and CONFIG_PUSH_RE.match(t[13:])) for i, t in enumerate(tokens))


def _is_merge(tokens, api_hit, default, cwd, push_ok=False):
    """One chunk starting at a gh/git/curl/wget token in command position. push_ok: git.directPush (N1-167)."""
    if tokens[0] in ("curl", "wget"):
        return api_hit
    pos, git_cwd = _positionals(tokens[1:], GH_VALUE_FLAGS if tokens[0] == "gh" else GIT_VALUE_FLAGS)
    if tokens[0] == "gh":
        return pos[:2] == ["pr", "merge"] or (pos[:1] == ["api"] and api_hit)
    if pos[:1] != ["push"]:
        return False
    args = tokens[tokens.index("push") + 1:]
    if any(len(a) > 3 and any(f.startswith(a) for f in ("--all", "--mirror", "--branches")) for a in args):
        return True
    refs, _ = _positionals(args, PUSH_VALUE_FLAGS)
    # --repo names the remote, so every positional is a refspec (Codex High)
    if not any(a == "--repo" or a.startswith(("--rep=", "--repo=")) for a in args):
        refs = refs[1:]
    if any("*" in r or r.lstrip("+") == ":" for r in refs):
        return True
    base = cwd or os.getcwd()
    push_dir = os.path.join(base, git_cwd) if git_cwd else base
    # directPush (N1-167 SEC-4) lifts only ordinary pushes: force (+ref, -f, --force*) and delete (:ref, -d, --delete) stay denied
    if push_ok and not (any(r.startswith(("+", ":")) for r in refs) or any(_destructive_flag(a) for a in args)
                        or any(len(a) > 3 and "--prune".startswith(a) for a in args) or _config_push(tokens)
                        # a bare push follows remote.*.push|mirror from repo config, so those stay denied (Codex High)
                        or (not refs and _repo_push_config(push_dir))):
        return False
    target = re.compile(r"(?:^|:)(?:refs/heads/)?%s$" % re.escape(default), re.I)
    if any(target.search(r.lstrip("+")) for r in refs):
        return True
    if not all(r in ("HEAD", "@") for r in refs):
        return False
    branch = _current_branch(push_dir)
    return bool(branch) and branch.lower() == default.lower()


def _commands(command):
    """Token lists, one per gh/git/curl/wget in command position (outer + latest nested; linear, SEC-22)."""
    command = REDIR_RE.sub(" ", command)
    command = re.sub(r"[$<>]\(|`", f" {SUBST} ", command)
    command = re.sub(r"[$@]\{|[()<>]", " ", command)
    for segment in SEGMENT_RE.split(command):
        outer = inner = None
        at_cmd, wrapper, skip, lead = True, None, 0, 0
        # Backstop: the first gh/git/curl/wget eaten as a flag value or NEWROOT also starts a shadow
        # chunk to segment end, so a wrong flag table fails toward deny (one per segment: linear).
        # ponytail: only the first such token; a later one after a genuine `-u git` is not re-read.
        shadow = None
        envs = []  # GIT_CONFIG_* assignments before git (N1-167 SEC-1)
        for tok in segment.split():
            start = None
            if tok == SUBST:
                at_cmd, wrapper, skip, lead = True, None, 0, 0
                continue
            if at_cmd:
                # an option (incl. attached `--chdir=/x/nice`, `-C/x/env`) is never a program or wrapper
                name = "" if tok.startswith(("-", "+")) else tok.rsplit("/", 1)[-1].lower()
                name = name[:-4] if name.endswith(".exe") else name
                if skip or (lead and not tok.startswith("-")):
                    if skip:
                        skip -= 1  # operand of a wrapper value flag; the command still follows
                    else:
                        lead -= 1  # chroot NEWROOT (`+r` included: only `-` starts an option)
                    start = name if name in PROGRAMS and shadow is None else None
                elif lead and tok == "--":
                    skip, lead = 1, lead - 1  # after `--` the next word is NEWROOT whatever its prefix
                elif name in PROGRAMS:
                    # GIT_CONFIG_* assignments before git become -c pairs so _config_push sees them (SEC-1)
                    head = [name] + [x for e in envs for x in ("-c", e)] * (name == "git")
                    if outer is None:
                        outer = head
                    else:
                        if inner:
                            yield inner
                        inner = head
                    at_cmd = False
                    if shadow is not None:
                        shadow.append(tok)  # outer/inner hold it via head; the shadow must too (N1-174)
                    continue
                elif name in WRAPPERS:
                    wrapper, lead = name, LEADING_POSITIONALS.get(name, 0)
                elif wrapper and tok.startswith(("-", "+")):
                    skip = (shell_operands(tok) if wrapper in ("bash", "sh") else 0) or int(
                        _needs_value(WRAPPER_VALUE_FLAGS.get(wrapper, ()), tok, ATTACHED_FLAGS.get(wrapper, ()),
                                     WRAPPER_NOVALUE_LONGS.get(wrapper, ())))
                elif not (wrapper and DURATION_RE.match(tok)):
                    if ASSIGN_RE.match(tok) and GIT_CONFIG_ENV_RE.match(tok):
                        envs.append(tok)
                    at_cmd = bool(ASSIGN_RE.match(tok))
            for chunk in (outer, inner, shadow):
                if chunk is not None:
                    chunk.append(tok)
            if start:
                shadow = [start]
        for chunk in (outer, inner, shadow):
            if chunk:
                yield chunk


def _is_true(config: dict, block: str, key: str) -> bool:
    section = config.get(block)
    return isinstance(section, dict) and section.get(key) is True


def _unattended() -> bool:
    """Queue or headless run, read from the hook's own env (a command's `env -u` cannot change it)."""
    return bool(os.environ.get("N1_QUEUE_RUN_ID")) or os.environ.get("N1_HEADLESS") == "1"


def merge_authorized(config: dict) -> bool:
    """Mirror of n1_merge_authorized (lib/config.sh, N1-146): mergeOnFinish true, plus fullAuto when unattended."""
    if not _is_true(config, "finishWork", "mergeOnFinish"):
        return False
    return not _unattended() or _is_true(config, "autonomy", "fullAuto")


def _command(payload):
    tool_input = payload.get("tool_input")
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    command = tool_input.get("command") or tool_input.get("cmd")
    if isinstance(command, list):
        command = " ".join(str(c) for c in command)
    return command if isinstance(command, str) else None


def merge_deny(payload: dict, config: dict, config_file: str = "") -> int:
    if merge_authorized(config):
        return 0
    unattended = _unattended()
    # N1-167: interactive sessions are gated only inside an active N1 run
    if not unattended and not _in_run(payload, config_file):
        return 0
    command = _command(payload)
    if not command:
        return 0
    command = re.sub(r"[\"'\\]", "", command)
    git_cfg = config.get("git")
    default = str((git_cfg if isinstance(git_cfg, dict) else {}).get("defaultBranch") or "main")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    api_re = re.compile(r"%s|git/refs/heads/%s(?![\w.-])" % (MERGE_API, re.escape(default)), re.I)
    api_hit = api_re.search(command) is not None
    push_ok = not unattended and _is_true(config, "git", "directPush")
    if not any(_is_merge(c, api_hit, default, cwd, push_ok) for c in _commands(command)):
        return 0
    sys.stderr.write("N1: merge/default-branch push denied in an N1 run -- merges need finishWork.mergeOnFinish true "
                     "(queue/headless runs also need autonomy.fullAuto true); default-branch pushes are also allowed by "
                     "git.directPush true (interactive runs only). The user can run it themselves: the blocked command "
                     "alone, prefixed with ! (e.g. \"! git push origin HEAD:main\"), as its own command, not chained "
                     "with others\n")
    return 2


def _words(stage):
    """Command-position words of a pipeline stage: env assignments, wrappers, their flags/durations skipped."""
    words = stage.split()
    i = 0
    while i < len(words) and (ASSIGN_RE.match(words[i]) or words[i] in WRAPPERS
                              or (i and (words[i].startswith("-") or DURATION_RE.match(words[i])))):
        i += 1
    return words[i:]


def _is_runner(stage):
    w = _words(stage)
    if not w:
        return False
    name = w[0].rsplit("/", 1)[-1]
    if RUNNER_RE.search(w[0]) or (w[0].endswith(".sh") and TESTS_DIR_RE.search(w[0])):
        return True
    if name.startswith("python") and w[1:3] == ["-m", "pytest"]:
        return True
    return (name, *w[1:2]) in {("npm", "test"), ("go", "test"), ("make", "test")} or w[:3] == ["npm", "run", "test"]


def _is_commit(unit):
    w = _words(unit)
    return bool(w) and w[0].rsplit("/", 1)[-1] == "git" and _positionals(w[1:], GIT_VALUE_FLAGS)[0][:1] == ["commit"]


def pipe_deny(payload: dict) -> int:
    command = _command(payload)
    if not command or "PIPESTATUS" in command:
        return 0
    parts = UNIT_RE.split(REDIR_RE.sub(" ", command))
    masked = pipefail = False
    for i in range(0, len(parts), 2):
        # pipefail only protects units after the `set -o pipefail` unit
        if pipefail or PIPEFAIL_RE.search(parts[i]):
            pipefail, masked = True, False
            continue
        if masked and _is_commit(parts[i]):
            sys.stderr.write("N1: commit denied -- a test runner piped into tail/head/grep hides its exit status; "
                             "prefix the command with 'set -o pipefail;' (or use PIPESTATUS)\n")
            return 2
        stages = [st.lstrip("&") for st in parts[i].split("|")]
        if len(stages) > 1 and any(_is_runner(st) for st in stages[:-1]):
            last = _words(stages[-1])
            masked = masked or (bool(last) and last[0].rsplit("/", 1)[-1] in ("tail", "head", "grep"))
        masked = masked and i + 1 < len(parts) and parts[i + 1].startswith("&&")
    return 0


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read())
    except ValueError:  # includes UnicodeDecodeError
        return 3  # unparseable: the wrapper denies a reviewer Write and allows the rest (N1-174)
    if not isinstance(payload, dict):
        return 3
    config_file = sys.argv[1] if len(sys.argv) > 1 else ""
    plugin_root = sys.argv[2] if len(sys.argv) > 2 else ""
    config = {}
    if config_file:
        try:
            config = json.loads(Path(config_file).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
    if not isinstance(config, dict):
        config = {}
    rc = restriction(payload, plugin_root, config_file) or merge_deny(payload, config, config_file) or pipe_deny(payload)
    if rc:
        return rc
    return spawn_override(payload, config)


if __name__ == "__main__":
    sys.exit(main())

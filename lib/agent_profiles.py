#!/usr/bin/env python3
"""Generate Codex custom-agent TOML files from N1 persona definitions.

Codex plugins cannot ship agents, so the session-start hook (Codex host only) writes one
<out>/n1-<persona>.toml per agents/<persona>.md that declares `name:` in its frontmatter.
Line 1 of every file is `# n1-fingerprint: <hash>` over (plugin version, plugin root,
persona file bytes, resolved model, resolved reasoning effort); an unchanged fingerprint
means the file is left untouched, so repeated session starts are no-ops.

Model policy mirrors lib/config.sh n1_model_for on the codex host:
  config.json models.<persona>.codex  -> "model" | {"model": ..., "reasoning_effort": ...}
  else ~/.codex/config.toml [agents] default_subagent_model / default_subagent_reasoning_effort.

Usage: agent_profiles.py --plugin-root DIR --out DIR [--config FILE] [--codex-config FILE] [--version V]
Prints: written=<n> unchanged=<n>
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# Any of these in a persona's tools list means it may modify the workspace.
WRITE_TOOLS = {"Edit", "Write", "Bash", "NotebookEdit", "MultiEdit"}


def parse_frontmatter(text: str) -> dict:
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    fm = {}
    for line in text[3:end].splitlines():
        m = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line.strip())
        if not m:
            continue
        value = m.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
            if value and m.group(2).strip()[0] == '"':
                value = value.replace('\\"', '"')
        fm[m.group(1)] = value
    return fm


def tools_list(fm: dict) -> list:
    return [t.strip() for t in (fm.get("tools") or "").split(",") if t.strip()]


def codex_defaults(codex_config: str) -> dict:
    """[agents] default_subagent_model / default_subagent_reasoning_effort from the Codex config."""
    out = {}
    try:
        text = Path(codex_config).read_text(encoding="utf-8")
    except OSError:
        return out
    section = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            section = s.strip("[]").strip()
            continue
        if section != "agents":
            continue
        m = re.match(r'^(default_subagent_model|default_subagent_reasoning_effort)\s*=\s*"([^"]*)"', s)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def resolve_model(config: dict, persona: str, defaults: dict):
    entry = ((config or {}).get("models") or {}).get(persona)
    model = effort = None
    if isinstance(entry, dict):
        codex = entry.get("codex")
        if isinstance(codex, str):
            model = codex
        elif isinstance(codex, dict):
            model = codex.get("model")
            effort = codex.get("reasoning_effort")
    return model or defaults.get("default_subagent_model"), effort or defaults.get("default_subagent_reasoning_effort")


def fingerprint(version: str, plugin_root: str, persona_bytes: bytes, model, effort) -> str:
    h = hashlib.sha256()
    for part in (version or "", plugin_root, model or "", effort or ""):
        h.update(part.encode("utf-8"))
        h.update(b"\0")
    h.update(persona_bytes)
    return h.hexdigest()[:16]


def render(persona: str, fm: dict, plugin_root: str, model, effort, fp: str) -> str:
    tools = tools_list(fm)
    md_path = os.path.join(plugin_root, "agents", f"{persona}.md")
    instructions = f"Read and follow {md_path} exactly."
    if tools:
        instructions += " Use only these tools: " + ", ".join(tools) + "."
    # json.dumps yields valid TOML basic strings (same escapes, \uXXXX for non-ASCII).
    lines = [
        f"# n1-fingerprint: {fp}",
        f"name = {json.dumps('n1-' + persona)}",
        f"description = {json.dumps(fm.get('description') or persona)}",
        f"developer_instructions = {json.dumps(instructions)}",
    ]
    if model:
        lines.append(f"model = {json.dumps(model)}")
    if effort:
        lines.append(f"model_reasoning_effort = {json.dumps(effort)}")
    if tools and not (set(tools) & WRITE_TOOLS):
        lines.append('sandbox_mode = "read-only"')
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--plugin-root", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--config", default=None, help="$N1_HOME/config.json")
    p.add_argument("--codex-config", default=os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "config.toml"))
    p.add_argument("--version", default="")
    a = p.parse_args(argv)

    config = {}
    if a.config and Path(a.config).is_file():
        try:
            config = json.loads(Path(a.config).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
    defaults = codex_defaults(a.codex_config)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    written = unchanged = 0
    for md in sorted(Path(a.plugin_root).glob("agents/*.md")):
        persona = md.stem
        data = md.read_bytes()
        fm = parse_frontmatter(data.decode("utf-8", "replace"))
        if not fm.get("name"):
            continue  # shared rubrics (research-standards.md) are not spawnable personas
        model, effort = resolve_model(config, persona, defaults)
        fp = fingerprint(a.version, a.plugin_root, data, model, effort)
        target = out / f"n1-{persona}.toml"
        if target.is_file():
            with open(target, encoding="utf-8") as fh:
                if fh.readline().strip() == f"# n1-fingerprint: {fp}":
                    unchanged += 1
                    continue
        target.write_text(render(persona, fm, a.plugin_root, model, effort, fp), encoding="utf-8")
        written += 1
    print(f"written={written} unchanged={unchanged}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

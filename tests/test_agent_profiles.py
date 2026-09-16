import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("agent_profiles", REPO / "lib" / "agent_profiles.py")
ap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ap)


def make_plugin(root: Path):
    (root / "agents").mkdir(parents=True)
    shutil.copytree(REPO / "lib", root / "lib")
    shutil.copy2(REPO / "pipeline.json", root / "pipeline.json")
    personas = {
        "code-reviewer": ('Read-only \\"cold\\" review — findings with file:line.', "opus", "medium", "Read, Grep, Glob"),
        "developer": ("Implements.", "sonnet", "medium", "Read, Edit, Write, Bash, Grep, Glob"),
        "fast-worker": ("Fast routine work.", "haiku", "medium", "Read"),
        "product-analyst": ("Clarifies requirements.", "sonnet", "low", ""),
        "implementer": ("Wraps SDD.", "sonnet", "medium", ""),
    }
    for name, (description, model, effort, tools) in personas.items():
        tool_line = f"tools: {tools}\n" if tools else ""
        (root / "agents" / f"{name}.md").write_text(
            f'---\nname: {name}\ndescription: "{description}"\nmodel: {model}\neffort: {effort}\n{tool_line}---\n# body\n',
            encoding="utf-8",
        )
    (root / "agents" / "research-standards.md").write_text("---\nmodel: sonnet\neffort: medium\n---\n# rubric\n", encoding="utf-8")


def run(root, out, config=None, codex_config=None, version="3.0.0"):
    argv = [sys.executable, str(REPO / "lib" / "agent_profiles.py"), "--plugin-root", str(root), "--out", str(out),
            "--version", version, "--codex-config", str(codex_config or (root / "nonexistent.toml"))]
    if config:
        argv += ["--config", str(config)]
    return subprocess.run(argv, capture_output=True, text=True, check=True)


def toml_value(path: Path, field: str):
    match = re.search(rf'^{re.escape(field)} = "([^"]*)"$', path.read_text(encoding="utf-8"), re.M)
    return match.group(1) if match else None


class AgentProfilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "plugin"
        self.out = self.tmp / ".codex" / "agents"
        self.home = self.tmp / "home"
        self.home.mkdir()
        make_plugin(self.root)
        self.codex_home = self.tmp / "codex"
        self.codex_home.mkdir()
        self.codex_cfg = self.codex_home / "config.toml"
        self.codex_cfg.write_text('[agents]\ndefault_subagent_model = "flat-default"\ndefault_subagent_reasoning_effort = "medium"\n', encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def config(self, value):
        path = self.home / "config.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def profile(self, persona):
        return self.out / f"n1-{persona}.toml"

    def shell_resolution(self, persona, context=""):
        env = os.environ | {"N1_HOST": "codex", "N1_HOME": str(self.home), "ID": "CASE", "CODEX_HOME": str(self.codex_home),
                            "CLAUDE_PLUGIN_ROOT": str(self.root)}
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; n1_resolve_agent "$2" "$3"', "bash", str(REPO / "lib" / "config.sh"), persona, context],
            env=env, capture_output=True, text=True, check=True,
        )
        return tuple(result.stdout.strip().split("\t")), result.stderr

    def test_generates_named_personas_and_is_idempotent(self):
        first = run(self.root, self.out, codex_config=self.codex_cfg)
        self.assertEqual(first.stdout.strip(), "written=5 unchanged=0")
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), [
            "n1-code-reviewer.toml", "n1-developer.toml", "n1-fast-worker.toml", "n1-implementer.toml", "n1-product-analyst.toml"])
        mtimes = {p.name: p.stat().st_mtime_ns for p in self.out.iterdir()}
        second = run(self.root, self.out, codex_config=self.codex_cfg)
        self.assertEqual(second.stdout.strip(), "written=0 unchanged=5")
        self.assertEqual(mtimes, {p.name: p.stat().st_mtime_ns for p in self.out.iterdir()})

    def test_missing_config_uses_policy_models_and_medium_effort(self):
        run(self.root, self.out, codex_config=self.codex_cfg)
        self.assertEqual(toml_value(self.profile("code-reviewer"), "model"), "gpt-5.6-sol")
        self.assertEqual(toml_value(self.profile("developer"), "model"), "gpt-5.6-terra")
        self.assertEqual(toml_value(self.profile("fast-worker"), "model"), "gpt-5.6-luna")
        for persona in ("code-reviewer", "developer", "implementer", "fast-worker"):
            self.assertEqual(toml_value(self.profile(persona), "model_reasoning_effort"), "medium")

    def test_toml_content_and_non_astra_override(self):
        cfg = self.config({"models": {"code-reviewer": {"codex": {"model": "gpt-5.6-sol", "reasoning_effort": "high"}}}})
        run(self.root, self.out, config=cfg, codex_config=self.codex_cfg)
        rev = self.profile("code-reviewer").read_text(encoding="utf-8")
        self.assertIn('name = "n1-code-reviewer"', rev)
        self.assertIn('description = "Read-only \\"cold\\" review \\u2014 findings with file:line."', rev)
        self.assertIn(f'developer_instructions = "Read and follow {self.root}/agents/code-reviewer.md exactly. Use only these tools: Read, Grep, Glob."', rev)
        self.assertIn('model = "gpt-5.6-sol"', rev)
        self.assertIn('model_reasoning_effort = "high"', rev)
        self.assertIn('sandbox_mode = "read-only"', rev)
        self.assertNotIn("sandbox_mode", self.profile("developer").read_text(encoding="utf-8"))

    def test_effort_clamping_and_astra_fallback_warn(self):
        low = self.config({"models": {"developer": {"codex": {"reasoning_effort": "low"}}}})
        result = run(self.root, self.out, config=low, codex_config=self.codex_cfg)
        self.assertIn("below policy floor 'medium'", result.stderr)
        self.assertEqual(toml_value(self.profile("developer"), "model_reasoning_effort"), "medium")
        no_effort = self.codex_home / "no-effort.toml"
        no_effort.write_text('''
[agents]
default_subagent_model = "flat-default"
''', encoding="utf-8")
        result = run(self.root, self.out, codex_config=no_effort, version="low-frontmatter")
        self.assertIn("product-analyst", result.stderr)
        self.assertIn("below policy floor 'medium'", result.stderr)
        self.assertEqual(toml_value(self.profile("product-analyst"), "model_reasoning_effort"), "medium")
        astra = self.config({"models": {"developer": {"codex": "gpt-6-astra"}}})
        result = run(self.root, self.out, config=astra, codex_config=self.codex_cfg, version="astra")
        self.assertIn("ineligible gpt-6-astra override for developer in context 'profile'", result.stderr)
        self.assertEqual(toml_value(self.profile("developer"), "model"), "gpt-5.6-terra")

    def test_unknown_role_uses_codex_default(self):
        model, effort = ap.resolve_profile({}, "unknown", {"default_subagent_model": "flat-default", "default_subagent_reasoning_effort": "high"},
                                           {"model": "unclassified"}, ap.load_model_policy(str(self.root)))
        self.assertEqual((model, effort), ("flat-default", "high"))

    def test_fingerprint_changes_when_final_clamped_effort_changes(self):
        cfg = self.config({"models": {"developer": {"codex": {"reasoning_effort": "low"}}}})
        run(self.root, self.out, config=cfg, codex_config=self.codex_cfg)
        base = self.profile("developer").read_text(encoding="utf-8").splitlines()[0]
        cfg.write_text(json.dumps({"models": {"developer": {"codex": {"reasoning_effort": "high"}}}}), encoding="utf-8")
        self.assertEqual(run(self.root, self.out, config=cfg, codex_config=self.codex_cfg).stdout.strip(), "written=1 unchanged=4")
        self.assertNotEqual(base, self.profile("developer").read_text(encoding="utf-8").splitlines()[0])

    def test_context_free_shell_profile_parity_and_declared_contextual_difference(self):
        cfg = self.config({"models": {"developer": {"codex": {"model": "custom-model", "reasoning_effort": "high"}}}})
        run(self.root, self.out, config=cfg, codex_config=self.codex_cfg)
        for persona in ("code-reviewer", "developer", "implementer", "fast-worker"):
            expected = (toml_value(self.profile(persona), "model"), toml_value(self.profile(persona), "model_reasoning_effort"))
            actual, stderr = self.shell_resolution(persona)
            self.assertEqual(stderr, "")
            self.assertEqual(actual, expected)
        cfg.write_text(json.dumps({"models": {}}), encoding="utf-8")
        run(self.root, self.out, config=cfg, codex_config=self.codex_cfg, version="context")
        (self.home / "memory" / "CASE").mkdir(parents=True)
        (self.home / "memory" / "CASE" / "overview.md").write_text("---\ntype: task\n---\n", encoding="utf-8")
        (self.home / "memory" / "CASE" / "analysis.md").write_text("<!-- n1:signals\nblast_radius: high\n-->\n", encoding="utf-8")
        contextual, stderr = self.shell_resolution("developer", "implementation")
        self.assertEqual(stderr, "")
        self.assertEqual(toml_value(self.profile("developer"), "model"), "gpt-5.6-terra")
        self.assertEqual(contextual, ("gpt-5.6-sol", "medium"))


if __name__ == "__main__":
    unittest.main()

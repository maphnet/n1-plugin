import importlib.util
import json
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
    (root / "agents" / "code-reviewer.md").write_text(
        '---\nname: code-reviewer\ndescription: "Read-only \\"cold\\" review — findings with file:line."\n'
        "model: opus\ntools: Read, Grep, Glob\n---\n# body\n", encoding="utf-8")
    (root / "agents" / "developer.md").write_text(
        "---\nname: developer\ndescription: \"Implements.\"\nmodel: sonnet\ntools: Read, Edit, Write, Bash, Grep, Glob\n---\n",
        encoding="utf-8")
    (root / "agents" / "implementer.md").write_text(
        "---\nname: implementer\ndescription: \"Wraps SDD.\"\nmodel: sonnet\n---\n", encoding="utf-8")
    (root / "agents" / "research-standards.md").write_text("---\nmodel: sonnet\neffort: medium\n---\n# rubric\n",
                                                           encoding="utf-8")


def run(root, out, config=None, codex_config=None, version="3.0.0"):
    argv = [sys.executable, str(REPO / "lib" / "agent_profiles.py"), "--plugin-root", str(root), "--out", str(out),
            "--version", version, "--codex-config", str(codex_config or (root / "nonexistent.toml"))]
    if config:
        argv += ["--config", str(config)]
    return subprocess.run(argv, capture_output=True, text=True, check=True).stdout.strip()


class AgentProfilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "plugin"
        self.out = self.tmp / ".codex" / "agents"
        make_plugin(self.root)
        self.codex_cfg = self.tmp / "config.toml"
        self.codex_cfg.write_text('[features]\nmulti_agent = true\n\n[agents]\nenabled = true\n'
                                  'default_subagent_model = "gpt-5.6-terra"\ndefault_subagent_reasoning_effort = "medium"\n',
                                  encoding="utf-8")

    def test_generates_only_named_personas_and_is_idempotent(self):
        first = run(self.root, self.out, codex_config=self.codex_cfg)
        self.assertEqual(first, "written=3 unchanged=0")
        self.assertEqual(sorted(p.name for p in self.out.iterdir()),
                         ["n1-code-reviewer.toml", "n1-developer.toml", "n1-implementer.toml"])
        mtimes = {p.name: p.stat().st_mtime_ns for p in self.out.iterdir()}
        second = run(self.root, self.out, codex_config=self.codex_cfg)
        self.assertEqual(second, "written=0 unchanged=3")
        self.assertEqual(mtimes, {p.name: p.stat().st_mtime_ns for p in self.out.iterdir()})

    def test_fingerprint_changes_with_root_version_persona_and_model(self):
        run(self.root, self.out, codex_config=self.codex_cfg)
        fp = lambda: (self.out / "n1-developer.toml").read_text(encoding="utf-8").splitlines()[0]
        base = fp()
        self.assertEqual(run(self.root, self.out, codex_config=self.codex_cfg, version="3.1.0"), "written=3 unchanged=0")
        self.assertNotEqual(base, fp())
        cfg = self.tmp / "n1.json"
        cfg.write_text(json.dumps({"models": {"developer": {"codex": "gpt-5.6"}}}), encoding="utf-8")
        self.assertEqual(run(self.root, self.out, config=cfg, codex_config=self.codex_cfg, version="3.1.0"),
                         "written=1 unchanged=2")
        self.assertIn('model = "gpt-5.6"', (self.out / "n1-developer.toml").read_text(encoding="utf-8"))
        (self.root / "agents" / "developer.md").write_text("---\nname: developer\ndescription: \"x\"\nmodel: sonnet\ntools: Read\n---\n",
                                                            encoding="utf-8")
        self.assertEqual(run(self.root, self.out, config=cfg, codex_config=self.codex_cfg, version="3.1.0"),
                         "written=1 unchanged=2")

    def test_toml_content(self):
        cfg = self.tmp / "n1.json"
        cfg.write_text(json.dumps({"models": {"code-reviewer": {"claude-code": "opus",
                                              "codex": {"model": "gpt-5.6-sol", "reasoning_effort": "high"}}}}),
                       encoding="utf-8")
        run(self.root, self.out, config=cfg, codex_config=self.codex_cfg)
        rev = (self.out / "n1-code-reviewer.toml").read_text(encoding="utf-8")
        self.assertIn('name = "n1-code-reviewer"', rev)
        self.assertIn('description = "Read-only \\"cold\\" review \\u2014 findings with file:line."', rev)
        self.assertIn(f'developer_instructions = "Read and follow {self.root}/agents/code-reviewer.md exactly. '
                      'Use only these tools: Read, Grep, Glob."', rev)
        self.assertIn('model = "gpt-5.6-sol"', rev)
        self.assertIn('model_reasoning_effort = "high"', rev)
        self.assertIn('sandbox_mode = "read-only"', rev)
        dev = (self.out / "n1-developer.toml").read_text(encoding="utf-8")
        self.assertNotIn("sandbox_mode", dev)
        self.assertIn('model = "gpt-5.6-terra"', dev)
        self.assertIn('model_reasoning_effort = "medium"', dev)
        imp = (self.out / "n1-implementer.toml").read_text(encoding="utf-8")
        self.assertNotIn("sandbox_mode", imp)
        self.assertNotIn("Use only these tools", imp)

    def test_missing_codex_config_omits_model(self):
        run(self.root, self.out)
        dev = (self.out / "n1-developer.toml").read_text(encoding="utf-8")
        self.assertNotIn("model =", dev)
        self.assertNotIn("model_reasoning_effort", dev)


if __name__ == "__main__":
    unittest.main()

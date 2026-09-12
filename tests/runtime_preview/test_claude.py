"""Offline package and policy tests for the Claude advisory runtime."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


PLUGIN_ROOT = Path(".")
ADAPTER_ROOT = Path("adapters/claude-code/preview")


def load_hook():
    spec = importlib.util.spec_from_file_location(
        "n1_runtime_hook", ADAPTER_ROOT / "hooks/enforce-preview.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ClaudeAdapterTests(unittest.TestCase):
    def test_existing_n1_plugin_owns_the_runtime_agents_without_a_second_identity(self):
        """Would fail if Claude needed a second plugin or lost the existing N1 identity."""
        manifest = json.loads((PLUGIN_ROOT / ".claude-plugin/plugin.json").read_text())
        marketplace = json.loads((PLUGIN_ROOT / ".claude-plugin/marketplace.json").read_text())
        self.assertEqual(manifest["name"], "n1")
        self.assertEqual(manifest["version"], "3.0.0")
        self.assertEqual(marketplace["plugins"][0]["name"], "n1")
        self.assertEqual(marketplace["plugins"][0]["version"], manifest["version"])
        self.assertFalse((ADAPTER_ROOT / ".claude-plugin").exists())
        self.assertTrue((PLUGIN_ROOT / "skills/n1-review/SKILL.md").is_file())
        self.assertTrue((PLUGIN_ROOT / "skills/n1-review-runtime/SKILL.md").is_file())
        for role in ("code-reviewer", "security-reviewer", "review-verifier"):
            persona = (PLUGIN_ROOT / "agents" / ("n1-runtime-" + role + ".md")).read_text()
            self.assertIn("name: n1-runtime-" + role, persona)
            self.assertIn("tools: Read, Grep, Glob", persona)
            self.assertNotIn("Bash", persona)
            self.assertIn("runtime/review/roles/" + role + ".md", persona)

    def test_registered_worker_gate_allows_only_read_search_tools(self):
        """Would fail if an alternate, nested, shell, or MCP tool became usable by a worker."""
        hook = load_hook()
        self.assertEqual(hook.decision("Read", True), {})
        self.assertEqual(hook.decision("Grep", True), {})
        self.assertEqual(hook.decision("Glob", True), {})
        for tool in ("Bash", "Shell", "Agent", "Task", "mcp__server__call", "unknown"):
            with self.subTest(tool=tool):
                self.assertEqual(hook.decision(tool, True), {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": "N1 runtime reviewers are read-only",
                    }
                })
        self.assertEqual(hook.decision("Bash", False), {})

    def test_worker_scoped_malformed_payload_denies_without_affecting_unrelated_events(self):
        """Would fail if malformed preview-worker events failed open or production events were blocked."""
        hook = load_hook()
        denied = hook.handle_payload(None, worker_scoped=True)
        self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(hook.handle_payload({"tool_name": "Bash"}, worker_scoped=False), {})

    def test_worker_scoped_read_paths_stay_within_supplied_source_or_input_roots(self):
        """Would fail if a reviewer could use a read tool to escape its pinned roots."""
        hook = load_hook()
        roots = ("/run/source", "/run/inputs")
        self.assertEqual(hook.handle_payload(
            {"tool_name": "Read", "tool_input": {"file_path": "/run/source/app.py"}},
            worker_scoped=True, roots=roots,
        ), {})
        for tool, value in (("Read", "/run/source/../state.json"),
                            ("Grep", "/run/state.json"),
                            ("Glob", "/run/inputs/../../outside")):
            with self.subTest(tool=tool, value=value):
                self.assertEqual(hook.handle_payload(
                    {"tool_name": tool, "tool_input": {"path": value, "file_path": value}},
                    worker_scoped=True, roots=roots,
                )["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_hook_cli_denies_a_registered_worker_shell_call(self):
        """Would fail if the installed Python hook stopped applying the real decision function."""
        result = subprocess.run(
            [sys.executable, str(ADAPTER_ROOT / "hooks/enforce-preview.py"), "--worker-scoped"],
            input=json.dumps({"tool_name": "Bash"}), text=True, capture_output=True, check=True,
        )
        self.assertEqual(json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_unrooted_hook_is_not_registered_until_the_host_can_scope_it(self):
        """Would fail if package config enabled a hook without worker identity and per-run roots."""
        hooks = json.loads((ADAPTER_ROOT / "hooks/hooks.json").read_text())
        commands = [item["command"] for entries in hooks["hooks"].values()
                    for entry in entries for item in entry["hooks"]]
        self.assertFalse(any("enforce-preview.py" in command for command in commands))

    def test_packaged_preflight_is_executable_and_blocks_before_the_shared_bridge(self):
        """Would fail if a caller could bypass the known-unverified host state into prepare."""
        result = subprocess.run(
            [sys.executable, str(ADAPTER_ROOT / "preflight.py"), "owner/repo#123"],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 3)
        value = json.loads(result.stdout)
        self.assertEqual(value["status"], "unsupported")
        self.assertIn("lifecycleControl", value["reasons"])
        self.assertEqual(result.stderr, "")

    def test_controller_skill_static_pressure_covers_native_lifecycle_fail_closed_rules(self):
        """Static pressure test: omission of a lifecycle safety rule must fail package qualification."""
        skill = (PLUGIN_ROOT / "skills/n1-review-runtime/SKILL.md").read_text()
        for required in (
            "owner/repo#123", "before waiting", "600-second", "fresh context",
            "rawText", "unsupported", "controller-rendered local report",
        ):
            with self.subTest(required=required):
                self.assertIn(required, skill)


if __name__ == "__main__":
    unittest.main()

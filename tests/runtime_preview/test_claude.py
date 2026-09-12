"""Offline package and policy tests for the Claude advisory preview."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path("adapters/claude-code/preview")


def load_hook():
    spec = importlib.util.spec_from_file_location("n1_preview_hook", ROOT / "hooks/enforce-preview.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ClaudeAdapterTests(unittest.TestCase):
    def test_package_is_separate_and_reviewers_are_native_read_only_agents(self):
        """Would fail if the preview leaked into the production package or granted execution."""
        manifest = json.loads((ROOT / ".claude-plugin/plugin.json").read_text())
        self.assertEqual(manifest, {
            "name": "n1-preview",
            "version": "0.1.0",
            "description": "Opt-in N1 advisory review qualification preview",
        })
        for role in ("code-reviewer", "security-reviewer", "review-verifier"):
            persona = (ROOT / "agents" / ("n1-preview-" + role + ".md")).read_text()
            self.assertIn("name: n1-preview-" + role, persona)
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
                        "permissionDecisionReason": "N1 preview reviewers are read-only",
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
            [sys.executable, str(ROOT / "hooks/enforce-preview.py"), "--worker-scoped"],
            input=json.dumps({"tool_name": "Bash"}), text=True, capture_output=True, check=True,
        )
        self.assertEqual(json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_controller_skill_static_pressure_covers_native_lifecycle_fail_closed_rules(self):
        """Static pressure test: omission of a lifecycle safety rule must fail package qualification."""
        skill = (ROOT / "skills/n1-review-preview/SKILL.md").read_text()
        for required in (
            "owner/repo#123", "before waiting", "600-second", "fresh context",
            "rawText", "unsupported", "controller-rendered local report",
        ):
            with self.subTest(required=required):
                self.assertIn(required, skill)


if __name__ == "__main__":
    unittest.main()

"""Offline package and enforcement tests for the Codex advisory preview."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - production keeps its older Python floor
    tomllib = None


ROOT = Path("adapters/codex/preview")


def load_hook():
    spec = importlib.util.spec_from_file_location("codex_policy", ROOT / "hooks/enforce-preview.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CodexAdapterTests(unittest.TestCase):
    def test_deny_shape(self):
        """Would fail if Codex received an undocumented or non-denying hook response."""
        result = load_hook().deny("mutation unavailable")
        self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(result["hookSpecificOutput"]["hookEventName"], "PreToolUse")
        self.assertEqual(
            result["hookSpecificOutput"]["permissionDecisionReason"],
            "mutation unavailable",
        )
        self.assertNotIn("continue", result)

    def test_reader_command_requires_one_canonical_trusted_invocation(self):
        """Would fail if shell syntax, alternate binaries, or extra arguments reached a worker shell."""
        hook = load_hook()
        executable = "/usr/bin/python3"
        reader = "/opt/n1/lib/runtime_review/reader.py"
        self.assertTrue(hook.allowed_reader_command(
            executable + " " + reader + " read src/module.py", executable, reader,
        ))
        self.assertTrue(hook.allowed_reader_command(
            executable + " " + reader + " search 'literal text'", executable, reader,
        ))
        rejected = (
            executable + " " + reader + " read src/module.py; id",
            executable + " " + reader + " read src/module.py > /tmp/out",
            executable + " " + reader + " read src/module.py\nid",
            executable + " " + reader + " read `id`",
            executable + " " + reader + " read $(id)",
            "ENV=x " + executable + " " + reader + " read src/module.py",
            "/usr/bin/python " + reader + " read src/module.py",
            executable + " /tmp/reader.py read src/module.py",
            executable + " " + reader + " exec src/module.py",
            executable + " " + reader + " read src/module.py extra",
            executable + "  " + reader + " read src/module.py",
        )
        for command in rejected:
            with self.subTest(command=command):
                self.assertFalse(hook.allowed_reader_command(command, executable, reader))

    def test_worker_gate_denies_everything_except_the_bound_reader(self):
        """Would fail if a worker gained patch, MCP, discovery, delegation, or arbitrary shell access."""
        hook = load_hook()
        executable = "/usr/bin/python3"
        reader = "/opt/n1/lib/runtime_review/reader.py"
        command = executable + " " + reader + " read app.py"
        self.assertEqual(hook.decision("exec_command", command, True, executable, reader), {})
        for tool in (
            "apply_patch", "mcp__server__call", "tool_search", "spawn_agent",
            "request_user_input", "web_search", "exec_command",
        ):
            candidate = command + " extra" if tool == "exec_command" else command
            with self.subTest(tool=tool):
                self.assertEqual(
                    hook.decision(tool, candidate, True, executable, reader)
                    ["hookSpecificOutput"]["permissionDecision"],
                    "deny",
                )
        self.assertEqual(hook.decision("apply_patch", command, False, executable, reader), {})

    def test_hook_payload_uses_only_one_string_cmd_field(self):
        """Would fail if the hook read a non-native, absent, malformed, or ambiguous command field."""
        hook = load_hook()
        executable = "/usr/bin/python3"
        reader = "/opt/n1/lib/runtime_review/reader.py"
        command = executable + " " + reader + " read app.py"
        valid = {"tool_name": "exec_command", "tool_input": {"cmd": command}}
        self.assertEqual(hook.handle_payload(valid, True, executable, reader), {})
        invalid = (
            {"tool_name": "exec_command", "tool_input": {}},
            {"tool_name": "exec_command", "tool_input": {"cmd": [command]}},
            {"tool_name": "exec_command", "tool_input": {
                "cmd": command, "command": command,
            }},
        )
        for payload in invalid:
            with self.subTest(payload=payload):
                result = hook.handle_payload(payload, True, executable, reader)
                self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_hook_cli_uses_cmd_and_denies_ambiguous_command_fields(self):
        """Would fail if the executable hook diverged from native cmd-field validation."""
        executable = "/usr/bin/python3"
        reader = "/opt/n1/lib/runtime_review/reader.py"
        command = executable + " " + reader + " read app.py"
        script = ROOT / "hooks/enforce-preview.py"
        valid = subprocess.run(
            [sys.executable, str(script), "--worker-scoped", executable, reader],
            input=json.dumps({"tool_name": "exec_command", "tool_input": {"cmd": command}}),
            capture_output=True, text=True,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(json.loads(valid.stdout), {})
        invalid = (
            {"tool_name": "exec_command", "tool_input": {}},
            {"tool_name": "exec_command", "tool_input": {"cmd": [command]}},
            {"tool_name": "exec_command", "tool_input": {
                "cmd": command, "command": command,
            }},
        )
        for payload in invalid:
            with self.subTest(payload=payload):
                denied = subprocess.run(
                    [sys.executable, str(script), "--worker-scoped", executable, reader],
                    input=json.dumps(payload), capture_output=True, text=True,
                )
                self.assertEqual(denied.returncode, 0, denied.stderr)
                self.assertEqual(
                    json.loads(denied.stdout)["hookSpecificOutput"]["permissionDecision"],
                    "deny",
                )

    @unittest.skipIf(tomllib is None, "TOML qualification requires Python 3.11+")
    def test_native_roles_are_distinct_read_only_templates_with_explicit_inheritance(self):
        """Would fail if a native role could edit, delegate, or silently select another model policy."""
        expected = {
            "n1_preview_code_reviewer.toml": (
                "n1_preview_code_reviewer",
                "N1 advisory correctness reviewer; no edits or delegation",
            ),
            "n1_preview_security_reviewer.toml": (
                "n1_preview_security_reviewer",
                "N1 advisory security reviewer; no edits or delegation",
            ),
            "n1_preview_review_verifier.toml": (
                "n1_preview_review_verifier",
                "N1 advisory finding verifier; no edits or delegation",
            ),
        }
        for filename, (name, description) in expected.items():
            with self.subTest(role=name):
                role = tomllib.loads((ROOT / "agents" / filename).read_text())
                self.assertEqual(role["name"], name)
                self.assertEqual(role["description"], description)
                self.assertEqual(role["sandbox_mode"], "read-only")
                self.assertEqual(
                    role["developer_instructions"],
                    "Read the supplied N1 request and packaged role instructions. Return only the specified JSON result.",
                )
                self.assertNotIn("model", role)
                self.assertNotIn("model_provider", role)
                self.assertNotIn("model_reasoning_effort", role)

    def test_package_is_separate_and_hooks_are_not_enabled_without_worker_scope(self):
        """Would fail if an untrusted package hook became a claimed enforcement boundary."""
        manifest = json.loads((ROOT / ".codex-plugin/plugin.json").read_text())
        self.assertEqual(manifest["name"], "preview")
        self.assertEqual(manifest["version"], "0.1.0")
        self.assertEqual(manifest["skills"], "./skills/")
        hooks = json.loads((ROOT / "hooks/hooks.json").read_text())
        self.assertEqual(hooks, {"hooks": {}})

    def test_packaged_preflight_rejects_even_caller_supplied_available_evidence(self):
        """Would fail if caller-controlled capability JSON could reach prepare or dispatch."""
        script = ROOT / "preflight.py"
        self.assertTrue(os.access(script, os.X_OK))
        blocked = subprocess.run(
            [sys.executable, str(script), "owner/repo#123"],
            capture_output=True, text=True,
        )
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertEqual(json.loads(blocked.stdout)["status"], "unsupported")

        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "available.json"
            evidence.write_text(json.dumps({
                "capabilities": {
                    name: {"status": "available", "evidence": ["caller claim"]}
                    for name in ("readSearchEnforced", "isolatedContext", "lifecycleControl")
                },
            }), encoding="utf-8")
            supplied = subprocess.run(
                [sys.executable, str(script), "owner/repo#123",
                 "--capabilities", str(evidence), "--observed", str(evidence)],
                capture_output=True, text=True,
            )
        self.assertNotEqual(supplied.returncode, 0)
        self.assertNotIn('"status": "completed"', supplied.stdout)

    def test_controller_skill_stays_unsupported_until_native_lifecycle_is_proven(self):
        """Static pressure check: removing a fail-closed lifecycle rule blocks qualification."""
        skill = (ROOT / "skills/n1-review-preview/SKILL.md").read_text()
        for required in (
            "$n1-review-preview owner/repo#123", "host fixed to `codex`",
            "unsupported", "before waiting", "600-second", "fresh nonforked context",
            "observed envelopes", "cancellation receipts", "controller-rendered local report",
        ):
            with self.subTest(required=required):
                self.assertIn(required, skill)
        adapter = (ROOT / "adapter.md").read_text()
        for name, document in (("skill", skill), ("adapter", adapter)):
            with self.subTest(document=name):
                self.assertNotIn("task_name", document)
                self.assertIn("supported role/profile binding", document)


if __name__ == "__main__":
    unittest.main()

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("transcript_codex", REPO / "lib" / "transcript_codex.py")
tc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tc)


def rec(ordinal, rtype, payload, ts="2026-09-12T09:36:01.000Z"):
    return json.dumps({"timestamp": ts, "ordinal": ordinal, "type": rtype, "payload": payload})


def msg(role, text, kind="input_text"):
    return {"type": "message", "id": "m", "role": role, "content": [{"type": kind, "text": text}]}


class CodexTranscriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.path = self.tmp / "2026" / "09" / "12" / "rollout-2026-09-12T12-34-42-abc.jsonl"
        self.path.parent.mkdir(parents=True)
        lines = [
            rec(0, "session_meta", {"session_id": "abc", "cwd": "/mnt/c/Dev/n1-plugin", "cli_version": "0.154.0"}),
            rec(1, "response_item", msg("developer", "<skills_instructions>...</skills_instructions>")),
            rec(2, "response_item", msg("user", "# AGENTS.md instructions\n\n<INSTRUCTIONS>...")),
            rec(3, "response_item", msg("user", "<environment_context>cwd=/x</environment_context>")),
            rec(4, "response_item", msg("user", "$n1-start NP-1"), ts="2026-09-12T09:36:02.000Z"),
            rec(5, "response_item", msg("assistant", "Which tracker?", "output_text"), ts="2026-09-12T09:36:03.000Z"),
            rec(6, "response_item", {"type": "function_call", "name": "request_user_input", "arguments": "{}"}, ts="2026-09-12T09:36:04.000Z"),
            rec(7, "response_item", {"type": "function_call_output", "call_id": "c", "output": "{}"}),
            rec(8, "response_item", msg("user", "Jira"), ts="2026-09-12T09:36:05.000Z"),
            rec(9, "response_item", {"type": "custom_tool_call", "name": "exec_command", "input": "ls"}),
            rec(10, "token_usage_record", {"usage": {"input_tokens": 1}}),
            rec(11, "event_msg", {"type": "task_complete"}),
            "not json",
        ]
        self.path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_iter_events_filters_injected_context_and_flags_asks(self):
        events = list(tc.iter_events(self.path))
        self.assertEqual([e["kind"] for e in events], ["user", "assistant", "tool_call", "user", "tool_call"])
        self.assertEqual(events[0]["text"], "$n1-start NP-1")
        self.assertEqual(events[0]["timestamp"], "2026-09-12T09:36:02.000Z")
        self.assertEqual(events[1]["text"], "Which tracker?")
        self.assertEqual((events[2]["tool"], events[2]["asked"]), ("request_user_input", True))
        self.assertEqual((events[4]["tool"], events[4]["asked"]), ("exec_command", False))

    def test_session_files_and_cwd(self):
        self.assertEqual(tc.session_files(self.tmp), [self.path])
        self.assertEqual(tc.session_cwd(self.path), "/mnt/c/Dev/n1-plugin")


# --- Import telemetry_codex module ---
SPEC_TC = importlib.util.spec_from_file_location("telemetry_codex", REPO / "lib" / "telemetry_codex.py")
tcx = importlib.util.module_from_spec(SPEC_TC)
SPEC_TC.loader.exec_module(tcx)


class CodexUsageExtractionTest(unittest.TestCase):
    """Tests for telemetry_codex.extract_usage — session-total strategy."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.path = self.tmp / "rollout.jsonl"

    def _write(self, lines):
        self.path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_last_usage_record_wins(self):
        """Session-total strategy: last token_usage_record is the cumulative total."""
        self._write([
            rec(0, "session_meta", {"session_id": "s1", "cwd": "/x", "cli_version": "0.154.0"}),
            rec(1, "token_usage_record", {"usage": {"input_tokens": 100, "output_tokens": 10}}),
            rec(2, "token_usage_record", {"usage": {"input_tokens": 500, "output_tokens": 50,
                "cached_input_tokens": 300, "reasoning_tokens": 20}}),
        ])
        u = tcx.extract_usage(str(self.path))
        self.assertEqual(u["input_tokens"], 500)
        self.assertEqual(u["output_tokens"], 50)
        self.assertEqual(u["cached_input_tokens"], 300)
        self.assertEqual(u["reasoning_tokens"], 20)
        self.assertEqual(u["usage_scope"], "session-total")
        self.assertEqual(u["usage_status"], "complete")
        self.assertEqual(u["parse_failures"], 0)
        self.assertEqual(u["cli_version"], "0.154.0")

    def test_missing_file_returns_unknown(self):
        u = tcx.extract_usage(str(self.tmp / "nonexistent.jsonl"))
        self.assertIsNone(u["input_tokens"])
        self.assertIsNone(u["output_tokens"])
        self.assertEqual(u["usage_status"], "unknown")

    def test_no_usage_records_returns_unknown(self):
        self._write([
            rec(0, "session_meta", {"session_id": "s1", "cwd": "/x"}),
            rec(1, "response_item", msg("assistant", "hello", "output_text")),
        ])
        u = tcx.extract_usage(str(self.path))
        self.assertIsNone(u["input_tokens"])
        self.assertEqual(u["usage_status"], "unknown")

    def test_malformed_usage_counted_as_parse_failure(self):
        self._write([
            rec(0, "session_meta", {"session_id": "s1", "cwd": "/x"}),
            rec(1, "token_usage_record", {"usage": "not_a_dict"}),
            rec(2, "token_usage_record", {"usage": {"input_tokens": 200, "output_tokens": 30}}),
        ])
        u = tcx.extract_usage(str(self.path))
        self.assertEqual(u["input_tokens"], 200)
        self.assertEqual(u["usage_status"], "partial")
        self.assertEqual(u["parse_failures"], 1)

    def test_null_fields_not_zero_when_absent(self):
        """Fields not present in the usage dict should be None, not 0."""
        self._write([
            rec(0, "token_usage_record", {"usage": {"input_tokens": 100}}),
        ])
        u = tcx.extract_usage(str(self.path))
        self.assertEqual(u["input_tokens"], 100)
        self.assertIsNone(u["output_tokens"])
        self.assertIsNone(u["cached_input_tokens"])
        self.assertIsNone(u["reasoning_tokens"])


class CodexLinkageExtractionTest(unittest.TestCase):
    """Tests for telemetry_codex.extract_linkage — session identity and relationships."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.path = self.tmp / "rollout.jsonl"

    def _write(self, lines):
        self.path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_basic_linkage(self):
        self._write([
            rec(0, "session_meta", {"session_id": "abc", "cwd": "/x",
                "parent_id": "parent-1", "fork_of": "fork-1", "reused_from": "reuse-1"}),
        ])
        m = tcx.extract_linkage(str(self.path))
        self.assertEqual(m["session_id"], "abc")
        self.assertEqual(m["parent_id"], "parent-1")
        self.assertEqual(m["fork_of"], "fork-1")
        self.assertEqual(m["reused_from"], "reuse-1")

    def test_standalone_session_has_null_linkage(self):
        self._write([
            rec(0, "session_meta", {"session_id": "abc", "cwd": "/x"}),
        ])
        m = tcx.extract_linkage(str(self.path))
        self.assertEqual(m["session_id"], "abc")
        self.assertIsNone(m["parent_id"])
        self.assertIsNone(m["fork_of"])
        self.assertIsNone(m["reused_from"])

    def test_missing_file_returns_all_null(self):
        m = tcx.extract_linkage(str(self.tmp / "nope.jsonl"))
        self.assertIsNone(m["session_id"])
        self.assertIsNone(m["parent_id"])

    def test_no_session_meta_returns_all_null(self):
        self._write([
            rec(0, "response_item", msg("user", "hello")),
        ])
        m = tcx.extract_linkage(str(self.path))
        self.assertIsNone(m["session_id"])


class CodexSchemaVersionTest(unittest.TestCase):
    def test_schema_version_is_4(self):
        self.assertEqual(tcx.SCHEMA_VERSION, 4)


if __name__ == "__main__":
    unittest.main()

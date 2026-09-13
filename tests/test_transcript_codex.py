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


if __name__ == "__main__":
    unittest.main()

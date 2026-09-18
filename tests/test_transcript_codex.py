import importlib.util
import json
import sqlite3
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

SPEC_BF = importlib.util.spec_from_file_location("backfill_codex", REPO / "scripts" / "backfill-codex-telemetry.py")
bf = importlib.util.module_from_spec(SPEC_BF)
SPEC_BF.loader.exec_module(bf)


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
        self.assertEqual(u["usage_status"], "partial")
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

    def test_thread_usage_is_preferred_over_final_request(self):
        """A 0.154 session total (10549084) is not its final request (167855)."""
        self._write([
            rec(0, "token_usage_record", {"response_id": "r1", "usage": {
                "input_tokens": 167348, "cached_input_tokens": 166656,
                "cache_write_input_tokens": 0, "output_tokens": 507,
                "reasoning_output_tokens": 208, "total_tokens": 167855,
            }, "thread_token_usage": {
                "input_tokens": 10520036, "cached_input_tokens": 10122496,
                "cache_write_input_tokens": 0, "output_tokens": 29048,
                "reasoning_output_tokens": 6987, "total_tokens": 10549084,
            }}),
        ])
        u = tcx.extract_usage(self.path)
        self.assertEqual(u["total_tokens"], 10549084)
        self.assertEqual(u["input_tokens"], 10520036)
        self.assertEqual(u["reasoning_tokens"], 6987)
        self.assertEqual(u["cache_creation_tokens"], 0)

    def test_request_usage_is_summed_when_thread_total_is_unavailable(self):
        self._write([
            rec(0, "token_usage_record", {"response_id": "r1", "usage": {
                "input_tokens": 100, "cached_input_tokens": 80,
                "cache_write_input_tokens": 3, "output_tokens": 10,
                "reasoning_output_tokens": 4, "total_tokens": 110,
            }, "thread_token_usage": {}}),
            rec(1, "token_usage_record", {"response_id": "r2", "usage": {
                "input_tokens": 200, "cached_input_tokens": 150,
                "cache_write_input_tokens": 5, "output_tokens": 20,
                "reasoning_output_tokens": 6, "total_tokens": 220,
            }, "thread_token_usage": {}}),
        ])
        u = tcx.extract_usage(self.path)
        self.assertEqual(u["input_tokens"], 300)
        self.assertEqual(u["cached_input_tokens"], 230)
        self.assertEqual(u["cache_creation_tokens"], 8)
        self.assertEqual(u["output_tokens"], 30)
        self.assertEqual(u["reasoning_tokens"], 10)
        self.assertEqual(u["total_tokens"], 330)

    def test_legacy_cumulative_usage_uses_last_total(self):
        self._write([
            rec(0, "token_usage_record", {"usage": {"input_tokens": 100, "output_tokens": 10}}),
            rec(1, "token_usage_record", {"usage": {"input_tokens": 300, "output_tokens": 30}}),
        ])
        u = tcx.extract_usage(self.path)
        self.assertEqual(u["input_tokens"], 300)
        self.assertEqual(u["output_tokens"], 30)

    def test_event_token_count_uses_legacy_cumulative_total(self):
        self._write([
            rec(0, "event_msg", {"type": "token_count", "info": {"total_token_usage": {
                "input_tokens": 300, "cached_input_tokens": 200, "output_tokens": 30,
                "reasoning_output_tokens": 5, "total_tokens": 330,
            }}}),
        ])
        self.assertEqual(tcx.extract_usage(self.path)["total_tokens"], 330)

    def test_incomplete_request_usage_is_partial(self):
        self._write([
            rec(0, "token_usage_record", {"response_id": "r1", "usage": {"input_tokens": 10}, "thread_token_usage": {}}),
        ])
        u = tcx.extract_usage(self.path)
        self.assertEqual(u["input_tokens"], 10)
        self.assertIsNone(u["output_tokens"])
        self.assertEqual(u["usage_status"], "partial")

    def test_duplicate_request_id_is_counted_once(self):
        usage = {"input_tokens": 10, "cached_input_tokens": 8, "cache_write_input_tokens": 0,
                 "output_tokens": 2, "reasoning_output_tokens": 1, "total_tokens": 12}
        self._write([
            rec(0, "token_usage_record", {"response_id": "r1", "usage": usage, "thread_token_usage": {}}),
            rec(1, "token_usage_record", {"response_id": "r1", "usage": usage, "thread_token_usage": {}}),
        ])
        self.assertEqual(tcx.extract_usage(self.path)["total_tokens"], 12)


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

    def test_current_session_meta_ids_are_normalized(self):
        self._write([
            rec(0, "session_meta", {"id": "thread-1", "session_id": "legacy-id",
                "parent_thread_id": "thread-0", "forked_from_id": "thread-fork"}),
        ])
        m = tcx.extract_linkage(self.path)
        self.assertEqual(m["session_id"], "thread-1")
        self.assertEqual(m["thread_id"], "thread-1")
        self.assertEqual(m["parent_id"], "thread-0")
        self.assertEqual(m["fork_of"], "thread-fork")


class CodexDescendantDiscoveryTest(unittest.TestCase):
    def test_sqlite_edges_find_unique_descendant_rollouts(self):
        tmp = Path(tempfile.mkdtemp())
        root = tmp / "root.jsonl"
        child = tmp / "child.jsonl"
        grandchild = tmp / "grandchild.jsonl"
        for path, thread_id in ((root, "root"), (child, "child"), (grandchild, "grandchild")):
            path.write_text(rec(0, "session_meta", {"id": thread_id}) + "\n", encoding="utf-8")
        db = tmp / "state.sqlite"
        con = sqlite3.connect(db)
        con.executescript("""
            CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT);
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);
        """)
        con.executemany("INSERT INTO threads VALUES (?, ?)", [("child", str(child)), ("grandchild", str(grandchild))])
        con.executemany("INSERT INTO thread_spawn_edges VALUES (?, ?, 'open')", [("root", "child"), ("child", "grandchild")])
        con.commit()
        con.close()
        self.assertEqual(tcx.discover_descendant_paths(root, db), [child, grandchild])

    def test_usage_tree_adds_only_explicit_descendants(self):
        tmp = Path(tempfile.mkdtemp())
        root = tmp / "root.jsonl"
        child = tmp / "child.jsonl"
        unrelated = tmp / "unrelated.jsonl"
        root.write_text("\n".join([
            rec(0, "session_meta", {"id": "root"}),
            rec(1, "token_usage_record", {"response_id": "root-request", "usage": {
                "input_tokens": 100, "cached_input_tokens": 90, "cache_write_input_tokens": 1,
                "output_tokens": 10, "reasoning_output_tokens": 2, "total_tokens": 110,
            }, "thread_token_usage": {}}),
        ]) + "\n", encoding="utf-8")
        child.write_text("\n".join([
            rec(0, "session_meta", {"id": "child"}),
            rec(1, "token_usage_record", {"response_id": "child-request", "usage": {
                "input_tokens": 200, "cached_input_tokens": 180, "cache_write_input_tokens": 3,
                "output_tokens": 20, "reasoning_output_tokens": 4, "total_tokens": 220,
            }, "thread_token_usage": {}}),
        ]) + "\n", encoding="utf-8")
        unrelated.write_text(rec(0, "session_meta", {"id": "unrelated"}) + "\n", encoding="utf-8")
        db = tmp / "state.sqlite"
        con = sqlite3.connect(db)
        con.executescript("""
            CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT);
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);
        """)
        con.executemany("INSERT INTO thread_spawn_edges VALUES ('root', ?, 'open')", [("child",), ("missing",)])
        con.executemany("INSERT INTO threads VALUES (?, ?)", [("child", str(child)), ("unrelated", str(unrelated))])
        con.commit()
        con.close()
        usage = tcx.extract_usage_tree(root, db)
        self.assertEqual(usage["input_tokens"], 300)
        self.assertEqual(usage["total_tokens"], 330)
        self.assertEqual(usage["session_count"], 2)
        self.assertEqual(usage["usage_scope"], "session-tree")
        self.assertEqual(usage["missing_session_count"], 1)
        self.assertEqual(usage["usage_status"], "partial")
        self.assertEqual(usage["root_usage"]["total_tokens"], 110)

    def test_tree_marks_discovery_unknown_without_sqlite(self):
        root = Path(tempfile.mkdtemp()) / "root.jsonl"
        root.write_text(rec(0, "session_meta", {"id": "root"}) + "\n", encoding="utf-8")
        usage = tcx.extract_usage_tree(root, root.with_suffix(".sqlite"))
        self.assertEqual(usage["discovery_status"], "unavailable")
        self.assertEqual(usage["headless_coverage"], "unknown")
        self.assertEqual(usage["usage_scope"], "root-only")

    def test_cycle_cannot_reinclude_root(self):
        tmp = Path(tempfile.mkdtemp())
        root = tmp / "root.jsonl"
        child = tmp / "child.jsonl"
        root.write_text(rec(0, "session_meta", {"id": "root"}) + "\n", encoding="utf-8")
        child.write_text(rec(0, "session_meta", {"id": "child"}) + "\n", encoding="utf-8")
        db = tmp / "state.sqlite"
        con = sqlite3.connect(db)
        con.executescript("""
            CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT);
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);
            INSERT INTO thread_spawn_edges VALUES ('root', 'child', 'open');
            INSERT INTO thread_spawn_edges VALUES ('child', 'root', 'open');
        """)
        con.executemany("INSERT INTO threads VALUES (?, ?)", [("root", str(root)), ("child", str(child))])
        con.commit()
        con.close()
        self.assertEqual(tcx.discover_descendant_paths(root, db), [child])


class CodexSchemaVersionTest(unittest.TestCase):
    def test_schema_version_is_5(self):
        self.assertEqual(tcx.SCHEMA_VERSION, 5)


class CodexBackfillTest(unittest.TestCase):
    def test_v4_complete_record_is_reprocessed_as_codex(self):
        tmp = Path(tempfile.mkdtemp())
        session = tmp / "rollout.jsonl"
        session.write_text("\n".join([
            rec(0, "session_meta", {"id": "root", "cli_version": "0.154.0"}),
            rec(1, "token_usage_record", {"response_id": "r1", "usage": {"input_tokens": 10},
                "thread_token_usage": {"input_tokens": 100, "cached_input_tokens": 80,
                    "cache_write_input_tokens": 0, "output_tokens": 20,
                    "reasoning_output_tokens": 5, "total_tokens": 120}}),
        ]) + "\n", encoding="utf-8")
        record = {"schema_version": 4, "parser_schema_version": 4, "host": "claude-code",
                  "usage_status": "complete", "summary": {"cache_efficiency": 0}}
        result = bf.backfill_record(record, session)
        self.assertEqual(result["schema_version"], 5)
        self.assertEqual(result["host"], "codex")
        self.assertEqual(result["summary"]["total_tokens"], 120)
        self.assertEqual(result["summary"]["cache_efficiency"], 0.8)
        self.assertEqual(result["usage_coverage"]["headless_coverage"], "unknown")


if __name__ == "__main__":
    unittest.main()

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("benchmark", REPO / "scripts" / "benchmark.py")
bm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bm)


def write_jsonl(path: Path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for r in records:
            fh.write(r if isinstance(r, str) else json.dumps(r))
            fh.write("\n")


def make_run(run_id="n1-run-1", version="2.80.0", project="proj", ticket="T-1",
             started="2026-09-01T10:00:00Z", completed="2026-09-01T11:00:00Z",
             outcome="pr_created", steps=None, outcomes=None, summary=None, orchestrator=None):
    return {
        "schema_version": 2, "run_id": run_id, "session_id": None, "n1_version": version,
        "project": project, "ticket_id": ticket, "branch": ticket,
        "started_at": started, "completed_at": completed, "final_outcome": outcome,
        "steps": steps if steps is not None else [
            {"step": "brainstorm", "step_number": 3, "started_at": "2026-09-01T10:00:00Z",
             "completed_at": "2026-09-01T10:30:00Z", "outcome": "pass"},
            {"step": "implementation", "step_number": 7, "started_at": "2026-09-01T10:30:00Z",
             "completed_at": "2026-09-01T11:00:00Z", "outcome": "pass"},
        ],
        "agents": [], "decisions": [],
        "outcomes": outcomes if outcomes is not None else [
            {"event": "outcome", "outcomes": {"review_pass_first_try": "true",
                                              "qa_pass_first_try": "true", "fix_cycles_count": "1"}}],
        "summary": summary if summary is not None else {"compaction_count": 2},
        "orchestrator": orchestrator if orchestrator is not None else {"totals": {"output_tokens": 5000}},
    }


class TempDirs:
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.n1 = self.tmp / "n1"
        self.projects = self.tmp / "projects"
        self.out = self.tmp / "out"
        for p in (self.n1, self.projects, self.out):
            p.mkdir(parents=True)

    def run_path(self, run: dict) -> Path:
        return self.n1 / run["project"] / "memory" / run["ticket_id"] / "telemetry" / "runs" / f"{run['run_id']}.jsonl"

    def add_run(self, run: dict, extra_lines=()):
        p = self.run_path(run)
        write_jsonl(p, [run, *extra_lines])
        run["_source_path"] = str(p)
        return run


class LoadRunsTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()

    def test_loads_records_and_counts_malformed_lines(self):
        self.d.add_run(make_run(run_id="a"), extra_lines=["{not json"])
        self.d.add_run(make_run(run_id="b", project="other", ticket="T-2"))
        runs, malformed = bm.load_runs(self.d.n1)
        self.assertEqual(sorted(r["run_id"] for r in runs), ["a", "b"])
        self.assertEqual(malformed, 1)
        self.assertTrue(runs[0]["_source_path"].endswith(".jsonl"))

    def test_dedupes_by_run_id_keeping_last(self):
        first = make_run(run_id="a", outcome=None)
        second = make_run(run_id="a", outcome="pr_created")
        write_jsonl(self.d.run_path(first), [first, second])
        runs, _ = bm.load_runs(self.d.n1)
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["final_outcome"], "pr_created")

    def test_ignores_lines_without_schema_version(self):
        self.d.add_run(make_run(run_id="a"), extra_lines=[{"event": "outcome", "run_id": "a"}])
        runs, malformed = bm.load_runs(self.d.n1)
        self.assertEqual(len(runs), 1)
        self.assertEqual(malformed, 0)

    def test_missing_root_returns_empty(self):
        runs, malformed = bm.load_runs(self.d.tmp / "nope")
        self.assertEqual(runs, [])
        self.assertEqual(malformed, 0)


class EligibilityTest(unittest.TestCase):
    def test_eligible_outcomes(self):
        for o in ("pr_created", "pr_skipped", "investigation_complete"):
            self.assertTrue(bm.is_eligible(make_run(outcome=o)), o)

    def test_ineligible_outcomes(self):
        for o in (None, "", "superseded", "operational_fix"):
            self.assertFalse(bm.is_eligible(make_run(outcome=o)), repr(o))


class ParseTsTest(unittest.TestCase):
    def test_parses_z_and_fractional(self):
        self.assertEqual(bm.parse_ts("2026-09-01T10:00:00Z"), 1788256800.0)
        self.assertEqual(bm.parse_ts("2026-09-01T10:00:00.123Z"), 1788256800.0)

    def test_none_and_garbage(self):
        self.assertIsNone(bm.parse_ts(None))
        self.assertIsNone(bm.parse_ts("yesterday"))


def human(ts, text, session="s1"):
    return {"type": "user", "uuid": ts, "timestamp": ts, "sessionId": session,
            "origin": {"kind": "human"}, "message": {"role": "user", "content": text}}


def tool_result(ts):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "x", "content": "ok"}]}}


def assistant(ts, text=None, ask=False):
    content = []
    if text is not None:
        content.append({"type": "text", "text": text})
    if ask:
        content.append({"type": "tool_use", "name": "AskUserQuestion", "input": {"questions": []}})
    return {"type": "assistant", "timestamp": ts, "message": {"role": "assistant", "content": content}}


class LinkingTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()
        self.run = self.d.add_run(make_run())

    def raw_agents(self, session_path):
        p = self.d.n1 / "proj" / "memory" / "T-1" / "telemetry" / "raw" / "agents" / "n1-run-1.jsonl"
        write_jsonl(p, [
            {"run_id": "n1-run-1", "layer": "agent", "event": "start", "agent_id": "a1"},
            {"run_id": "n1-run-1", "layer": "agent", "event": "stop", "agent_id": "a1",
             "transcript_path": "/x/subagents/agent-a1.jsonl", "session_transcript_path": session_path},
        ])

    def transcript(self, slug, name, records):
        p = self.d.projects / slug / f"{name}.jsonl"
        write_jsonl(p, records)
        return p

    def test_agent_event_link_wins_when_file_exists(self):
        t = self.transcript("-mnt-c-Dev-proj", "sess", [human("2026-09-01T10:05:00Z", "T-1 go")])
        self.raw_agents(str(t))
        path, method = bm.link_transcript(self.run, self.d.projects)
        self.assertEqual((path, method), (str(t), "agent_event"))

    def test_agent_event_path_missing_falls_back_to_heuristic(self):
        self.raw_agents("/nonexistent/session.jsonl")
        t = self.transcript("-mnt-c-Dev-proj", "sess", [human("2026-09-01T10:05:00Z", "working on T-1")])
        path, method = bm.link_transcript(self.run, self.d.projects)
        self.assertEqual((path, method), (str(t), "heuristic"))

    def test_heuristic_matches_worktree_slug_and_requires_ticket_and_window(self):
        self.transcript("-mnt-c-Dev-proj", "old", [human("2026-08-01T10:05:00Z", "T-1 earlier")])
        self.transcript("-mnt-c-Dev-proj", "other-ticket", [human("2026-09-01T10:05:00Z", "T-9 stuff")])
        good = self.transcript("-mnt-c-Dev-proj--claude-worktrees-proj-T-1", "wt",
                               [human("2026-09-01T10:05:00Z", "start T-1"), human("2026-09-01T10:40:00Z", "ok")])
        path, method = bm.link_transcript(self.run, self.d.projects)
        self.assertEqual((path, method), (str(good), "heuristic"))

    def test_heuristic_prefers_most_turns_in_window(self):
        self.transcript("-mnt-c-Dev-proj", "one", [human("2026-09-01T10:05:00Z", "T-1 a")])
        two = self.transcript("-mnt-c-Dev-proj", "two", [human("2026-09-01T10:05:00Z", "T-1 a"),
                                                         human("2026-09-01T10:06:00Z", "b")])
        path, _ = bm.link_transcript(self.run, self.d.projects)
        self.assertEqual(path, str(two))

    def test_unlinked_when_nothing_matches(self):
        self.transcript("-mnt-c-Dev-unrelated", "x", [human("2026-09-01T10:05:00Z", "T-1")])
        self.assertEqual(bm.link_transcript(self.run, self.d.projects), (None, "unlinked"))

    def test_candidate_dirs_ignore_case_and_match_worktrees(self):
        for slug in ("-mnt-c-Dev-Proj", "-mnt-c-Dev-proj--claude-worktrees-proj-T-1", "-mnt-c-Dev-projx", "-home-u-other"):
            (self.d.projects / slug).mkdir()
        got = sorted(p.name for p in bm.candidate_project_dirs(self.d.projects, "proj", "T-1"))
        self.assertEqual(got, ["-mnt-c-Dev-Proj", "-mnt-c-Dev-proj--claude-worktrees-proj-T-1"])


class ExtractTurnsTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()
        self.run = make_run()

    def write(self, records):
        p = self.d.projects / "-mnt-c-Dev-proj" / "s.jsonl"
        write_jsonl(p, records)
        return str(p)

    def test_filters_and_attributes(self):
        path = self.write([
            human("2026-09-01T10:01:00Z", "<command-name>/n1:n1-start</command-name>"),
            assistant("2026-09-01T10:02:00Z", "Which option?", ask=True),
            human("2026-09-01T10:03:00Z", "2"),
            tool_result("2026-09-01T10:04:00Z"),
            {"type": "user", "isMeta": True, "timestamp": "2026-09-01T10:04:30Z",
             "message": {"role": "user", "content": "skill body"}},
            assistant("2026-09-01T10:05:00Z", "Done with brainstorm."),
            human("2026-09-01T10:35:00Z", "no, wrong file"),
            human("2026-09-01T10:36:00Z", "[Request interrupted by user]"),
            human("2026-09-01T12:00:00Z", "later"),
        ])
        turns = bm.extract_turns(path, self.run)
        self.assertEqual([t["text"] for t in turns], ["2", "no, wrong file", "later"])
        self.assertEqual([t["step"] for t in turns], ["brainstorm", "implementation", "outside"])
        self.assertEqual(turns[0]["id"], "n1-run-1#0")
        self.assertTrue(turns[0]["asked_question"])
        self.assertEqual(turns[0]["prev_assistant"], "Which option?")
        self.assertFalse(turns[1]["asked_question"])
        self.assertEqual(turns[1]["prev_assistant"], "Done with brainstorm.")

    def test_truncates_text(self):
        path = self.write([assistant("2026-09-01T10:02:00Z", "a" * 1000),
                           human("2026-09-01T10:03:00Z", "b" * 1000)])
        t = bm.extract_turns(path, self.run)[0]
        self.assertEqual(len(t["text"]), bm.TEXT_LIMIT)
        self.assertEqual(len(t["prev_assistant"]), bm.TEXT_LIMIT)

    def test_list_content_and_missing_origin(self):
        path = self.write([{"type": "user", "timestamp": "2026-09-01T10:03:00Z",
                            "message": {"role": "user", "content": [{"type": "text", "text": "hi"}]}}])
        self.assertEqual(bm.extract_turns(path, self.run)[0]["text"], "hi")

    def test_unreadable_transcript_gives_empty(self):
        self.assertEqual(bm.extract_turns(str(self.d.tmp / "missing.jsonl"), self.run), [])


def turn(text, asked=False, prev="Summary."):
    return {"id": "r#0", "timestamp": "2026-09-01T10:03:00Z", "step": "brainstorm",
            "text": text, "prev_assistant": prev, "asked_question": asked}


class HeuristicTest(unittest.TestCase):
    def test_empty_is_noise(self):
        self.assertEqual(bm.classify_heuristic(turn("   ")), "noise")

    def test_short_reply_after_ask_is_answer(self):
        self.assertEqual(bm.classify_heuristic(turn("Option 2, the second one", asked=True)), "answer")

    def test_short_reply_after_question_mark_is_answer(self):
        self.assertEqual(bm.classify_heuristic(turn("use jira", prev="Which tracker?")), "answer")

    def test_long_reply_after_ask_is_ambiguous(self):
        self.assertEqual(bm.classify_heuristic(turn("x" * 201, asked=True)), "ambiguous")

    def test_approval_vocab(self):
        for t in ("yes", "Y", "ok.", "Looks good!", "go", "3", "LGTM", "do it"):
            self.assertEqual(bm.classify_heuristic(turn(t)), "approval", t)

    def test_answer_beats_approval_when_asked(self):
        self.assertEqual(bm.classify_heuristic(turn("1", asked=True)), "answer")

    def test_other_is_ambiguous(self):
        self.assertEqual(bm.classify_heuristic(turn("no, revert that and use the other file")), "ambiguous")
        self.assertEqual(bm.classify_heuristic(turn("also add a CSV export")), "ambiguous")


class CollectTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()
        self.run = self.d.add_run(make_run())
        self.d.add_run(make_run(run_id="n1-run-2", ticket="T-2", outcome=None))
        write_jsonl(self.d.projects / "-mnt-c-Dev-proj" / "s.jsonl", [
            assistant("2026-09-01T10:02:00Z", "Which?", ask=True),
            human("2026-09-01T10:03:00Z", "T-1: option 2"),
            human("2026-09-01T10:40:00Z", "no, revert that"),
        ])

    def collect(self, *extra):
        out_file = self.d.tmp / "amb.json"
        rc = bm.main(["collect", "--n1-root", str(self.d.n1), "--projects-dir", str(self.d.projects),
                      "--out", str(self.d.out), "--ambiguous-out", str(out_file), *extra])
        self.assertEqual(rc, 0)
        return json.loads(out_file.read_text())

    def test_collect_caches_and_emits_ambiguous(self):
        res = self.collect()
        self.assertEqual(res["runs_new"], 2)
        self.assertEqual([a["id"] for a in res["ambiguous"]], ["n1-run-1#1"])
        cache = json.loads((self.d.out / "runs" / "n1-run-1.json").read_text())
        self.assertEqual(cache["link_method"], "heuristic")
        self.assertEqual([t["label"] for t in cache["turns"]], ["answer", "ambiguous"])
        self.assertEqual(cache["turns"][0]["label_source"], "heuristic")
        skipped = json.loads((self.d.out / "runs" / "n1-run-2.json").read_text())
        self.assertFalse(skipped["eligible"])
        self.assertEqual(skipped["link_method"], "skipped")

    def test_second_collect_skips_cached_but_re_emits_unlabeled_ambiguous(self):
        self.collect()
        res = self.collect()
        self.assertEqual((res["runs_new"], res["runs_cached"]), (0, 2))
        self.assertEqual(len(res["ambiguous"]), 1)

    def test_force_reprocesses(self):
        self.collect()
        res = self.collect("--force")
        self.assertEqual(res["runs_new"], 2)

    def test_since_filters_old_runs(self):
        res = self.collect("--since", "2026-09-02")
        self.assertEqual(res["runs_total"], 0)

    def test_missing_root_is_clean_exit(self):
        rc = bm.main(["collect", "--n1-root", str(self.d.tmp / "none"), "--projects-dir", str(self.d.projects),
                      "--out", str(self.d.out)])
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()

import contextlib
import io
import importlib.util
import json
import os
import shlex
import subprocess
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


_UNSET = object()


def make_run(run_id="n1-run-1", version="2.80.0", project="proj", ticket="T-1",
             started="2026-09-01T10:00:00Z", completed=_UNSET,
             outcome="pr_created", steps=_UNSET, outcomes=_UNSET, summary=_UNSET, orchestrator=_UNSET,
             host="claude-code"):
    return {
        "schema_version": 2, "parser_schema_version": 6, "run_id": run_id, "host": host, "session_id": None, "n1_version": version,
        "project": project, "ticket_id": ticket, "branch": ticket,
        "started_at": started,
        "completed_at": completed if completed is not _UNSET else "2026-09-01T11:00:00Z",
        "final_outcome": outcome,
        "steps": steps if steps is not _UNSET else [
            {"step": "brainstorm", "step_number": 3, "started_at": "2026-09-01T10:00:00Z",
             "completed_at": "2026-09-01T10:30:00Z", "outcome": "pass"},
            {"step": "implementation", "step_number": 7, "started_at": "2026-09-01T10:30:00Z",
             "completed_at": "2026-09-01T11:00:00Z", "outcome": "pass"},
        ],
        "agents": [], "decisions": [],
        "outcomes": outcomes if outcomes is not _UNSET else [
            {"event": "outcome", "outcomes": {"review_pass_first_try": "true",
                                              "qa_pass_first_try": "true", "fix_cycles_count": "1"}}],
        "summary": summary if summary is not _UNSET else {"compaction_count": 2},
        "orchestrator": orchestrator if orchestrator is not _UNSET else {"totals": {"output_tokens": 5000}},
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
        for o in ("pr_created", "investigation_complete"):
            self.assertTrue(bm.is_eligible(make_run(outcome=o)), o)

    def test_ineligible_outcomes(self):
        for o in (None, "", "superseded", "operational_fix", "pr_skipped"):
            self.assertFalse(bm.is_eligible(make_run(outcome=o)), repr(o))


class InferOutcomeTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()

    def overview(self, ticket, text, project="proj"):
        p = self.d.n1 / project / "memory" / ticket / "overview.md"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")

    def load(self):
        runs, _ = bm.load_runs(self.d.n1)
        return {r["run_id"]: r for r in runs}

    def test_succeeded_pr_step_infers_pr_created(self):
        self.d.add_run(make_run(run_id="a", outcome="", steps=[{"step": "pr", "outcome": "success"}]))
        r = self.load()["a"]
        self.assertEqual(r["final_outcome"], "pr_created")
        self.assertTrue(r["outcome_inferred"])
        self.assertTrue(bm.is_eligible(r))

    def test_codex_review_decision_with_branch_infers_pr_created(self):
        run = make_run(run_id="a", outcome="", steps=[])
        run["decisions"] = [{"id": "codex-review", "signals": {"branch": "T-1", "outcome": "ran"}}]
        self.d.add_run(run)
        self.assertEqual(self.load()["a"]["final_outcome"], "pr_created")

    def test_overview_signals_apply_to_last_run_only(self):
        self.overview("T-1", "---\ntier: standard\npr_url: https://example.test/pr/1\n---\n# T-1\n")
        self.d.add_run(make_run(run_id="old", outcome="", steps=[], started="2026-09-01T10:00:00Z"))
        self.d.add_run(make_run(run_id="new", outcome="", steps=[], started="2026-09-02T10:00:00Z"))
        runs = self.load()
        self.assertEqual(runs["new"]["final_outcome"], "pr_created")
        self.assertEqual(runs["old"]["final_outcome"], "")
        self.assertNotIn("outcome_inferred", runs["old"])

    def test_overview_frontmatter_final_outcome_wins(self):
        self.overview("T-1", "---\nfinal_outcome: investigation_complete\n---\n")
        self.d.add_run(make_run(run_id="a", outcome="", steps=[{"step": "pr", "outcome": "success"}]))
        self.assertEqual(self.load()["a"]["final_outcome"], "investigation_complete")

    def test_finish_section_pr_url(self):
        self.overview("T-1", "---\ntier: simple\n---\n# T-1\n\n## Finish\npr_url: https://example.test/pr/2\n")
        self.d.add_run(make_run(run_id="a", outcome="", steps=[]))
        self.assertEqual(self.load()["a"]["final_outcome"], "pr_created")

    def test_skipped_pr_is_pr_skipped_and_stays_ineligible(self):
        self.overview("T-1", "---\nstep: done\n---\n")
        self.d.add_run(make_run(run_id="a", outcome="", steps=[{"step": "pr", "outcome": "skipped"}]))
        r = self.load()["a"]
        self.assertEqual(r["final_outcome"], "pr_skipped")
        self.assertFalse(bm.is_eligible(r))

    def test_investigation_deliverable(self):
        self.d.add_run(make_run(run_id="a", outcome=None,
                                steps=[{"step": "investigation-deliverable", "outcome": "pass"}]))
        self.assertEqual(self.load()["a"]["final_outcome"], "investigation_complete")

    def test_set_outcome_is_never_overridden(self):
        run = make_run(run_id="a", outcome="abandoned", steps=[{"step": "pr", "outcome": "success"}])
        run["decisions"] = [{"id": "codex-review", "signals": {"branch": "T-1"}}]
        self.d.add_run(run)
        r = self.load()["a"]
        self.assertEqual(r["final_outcome"], "abandoned")
        self.assertNotIn("outcome_inferred", r)

    def test_no_signal_stays_empty(self):
        self.d.add_run(make_run(run_id="a", outcome=""))
        self.assertEqual(self.load()["a"]["final_outcome"], "")

    def test_older_run_keeps_its_own_tier(self):
        self.overview("T-1", "---\ntier: complex\nplanning_need: plan\n---\n")
        old = make_run(run_id="old", started="2026-01-01T00:00:00Z")
        old["estimated_tier"] = "simple"
        self.d.add_run(old)
        self.d.add_run(make_run(run_id="new", started="2026-02-01T00:00:00Z"))
        runs = self.load()
        old_c = bm.build_run_cache(runs["old"], self.d.projects)
        new_c = bm.build_run_cache(runs["new"], self.d.projects)
        self.assertEqual((old_c["tier"], old_c["plan_path"]), ("simple", "none"))
        self.assertEqual((new_c["tier"], new_c["plan_path"]), ("complex", "plan"))

    def test_build_run_cache_light_fields(self):
        self.overview("T-1", "---\ntier: complex\nplanning_need: plan\n---\n")
        self.d.add_run(make_run(run_id="a", outcome="", steps=[{"step": "pr", "outcome": "success"}]))
        c = bm.build_run_cache(self.load()["a"], self.d.projects)
        self.assertEqual((c["tier"], c["plan_path"], c["outcome_inferred"], c["eligible"]),
                         ("complex", "plan", True, True))
        plain = make_run(run_id="b", ticket="T-2")
        plain["estimated_tier"] = "simple"
        c = bm.build_run_cache(plain, self.d.projects)
        self.assertEqual((c["tier"], c["plan_path"], c["outcome_inferred"]), ("simple", "none", False))


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


def task_notification(ts):
    return {"type": "user", "timestamp": ts, "origin": {"kind": "task-notification"},
            "message": {"role": "user", "content": "<task-notification>done</task-notification>"}}


def assistant(ts, text=None, ask=False):
    content = []
    if text is not None:
        content.append({"type": "text", "text": text})
    if ask:
        content.append({"type": "tool_use", "name": "AskUserQuestion", "input": {"questions": []}})
    return {"type": "assistant", "timestamp": ts, "message": {"role": "assistant", "content": content}}


def q(text, labels):
    return {"question": text, "options": [{"label": lbl} for lbl in labels]}


def ask_use(ts, tid, questions, sidechain=False):
    rec = {"type": "assistant", "timestamp": ts, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tid, "name": "AskUserQuestion", "input": {"questions": questions}}]}}
    if sidechain:
        rec["isSidechain"] = True
    return rec


def ask_result(ts, tid, text):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tid, "content": text}]}}


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

    def test_run_record_link_wins_over_agent_event(self):
        t = self.transcript("-mnt-c-Dev-proj", "inline", [human("2026-09-01T10:05:00Z", "T-1 go")])
        self.raw_agents(str(t))
        self.run["session_transcript_path"] = str(t)
        path, method = bm.link_transcript(self.run, self.d.projects)
        self.assertEqual((path, method), (str(t), "run_record"))

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

    def test_heuristic_does_not_match_prefix_ticket(self):
        self.transcript("-mnt-c-Dev-proj", "prefix", [human("2026-09-01T10:05:00Z", "working on T-10")])
        self.assertEqual(bm.link_transcript(self.run, self.d.projects), (None, "unlinked"))


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

    def test_cached_collect_refreshes_light_fields_and_keeps_turns(self):
        self.collect()
        p = self.d.out / "runs" / "n1-run-1.json"
        cache = json.loads(p.read_text())
        cache.update(tier="stale", plan_path="stale", outcome_inferred=True)
        p.write_text(json.dumps(cache))
        res = self.collect()
        self.assertEqual(res["runs_cached"], 2)
        fresh = json.loads(p.read_text())
        self.assertNotEqual(fresh["tier"], "stale")
        self.assertNotEqual(fresh["plan_path"], "stale")
        self.assertFalse(fresh["outcome_inferred"])
        self.assertEqual(fresh["turns"], cache["turns"])

    def test_force_reprocesses(self):
        self.collect()
        res = self.collect("--force")
        self.assertEqual(res["runs_new"], 2)

    def test_since_filters_old_runs(self):
        res = self.collect("--since", "2026-09-02")
        self.assertEqual(res["runs_total"], 0)

    def test_until_is_inclusive_end_of_day(self):
        self.d.add_run(make_run(run_id="n1-run-undated", ticket="T-9", started=None))
        self.assertEqual(self.collect("--until", "2026-08-31")["runs_total"], 0)
        self.assertEqual(self.collect("--until", "2026-09-01")["runs_total"], 2)  # undated excluded
        for bad in ("garbage", "2026-02-30"):
            with self.assertRaises(SystemExit) as cm, contextlib.redirect_stderr(io.StringIO()):
                bm.main(["collect", "--until", bad])
            self.assertEqual(cm.exception.code, 2)

    def test_missing_root_is_clean_exit(self):
        rc = bm.main(["collect", "--n1-root", str(self.d.tmp / "none"), "--projects-dir", str(self.d.projects),
                      "--out", str(self.d.out)])
        self.assertEqual(rc, 0)

    def test_skips_codex_runs_in_mixed_host_history(self):
        codex_run = make_run(run_id="n1-run-codex", ticket="T-3")
        codex_run["host"] = "codex"
        self.d.add_run(codex_run)
        res = self.collect()
        self.assertEqual(res["runs_new"], 2)
        self.assertEqual(res["runs_skipped_host"], 1)
        self.assertFalse((self.d.out / "runs" / "n1-run-codex.json").exists())

    def test_cached_eligible_run_is_rebuilt_when_inference_disappears(self):
        self.collect()
        p = self.d.out / "runs" / "n1-run-2.json"
        c = json.loads(p.read_text())
        c["eligible"], c["outcome_inferred"] = True, True
        p.write_text(json.dumps(c))
        self.collect()
        self.assertFalse(json.loads(p.read_text())["eligible"])

    def test_cached_ineligible_run_is_rebuilt_once_inference_makes_it_eligible(self):
        self.collect()
        self.assertFalse(json.loads((self.d.out / "runs" / "n1-run-2.json").read_text())["eligible"])
        self.d.add_run(make_run(run_id="n1-run-2", ticket="T-2", outcome=None,
                                steps=[{"step": "pr", "outcome": "success"}]))
        p1 = self.d.out / "runs" / "n1-run-1.json"
        old = json.loads(p1.read_text())
        old["turns"][1]["label"], old["turns"][1]["label_source"] = "correction", "judge"
        for k in ("tier", "plan_path", "outcome_inferred"):
            old.pop(k)
        p1.write_text(json.dumps(old))
        res = self.collect()
        self.assertEqual((res["runs_new"], res["runs_cached"]), (1, 1))
        rebuilt = json.loads((self.d.out / "runs" / "n1-run-2.json").read_text())
        self.assertTrue(rebuilt["eligible"])
        self.assertTrue(rebuilt["outcome_inferred"])
        self.assertEqual(rebuilt["final_outcome"], "pr_created")
        kept = json.loads(p1.read_text())
        self.assertEqual(kept["turns"][1]["label_source"], "judge")
        self.assertEqual((kept["tier"], kept["plan_path"], kept["outcome_inferred"]), ("unknown", "none", False))


def labeled(label, step="brainstorm", n=0):
    return {"id": f"r#{n}", "timestamp": "x", "step": step, "text": "t", "prev_assistant": "",
            "asked_question": False, "label": label, "label_source": "heuristic", "reason": None}


class MetricsTest(unittest.TestCase):
    def test_turn_metrics_and_per_step(self):
        cache = {"run_record": make_run(), "turns": [
            labeled("answer"), labeled("correction", n=1), labeled("correction", "implementation", 2),
            labeled("approval", n=3), labeled("instruction", n=4), labeled("noise", n=5)]}
        bm.compute_run_metrics(cache)
        m = cache["metrics"]
        self.assertEqual((m["interventions"], m["answers"], m["corrections"]), (3, 1, 2))
        self.assertEqual(m["brainstorm_interactions"], 4)
        self.assertEqual(m["autonomous_interventions"], 1)
        self.assertEqual(cache["per_step"]["brainstorm"]["corrections"], 1)
        self.assertEqual(cache["per_step"]["implementation"]["interventions"], 1)

    def test_outside_turns_excluded_from_interventions(self):
        cache = {"run_record": make_run(), "turns": [
            labeled("answer", "outside"), labeled("correction", "outside", 1),
            labeled("answer", "brainstorm", 2), labeled("instruction", "outside", 3)]}
        bm.compute_run_metrics(cache)
        m = cache["metrics"]
        self.assertEqual(m["interventions"], 1)
        self.assertEqual(m["answers"], 1)
        self.assertEqual(m["corrections"], 0)
        self.assertEqual(m["brainstorm_interactions"], 1)
        self.assertEqual(m["autonomous_interventions"], 0)

    def test_telemetry_metrics(self):
        cache = {"run_record": make_run(), "turns": []}
        bm.compute_run_metrics(cache)
        m = cache["metrics"]
        self.assertEqual(m["fix_cycles"], 1.0)
        self.assertEqual(m["review_pass_first_try"], 1.0)
        self.assertEqual(m["duration_min"], 60.0)
        self.assertEqual(m["orchestrator_output_tokens"], 5000.0)
        self.assertEqual(m["compactions"], 2.0)

    def test_compactions_requires_v6(self):
        for version, expected in ((5, None), (6, 2.0)):
            run = make_run()
            run["parser_schema_version"] = version
            cache = {"run_record": run, "turns": []}
            bm.compute_run_metrics(cache)
            self.assertEqual(cache["metrics"]["compactions"], expected)

    def test_missing_data_yields_none(self):
        run = make_run(outcomes=[], summary={}, orchestrator=None, completed=None)
        cache = {"run_record": run, "turns": []}
        bm.compute_run_metrics(cache)
        m = cache["metrics"]
        for k in ("fix_cycles", "review_pass_first_try", "duration_min", "orchestrator_output_tokens", "compactions"):
            self.assertIsNone(m[k], k)
        self.assertEqual(m["interventions"], 0)

    def test_unlinked_run_has_none_turn_metrics(self):
        cache = {"run_record": make_run(), "turns": [], "link_method": "unlinked"}
        bm.compute_run_metrics(cache)
        self.assertIsNone(cache["metrics"]["interventions"])

    def test_questions_per_run_counts_asked_only(self):
        cache = {"run_record": make_run(), "turns": [], "questions": [
            {"step": "brainstorm", "resolution": "auto-decided"},
            {"step": "brainstorm", "resolution": "asked"},
            {"step": "plan", "resolution": "decide-for-me"}]}
        bm.compute_run_metrics(cache)
        self.assertEqual(cache["metrics"]["questions_per_run"], 1.0)
        self.assertEqual(cache["metrics"]["brainstorm_questions"], 2.0)

    def test_review_pass_first_try_hard(self):
        cache = {"run_record": make_run(), "turns": []}
        bm.compute_run_metrics(cache)
        self.assertIsNone(cache["metrics"]["review_pass_first_try_hard"])  # pre-5.83.0 run: n/a
        for raw, expected in (("true", 1.0), ("false", 0.0), ("", None)):
            run = make_run(outcomes=[{"event": "outcome", "outcomes": {
                "review_pass_first_try": "false", "review_pass_first_try_hard": raw}}])
            cache = {"run_record": run, "turns": []}
            bm.compute_run_metrics(cache)
            self.assertEqual(cache["metrics"]["review_pass_first_try_hard"], expected, raw)
            self.assertEqual(cache["metrics"]["review_pass_first_try"], 0.0)

    def test_session_and_orchestrator_cache_creation(self):
        def run_with(status):
            run = make_run(summary={"total_cache_creation_tokens": 900},
                           orchestrator={"totals": {"cache_creation_tokens": 300}})
            if status:
                run["usage_status"] = status
            cache = {"run_record": run, "turns": []}
            bm.compute_run_metrics(cache)
            return cache["metrics"]
        m = run_with(None)
        self.assertEqual(m["session_cache_creation_tokens"], 900.0)
        self.assertIsNone(m["orchestrator_cache_creation_tokens"])  # gated: usage not complete
        self.assertEqual(run_with("complete")["orchestrator_cache_creation_tokens"], 300.0)

    def test_metric_registry_shape(self):
        names = [m.name for m in bm.METRICS]
        self.assertEqual(names, ["interventions", "answers", "corrections",
                                 "brainstorm_interactions", "autonomous_interventions",
                                 "fix_cycles", "review_pass_first_try", "review_pass_first_try_hard",
                                 "duration_min", "work_min", "stall_min", "orchestrator_output_tokens", "compactions",
                                 "session_cache_creation_tokens", "orchestrator_cache_creation_tokens",
                                 "questions_per_run", "brainstorm_questions",
                                 "answer_matches_recommendation", "decide_for_me_share",
                                 "inherited_share",
                                 "bash_calls_per_run", "api_calls_per_run",
                                 "orchestrator_api_calls_per_run", "orchestrator_bash_calls_per_run",
                                 "orchestrator_input_tokens_per_run", "orchestrator_cost_ratio"])
        self.assertTrue(all(m.direction in ("lower", "higher") for m in bm.METRICS))


def asst_with_tools(ts, tool_names, sidechain=False):
    """Build an assistant transcript record with the given tool_use names in its content."""
    content = [{"type": "tool_use", "id": f"t{i}", "name": n, "input": {}} for i, n in enumerate(tool_names)]
    rec = {"type": "assistant", "timestamp": ts, "message": {"role": "assistant", "content": content}}
    if sidechain:
        rec["isSidechain"] = True
    return rec


class ReadAnswersTest(unittest.TestCase):
    T0, T1 = "2026-09-01T10:01:00Z", "2026-09-01T10:02:00Z"
    DB = q("Pick DB?", ["SQLite (Recommended)", "Postgres"])

    def setUp(self):
        self.d = TempDirs()

    def answers(self, records):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, records)
        return bm.read_answers(p)

    def test_recommended_label_followed(self):
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [self.DB]),
            ask_result(self.T1, "a1", 'Your questions have been answered: "Pick DB?"="SQLite (Recommended)". '
                                      "You can now continue with the user's answers in mind.")]), (1, 1))

    def test_other_option_and_label_without_suffix(self):
        cache_q = q("Cache?", ["Redis (Recommended)", "None"])
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [self.DB, cache_q]),
            ask_result(self.T1, "a1", 'Your questions have been answered: "Pick DB?"="Postgres", '
                                      '"Cache?"="Redis". You can now continue.')]), (1, 2))

    def test_free_text_with_quotes_is_answered_not_followed(self):
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [self.DB]),
            ask_result(self.T1, "a1", 'The user answered: "use "both", really"')]), (0, 1))

    def test_user_answered_prefix_with_multiple_questions_counts_both(self):
        cache_q = q("Cache?", ["Redis (Recommended)", "None"])
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [self.DB, cache_q]),
            ask_result(self.T1, "a1", 'The user answered: "Pick DB?"="SQLite (Recommended)", '
                                      '"Cache?"="None"')]), (1, 2))

    def test_user_answered_prefix_with_single_question_recommended_is_followed(self):
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [self.DB]),
            ask_result(self.T1, "a1", 'The user answered: "Pick DB?"="SQLite (Recommended)"')]), (1, 1))

    def test_quotes_inside_an_answer_do_not_shift_the_next_one(self):
        a = q("A?", ["A1 (Recommended)", "A2"])
        b = q("B?", ["B1 (Recommended)", "B2"])
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [a, b]),
            ask_result(self.T1, "a1", 'Your questions have been answered: "A?"="say "hi", ok", "B?"="B1". Done.')]),
            (1, 2))

    def test_question_without_recommended_option_is_excluded(self):
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [q("Name?", ["x", "y"])]),
            ask_result(self.T1, "a1", 'Your questions have been answered: "Name?"="x".')]), (0, 0))

    def test_interrupted_unmatched_and_sidechain_are_unanswered(self):
        self.assertEqual(self.answers([
            ask_use(self.T0, "a1", [self.DB]),
            ask_result(self.T1, "a1", "[Tool call interrupted by user]"),
            ask_use(self.T0, "a2", [self.DB]),
            ask_result(self.T1, "zz", 'Your questions have been answered: "Pick DB?"="Postgres".'),
            ask_use(self.T0, "a3", [self.DB], sidechain=True),
            ask_result(self.T1, "a3", 'Your questions have been answered: "Pick DB?"="Postgres".')]), (0, 0))

    def test_answers_outside_run_window_are_excluded(self):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, [
            ask_use(self.T0, "a1", [self.DB]),
            ask_result(self.T1, "a1", 'Your questions have been answered: "Pick DB?"="SQLite (Recommended)".')])
        self.assertEqual(bm.read_answers(p, bm.parse_ts("2026-09-01T10:00:00Z"), bm.parse_ts("2026-09-01T10:03:00Z")), (1, 1))
        self.assertEqual(bm.read_answers(p, bm.parse_ts("2026-09-01T10:05:00Z"), bm.parse_ts("2026-09-01T10:06:00Z")), (0, 0))

    def test_metric_from_compute_run_metrics(self):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, [ask_use(self.T0, "a1", [self.DB, q("Cache?", ["Redis (Recommended)", "None"])]),
                        ask_result(self.T1, "a1", 'Your questions have been answered: '
                                                  '"Pick DB?"="SQLite (Recommended)", "Cache?"="None".')])
        cache = {"run_record": make_run(), "turns": [], "transcript_path": str(p)}
        bm.compute_run_metrics(cache)
        self.assertEqual(cache["metrics"]["answer_matches_recommendation"], 0.5)
        cache = {"run_record": make_run(), "turns": [], "transcript_path": None}
        bm.compute_run_metrics(cache)
        self.assertIsNone(cache["metrics"]["answer_matches_recommendation"])


class ReadWaitSecondsTest(unittest.TestCase):
    S, E = bm.parse_ts("2026-09-01T10:00:00Z"), bm.parse_ts("2026-09-01T11:00:00Z")

    def setUp(self):
        self.d = TempDirs()

    def wait(self, records, s=_UNSET, e=_UNSET):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, records)
        return bm.read_wait_seconds(p, self.S if s is _UNSET else s, self.E if e is _UNSET else e)

    def test_threshold_is_120_seconds(self):
        self.assertEqual(self.wait([assistant("2026-09-01T10:00:00Z", "q"), human("2026-09-01T10:01:59Z", "a")]), 0)
        self.assertEqual(self.wait([assistant("2026-09-01T10:00:00Z", "q"), human("2026-09-01T10:02:00Z", "a")]), 120)

    def test_ask_answer_gap_counts_tool_result_gap_does_not(self):
        self.assertEqual(self.wait([
            ask_use("2026-09-01T10:00:00Z", "a1", [q("Pick?", ["x (Recommended)"])]),
            ask_result("2026-09-01T10:05:00Z", "a1", 'The user answered: "x"'),
            assistant("2026-09-01T10:06:00Z", "run"),
            tool_result("2026-09-01T10:16:00Z")]), 300)

    def test_gap_clipped_to_run_window(self):
        self.assertEqual(self.wait([
            assistant("2026-09-01T09:50:00Z", "q"), human("2026-09-01T10:05:00Z", "a"),
            assistant("2026-09-01T10:58:00Z", "q"), human("2026-09-01T11:30:00Z", "a")]), 300 + 120)

    def test_rate_limit_gap_counts(self):
        limit = assistant("2026-09-01T10:00:00Z", "usage limit")
        limit.update({"isApiErrorMessage": True, "error": "rate_limit"})
        self.assertEqual(self.wait([limit, tool_result("2026-09-01T10:30:00Z")]), 1800)

    def test_sidechain_records_ignored(self):
        side = assistant("2026-09-01T10:01:00Z", "agent")
        side["isSidechain"] = True
        self.assertEqual(self.wait([assistant("2026-09-01T10:00:00Z", "q"), side,
                                    human("2026-09-01T10:05:00Z", "a")]), 300)

    def test_missing_window_is_none(self):
        self.assertIsNone(self.wait([assistant("2026-09-01T10:00:00Z", "q")], s=None))

    def gaps(self, records):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, records)
        return bm._scan_gaps(p, self.S, self.E)

    def test_stall_is_long_gap_not_ending_in_human_turn(self):
        self.assertEqual(self.gaps([assistant("2026-09-01T10:00:00Z", "w"),
                                    task_notification("2026-09-01T10:59:00Z")]), (0.0, 0.0))
        self.assertEqual(self.gaps([assistant("2026-09-01T09:00:00Z", "w"),
                                    task_notification("2026-09-01T10:30:00Z")]), (0.0, 1800.0))

    def test_stall_threshold_is_3600_seconds(self):
        s, e = bm.parse_ts("2026-09-01T09:00:00Z"), bm.parse_ts("2026-09-01T12:00:00Z")
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, [assistant("2026-09-01T09:00:00Z", "w"), task_notification("2026-09-01T09:59:59Z"),
                        assistant("2026-09-01T09:59:59Z", "w"), task_notification("2026-09-01T10:59:59Z")])
        self.assertEqual(bm._scan_gaps(p, s, e), (0.0, 3600.0))

    def test_human_and_rate_limit_gaps_are_wait_not_stall(self):
        self.assertEqual(self.gaps([assistant("2026-09-01T09:00:00Z", "q"),
                                    human("2026-09-01T10:30:00Z", "a")]), (1800.0, 0.0))
        limit = assistant("2026-09-01T09:00:00Z", "usage limit")
        limit.update({"isApiErrorMessage": True, "error": "rate_limit"})
        self.assertEqual(self.gaps([limit, tool_result("2026-09-01T10:30:00Z")]), (1800.0, 0.0))

    def test_long_gap_into_human_after_non_assistant_is_neither(self):
        self.assertEqual(self.gaps([tool_result("2026-09-01T09:00:00Z"),
                                    human("2026-09-01T10:30:00Z", "a")]), (0.0, 0.0))

    def test_work_min_metric(self):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, [assistant("2026-09-01T10:00:00Z", "q"), human("2026-09-01T10:30:00Z", "a")])
        cache = {"run_record": make_run(), "turns": [], "transcript_path": str(p)}
        bm.compute_run_metrics(cache)
        self.assertEqual((cache["metrics"]["duration_min"], cache["metrics"]["work_min"]), (60.0, 30.0))
        cache = {"run_record": make_run(), "turns": [], "transcript_path": None}
        bm.compute_run_metrics(cache)
        self.assertIsNone(cache["metrics"]["work_min"])

    def test_work_min_excludes_stall_and_stall_min_reports_it(self):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, [assistant("2026-09-01T10:00:00Z", "w"), task_notification("2026-09-01T11:00:00Z")])
        cache = {"run_record": make_run(), "turns": [], "transcript_path": str(p)}
        bm.compute_run_metrics(cache)
        self.assertEqual((cache["metrics"]["work_min"], cache["metrics"]["stall_min"]), (0.0, 60.0))
        self.assertEqual(bm.WorkMinMetric().compute({**make_run(), "_wait_s": 600.0}, []), 50.0)  # no _stall_s


class CountToolCallsTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()

    def write(self, records):
        p = self.d.tmp / "transcript.jsonl"
        write_jsonl(p, records)
        return p

    def test_counts_bash_and_total(self):
        p = self.write([
            asst_with_tools("2026-09-01T10:01:00Z", ["Bash", "Bash", "Read"]),
            asst_with_tools("2026-09-01T10:02:00Z", ["Bash", "Edit"]),
        ])
        bash, api = bm.count_tool_calls(p)
        self.assertEqual(bash, 3)
        self.assertEqual(api, 5)

    def test_excludes_sidechain_records(self):
        p = self.write([
            asst_with_tools("2026-09-01T10:01:00Z", ["Bash"]),
            asst_with_tools("2026-09-01T10:02:00Z", ["Bash", "Read"], sidechain=True),
        ])
        bash, api = bm.count_tool_calls(p)
        self.assertEqual(bash, 1)
        self.assertEqual(api, 1)

    def test_empty_transcript_returns_zeros(self):
        p = self.write([human("2026-09-01T10:01:00Z", "hello")])
        bash, api = bm.count_tool_calls(p)
        self.assertEqual(bash, 0)
        self.assertEqual(api, 0)

    def test_missing_file_returns_zeros(self):
        bash, api = bm.count_tool_calls(self.d.tmp / "nonexistent.jsonl")
        self.assertEqual(bash, 0)
        self.assertEqual(api, 0)

    def test_compute_run_metrics_injects_tool_counts(self):
        p = self.write([asst_with_tools("2026-09-01T10:01:00Z", ["Bash", "Read", "Bash"])])
        cache = {"run_record": make_run(), "turns": [], "transcript_path": str(p)}
        bm.compute_run_metrics(cache)
        self.assertEqual(cache["metrics"]["bash_calls_per_run"], 2.0)
        self.assertEqual(cache["metrics"]["api_calls_per_run"], 3.0)

    def test_compute_run_metrics_no_transcript_yields_none(self):
        cache = {"run_record": make_run(), "turns": [], "transcript_path": None}
        bm.compute_run_metrics(cache)
        self.assertIsNone(cache["metrics"]["bash_calls_per_run"])
        self.assertIsNone(cache["metrics"]["api_calls_per_run"])


class ApplyLabelsTest(unittest.TestCase):
    def test_applies_valid_labels_and_falls_back(self):
        cache = {"turns": [
            {**labeled("ambiguous", n=0), "label_source": None},
            {**labeled("ambiguous", n=1), "label_source": None},
            {**labeled("ambiguous", n=2), "label_source": None},
            labeled("answer", n=3)]}
        fallbacks = bm.apply_labels(cache, {
            "r#0": {"label": "correction", "reason": "user said wrong file"},
            "r#1": {"label": "banana", "reason": ""},
        })
        self.assertEqual(fallbacks, 2)
        got = [(t["label"], t["label_source"]) for t in cache["turns"]]
        self.assertEqual(got, [("correction", "judge"), ("instruction", "fallback"),
                               ("instruction", "fallback"), ("answer", "heuristic")])
        self.assertEqual(cache["turns"][0]["reason"], "user said wrong file")


def cache_for(version, run_id, interventions, eligible=True, started="2026-09-01T10:00:00Z", link="heuristic", host="claude-code"):
    return {"run_id": run_id, "n1_version": version, "host": host, "eligible": eligible, "started_at": started,
            "completed_at": "2026-09-01T11:00:00Z",
            "link_method": link if eligible else "skipped", "project": "p", "ticket_id": "T",
            "metrics": {"interventions": interventions, "answers": interventions, "corrections": 0.0,
                        "brainstorm_interactions": 0.0, "autonomous_interventions": interventions,
                        "fix_cycles": 1.0, "review_pass_first_try": 1.0, "duration_min": 10.0,
                        "orchestrator_output_tokens": None, "compactions": 0.0} if eligible else {},
            "turns": []}


class AggregateTest(unittest.TestCase):
    def test_quality_coverage_excludes_unlinkable_by_construction(self):
        caches = [cache_for("3.0.0", f"r{i}", 1.0) for i in range(4)]
        noproj = cache_for("3.0.0", "np", None, link="unlinked")
        noproj["project"] = ""
        nots = cache_for("3.0.0", "nt", None, link="unlinked")
        nots["completed_at"] = None
        other = cache_for("3.0.0", "ot", None, link="unlinked")
        g = bm.aggregate(caches + [noproj, nots, other], "version")["claude-code/3.0.0"]
        self.assertEqual(g["n_unlinked"], 3)
        self.assertAlmostEqual(g["quality_coverage"], 4 / 5, places=3)
        self.assertEqual([bm.unlink_cause(c) for c in (noproj, nots, other)],
                         ["no project", "no timestamps", "no transcript matched"])

    def test_cells_and_inferred_count(self):
        caches = [cache_for("3.0.0", f"r{i}", float(i)) for i in range(6)]
        for i, c in enumerate(caches):
            c["tier"], c["plan_path"] = ("standard", "plan") if i < 5 else ("simple", "none")
            c["outcome_inferred"] = i < 2
        g = bm.aggregate(caches, "version")["claude-code/3.0.0"]
        self.assertEqual(g["cells"]["standard/plan"]["n"], 5)
        self.assertEqual(g["cells"]["standard/plan"]["mean"], 2.0)
        self.assertEqual(g["cells"]["simple/none"]["n"], 1)
        self.assertEqual(g["n_inferred"], 2)

    def test_aggregate_keyfn_overrides_partition(self):
        caches = [cache_for("3.0.0", "a", 1.0), cache_for("3.1.0", "b", 2.0)]
        agg = bm.aggregate(caches, "version", keyfn=lambda c: "claude-code/3.0.0-3.1.0")
        self.assertEqual(list(agg), ["claude-code/3.0.0-3.1.0"])
        self.assertEqual(agg["claude-code/3.0.0-3.1.0"]["n_runs"], 2)

    def test_version_key_sorts_numerically(self):
        vs = ["2.10.0", "2.9.0", "2.52.17", "2.52.3", "unknown", ""]
        self.assertEqual(sorted(vs, key=bm.version_key), ["", "unknown", "2.9.0", "2.10.0", "2.52.3", "2.52.17"])

    def test_group_keys(self):
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1, host="claude-code"), "version"), "claude-code/2.80.0")
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1, host="codex"), "version"), "codex/2.80.0")
        self.assertEqual(bm.group_key(cache_for("", "a", 1), "version"), "legacy")
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1, host="claude-code"), "week"), "claude-code/2026-W36")

    def test_group_keys_unknown_host_partitioned_separately(self):
        caches = [cache_for("2.80.0", f"a{i}", 1.0, host="claude-code") for i in range(5)]
        caches += [cache_for("2.80.0", "u1", 1.0, host="unknown")]
        agg = bm.aggregate(caches, "version")
        self.assertIn("claude-code/2.80.0", agg)
        self.assertIn("legacy", agg)
        self.assertEqual(agg["claude-code/2.80.0"]["n_runs"], 5)
        self.assertEqual(agg["legacy"]["n_runs"], 1)

    def test_sorted_groups_no_cross_host_bleeding(self):
        """claude-code keys sort before codex keys; unknown appended last."""
        snap = snap_with({
            "codex/2.80.0": group(2, 1, 3),
            "claude-code/2.80.0": group(2, 1, 3),
            "unknown/2.80.0": group(2, 1, 3, sufficient=False, n=1),
        })
        keys = bm._sorted_groups(snap)
        self.assertEqual(keys[0], "claude-code/2.80.0")
        self.assertEqual(keys[1], "codex/2.80.0")
        self.assertEqual(keys[2], "unknown/2.80.0")

    def test_bootstrap_ci_is_deterministic_and_brackets_mean(self):
        lo, hi = bm.bootstrap_ci([1, 2, 3, 4, 10])
        self.assertEqual((lo, hi), bm.bootstrap_ci([1, 2, 3, 4, 10]))
        self.assertLessEqual(lo, 4.0)
        self.assertGreaterEqual(hi, 4.0)
        self.assertEqual(bm.bootstrap_ci([5.0]), (5.0, 5.0))

    def test_aggregate_gate_and_abandon_rate(self):
        caches = [cache_for("2.80.0", f"a{i}", float(i)) for i in range(5)]
        caches += [cache_for("2.80.0", "x", None, eligible=False)]
        caches += [cache_for("2.81.0", "b1", 3.0), cache_for("2.81.0", "b2", None, link="unlinked")]
        agg = bm.aggregate(caches, "version")
        g = agg["claude-code/2.80.0"]
        self.assertEqual((g["n_runs"], g["n_all"], g["sufficient"]), (5, 6, True))
        self.assertEqual(g["metrics"]["interventions"]["n"], 5)
        self.assertEqual(g["metrics"]["interventions"]["mean"], 2.0)
        self.assertEqual(g["metrics"]["interventions"]["median"], 2.0)
        self.assertIsNone(g["metrics"]["orchestrator_output_tokens"])
        self.assertAlmostEqual(g["abandon_rate"], 1 / 6)
        h = agg["claude-code/2.81.0"]
        self.assertFalse(h["sufficient"])
        self.assertEqual(h["metrics"]["interventions"]["n"], 1)

    def test_aggregate_counts_only_registered_gate_ids(self):
        # N1-596: ids with no emit site (improvised by the orchestrator) are not gates.
        improvised = ("review-rerun", "finish-merge", "review-fix-cap", "review-extra-cycle",
                      "review-fix-cap-extra")
        decisions = [{"id": did, "result": True} for did in improvised]
        decisions += [{"id": "review-tier", "result": True},
                      {"id": "escalation:developer:implementation", "result": False}]
        caches = []
        for i in range(5):
            c = cache_for("5.103.3", f"g{i}", 1.0)
            c["run_record"] = make_run(run_id=f"g{i}")
            c["run_record"]["decisions"] = decisions
            caches.append(c)
        rates = bm.aggregate(caches, "version")["claude-code/5.103.3"]["gate_activation_rates"]
        self.assertEqual(rates, {"review-tier": 100.0, "escalation:developer:implementation": 0.0})

    def test_aggregate_partition_stats(self):
        caches = [cache_for("3.0.0", f"r{i}", 1.0, host="claude-code") for i in range(5)]
        caches += [cache_for("3.0.0", "u1", None, eligible=False, host="claude-code")]
        caches += [cache_for("3.0.0", "u2", 2.0, link="unlinked", host="claude-code")]
        agg = bm.aggregate(caches, "version")
        g = agg["claude-code/3.0.0"]
        self.assertEqual(g["n_incomplete"], 1)
        self.assertEqual(g["n_unlinked"], 1)
        # quality_coverage = (6 eligible - 1 unlinked) / 6 eligible
        self.assertAlmostEqual(g["quality_coverage"], 5 / 6, places=2)

    def test_aggregate_codex_review_coverage_includes_all_prs_and_latest_outcome(self):
        completed_without_decision = cache_for("3.1.0", "created", 1.0)
        completed_without_decision["run_record"] = make_run(run_id="created", outcome="pr_created")
        completed_without_decision["final_outcome"] = "pr_created"
        completed_legacy = cache_for("3.1.0", "legacy", 1.0)
        completed_legacy["run_record"] = make_run(run_id="legacy", outcome="pr_created")
        completed_legacy["run_record"]["decisions"] = [
            {"id": "codex-review", "signals": {"outcome": "skipped", "reason": "disabled"}},
        ]
        incomplete_with_pr = cache_for("3.1.0", "incomplete", None, eligible=False)
        incomplete_with_pr["run_record"] = make_run(run_id="incomplete", outcome=None)
        incomplete_with_pr["run_record"]["decisions"] = [
            {"id": "codex-review", "signals": {"pr_url": "https://example.test/pr/2", "outcome": "skipped",
                                                     "reason": "step-not-run"}},
            {"id": "codex-review", "signals": {"pr_url": "https://example.test/pr/2", "outcome": "ran"}},
        ]
        failed_review = cache_for("3.1.0", "failed", None, eligible=False)
        failed_review["run_record"] = make_run(run_id="failed", outcome=None)
        failed_review["run_record"]["decisions"] = [
            {"id": "codex-review", "signals": {"pr_url": "https://example.test/pr/3", "outcome": "failed"}},
        ]
        timed_out_review = cache_for("3.1.0", "timeout", None, eligible=False)
        timed_out_review["run_record"] = make_run(run_id="timeout", outcome=None)
        timed_out_review["run_record"]["decisions"] = [
            {"id": "codex-review", "signals": {"pr_url": "https://example.test/pr/4", "outcome": "timeout"}},
        ]
        unrelated_incomplete = cache_for("3.1.0", "no-pr", None, eligible=False)

        review = bm.aggregate([completed_without_decision, completed_legacy, incomplete_with_pr,
                               failed_review, timed_out_review, unrelated_incomplete], "version")["claude-code/3.1.0"]["codex_review"]

        self.assertEqual(review["pr_runs"], 5)
        self.assertEqual(review["prs"], 5)
        self.assertEqual(review["reviewed_runs"], 1)
        self.assertEqual(review["reviewed_prs"], 1)
        self.assertAlmostEqual(review["coverage_rate"], 1 / 5, places=3)
        self.assertEqual(review["outcomes"], {"ran": 1, "skipped": 1, "failed": 1, "timeout": 1, "missing": 1})

    def test_codex_review_counted_per_run_by_branch_without_outcome_gate(self):
        caches = []
        for i in range(12):
            c = cache_for("5.66.0", f"r{i}", None, eligible=False)
            c["final_outcome"] = "abandoned" if i < 5 else ""
            branch = "VEL-3979" if i < 2 else f"B-{i}"  # same ticket in two runs counts twice
            c["run_record"] = {"decisions": [
                {"id": "codex-review", "signals": {"branch": branch, "outcome": "skipped"}},
                {"id": "codex-review", "signals": {"branch": branch, "outcome": "ran"}}]}
            caches.append(c)
        review = bm.aggregate(caches, "version")["claude-code/5.66.0"]["codex_review"]
        self.assertEqual((review["prs"], review["reviewed_prs"], review["reviewed_runs"]), (12, 12, 12))
        self.assertEqual(review["outcomes"]["skipped"], 0)


class LegacyPartitionTest(unittest.TestCase):
    def test_unknown_host_version_or_timestamp_is_legacy(self):
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1, host="unknown"), "version"), "legacy")
        self.assertEqual(bm.group_key(cache_for("unknown", "a", 1), "version"), "legacy")
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1, started=None), "week"), "legacy")
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1), "week"), "claude-code/2026-W36")

    def test_is_legacy_key_tolerates_old_snapshot_keys(self):
        for k in ("legacy", "unknown/unknown", "unknown/3.28.4", "claude-code/unknown", "unknown"):
            self.assertTrue(bm.is_legacy_key(k), k)
        self.assertFalse(bm.is_legacy_key("claude-code/5.20.0"))

    def test_latest_sufficient_skips_legacy_and_old_unknown_keys(self):
        snap = snap_with({"claude-code/5.20.0": group(2, 1, 3), "unknown/3.28.4": group(1, 0, 2),
                          "unknown/unknown": group(1, 0, 2, n=86), "legacy": group(1, 0, 2)})
        self.assertEqual(bm.latest_sufficient(snap), "claude-code/5.20.0")
        self.assertEqual(bm._sufficient_groups(snap), ["claude-code/5.20.0"])
        keys = bm._sorted_groups(snap)
        self.assertEqual(keys[0], "claude-code/5.20.0")
        self.assertTrue(all(bm.is_legacy_key(k) for k in keys[1:]))

    def test_merged_labels_sort_by_first_version(self):
        snap = snap_with({"claude-code/5.10.0-5.12.0": group(1, 0, 2), "claude-code/5.9.0": group(1, 0, 2)})
        self.assertEqual(bm._sorted_groups(snap), ["claude-code/5.9.0", "claude-code/5.10.0-5.12.0"])


class FinalizeTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()
        self.d.add_run(make_run())
        write_jsonl(self.d.projects / "-mnt-c-Dev-proj" / "s.jsonl", [
            human("2026-09-01T10:03:00Z", "T-1 no, revert that"),
            human("2026-09-01T10:04:00Z", "and also add tests")])
        bm.main(["collect", "--n1-root", str(self.d.n1), "--projects-dir", str(self.d.projects),
                 "--out", str(self.d.out), "--ambiguous-out", str(self.d.tmp / "a.json")])

    def finalize(self, labels):
        lf = self.d.tmp / "labels.json"
        lf.write_text(json.dumps(labels))
        rc = bm.main(["finalize", "--labels", str(lf), "--out", str(self.d.out), "--plugin-version", "2.83.0",
                      "--judge-model", "haiku"])
        self.assertEqual(rc, 0)
        return bm.load_snapshots(self.d.out)[-1]

    def test_finalize_writes_snapshot_and_updates_cache(self):
        snap = self.finalize([{"id": "n1-run-1#0", "label": "correction", "reason": "revert"}])
        self.assertEqual(snap["judge_fallbacks"], 1)
        self.assertEqual(snap["plugin_version"], "2.83.0")
        self.assertEqual(snap["rubric_version"], bm.RUBRIC_VERSION)
        g = snap["groups"]["claude-code/2.80.0"]
        self.assertEqual(g["metrics"]["corrections"]["mean"], 1.0)
        self.assertFalse(g["sufficient"])
        self.assertEqual(snap["unlinked_causes"], {})
        self.assertEqual(list(snap["merged"]), ["claude-code/2.80.0"])
        self.assertEqual(snap["merged"]["claude-code/2.80.0"]["versions"], ["claude-code/2.80.0"])
        cache = bm.load_cache(self.d.out)["n1-run-1"]
        self.assertEqual(cache["metrics"]["interventions"], 1.0)
        self.assertEqual(cache["judge_model"], "haiku")
        self.assertEqual(snap["judge_model"], "haiku")
        self.assertEqual([t["label_source"] for t in cache["turns"]], ["judge", "fallback"])

    def test_finalize_accepts_dict_labels_and_is_idempotent(self):
        self.finalize({"n1-run-1#0": {"label": "correction"}, "n1-run-1#1": {"label": "instruction"}})
        snap = self.finalize([])
        self.assertEqual(snap["judge_fallbacks"], 0)
        self.assertIsNone(snap["judge_model"])  # nothing judged in the second run
        self.assertEqual(bm.load_cache(self.d.out)["n1-run-1"]["judge_model"], "haiku")
        self.assertEqual(len(bm.load_snapshots(self.d.out)), 2)
        self.assertIn("judge none (no turns judged)", bm.render_report(snap, None, None, "", {}))


class BaselineTest(unittest.TestCase):
    def setUp(self):
        self.d = TempDirs()
        bm.write_snapshot(self.d.out, snap_with({"claude-code/2.80.0": group(2, 1, 3), "legacy": group(1, 0, 2)}))

    def run_quiet(self, *argv, out=None):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            rc = bm.main([*argv, "--out", str(out or self.d.out)])
        return rc, err.getvalue()

    def test_set_and_show(self):
        self.assertEqual(self.run_quiet("baseline", "set", "claude-code/2.80.0")[0], 0)
        self.assertEqual(bm.load_baseline(self.d.out)["version"], "claude-code/2.80.0")
        self.assertEqual(self.run_quiet("baseline", "set", "2.80.0")[0], 0)  # bare version resolves
        self.assertEqual(bm.load_baseline(self.d.out)["version"], "claude-code/2.80.0")
        self.assertEqual(self.run_quiet("baseline", "show")[0], 0)
        self.assertEqual(self.run_quiet("baseline", "set")[0], 2)

    def test_set_rejects_value_absent_from_latest_snapshot(self):
        rc, err = self.run_quiet("baseline", "set", "2026-W29")
        self.assertEqual(rc, 2)
        self.assertIn("2026-W29", err)
        self.assertIn("claude-code/2.80.0", err)
        self.assertIsNone(bm.load_baseline(self.d.out))
        self.assertEqual(self.run_quiet("baseline", "set", "legacy")[0], 2)

    def test_set_without_snapshot_fails(self):
        empty = TempDirs()
        self.assertEqual(self.run_quiet("baseline", "set", "claude-code/2.80.0", out=empty.out)[0], 2)
        self.assertIsNone(bm.load_baseline(empty.out))


def stat(mean, lo, hi, n=5):
    return {"n": n, "mean": mean, "median": mean, "ci": [lo, hi]}


def snap_with(groups, sid="20260905T000000Z"):
    return {"snapshot_id": sid, "created_at": "2026-09-05T00:00:00Z", "by": "version", "plugin_version": "2.83.0",
            "rubric_version": 1, "judge_model": "m", "judge_fallbacks": 0, "malformed_lines": 0,
            "groups": groups, "run_ids": [], "unlinked": []}


def group(mean_interventions, lo, hi, sufficient=True, n=5):
    metrics = {m.name: stat(mean_interventions if m.name == "interventions" else 1.0, lo, hi, n) for m in bm.METRICS}
    return {"n_runs": n, "n_all": n, "n_incomplete": 0, "n_unlinked": 0, "quality_coverage": 1.0,
            "sufficient": sufficient, "metrics": metrics, "abandon_rate": 0.0, "run_ids": []}


class MergeVersionsTest(unittest.TestCase):
    def test_adjacent_versions_merge_until_min_sample_and_tail_merges_back(self):
        caches = []
        for v, n in (("5.58.1", 2), ("5.59.0", 1), ("5.60.0", 3), ("5.61.0", 6), ("5.62.0", 2)):
            caches += [cache_for(v, f"{v}-{i}", 1.0) for i in range(n)]
        caches.append(cache_for("5.59.0", "x", None, eligible=False))  # ineligible runs do not count
        caches.append(cache_for("", "leg", 1.0))
        m = bm.merge_versions(caches)
        self.assertEqual(m["claude-code/5.58.1"], "claude-code/5.58.1-5.60.0")
        self.assertEqual(m["claude-code/5.59.0"], "claude-code/5.58.1-5.60.0")
        self.assertEqual(m["claude-code/5.60.0"], "claude-code/5.58.1-5.60.0")
        self.assertEqual(m["claude-code/5.61.0"], "claude-code/5.61.0-5.62.0")
        self.assertEqual(m["claude-code/5.62.0"], "claude-code/5.61.0-5.62.0")
        self.assertNotIn("legacy", m)

    def test_single_undersized_bucket_keeps_its_version_label(self):
        m = bm.merge_versions([cache_for("5.0.0", "a", 1.0), cache_for("5.0.0", "b", 1.0)])
        self.assertEqual(m, {"claude-code/5.0.0": "claude-code/5.0.0"})

    def test_headline_groups(self):
        snap = snap_with({"claude-code/2.80.0": group(2, 1, 3)})
        self.assertEqual(bm.headline_groups(snap), {})
        snap["merged"] = {"claude-code/2.80.0": group(2, 1, 3)}
        self.assertIs(bm.headline_groups(snap), snap["merged"])
        week = snap_with({"claude-code/2026-W36": group(2, 1, 3), "legacy": group(1, 0, 2)})
        week["by"] = "week"
        self.assertEqual(list(bm.headline_groups(week)), ["claude-code/2026-W36"])


class ReportTest(unittest.TestCase):
    def test_stat_has_nearest_rank_p90(self):
        s = bm._stat(list(range(1, 11)))
        self.assertEqual((s["n"], s["median"], s["p90"]), (10, 5.5, 9))
        self.assertEqual(bm._stat([7])["p90"], 7)

    def test_duration_metrics_are_robust_and_never_flag_significance(self):
        self.assertEqual({m.name for m in bm.METRICS if m.robust}, {"duration_min", "work_min", "stall_min"})
        old, new = group(5, 4, 6), group(2, 1, 3)
        for name in ("duration_min", "work_min", "stall_min"):
            old["metrics"][name] = {"n": 5, "mean": 10.0, "median": 9.0, "p90": 20.0, "ci": [8.0, 12.0]}
            new["metrics"][name] = {"n": 5, "mean": 100.0, "median": 90.0, "p90": 200.0, "ci": [95.0, 105.0]}
        snap = snap_with({"claude-code/2.70.0": old, "claude-code/2.80.0": new})
        out = bm.render_report(snap, None, "claude-code/2.70.0", "pinned", {})
        main = next(ln for ln in out.splitlines() if ln.startswith("| claude-code/2.80.0 | 5/5"))
        self.assertEqual(main.count("median 90 / p90 200 (n=5) |"), 3)  # no delta appended in the main table
        rows = [ln for ln in out.splitlines() if ln.startswith(("| duration_min |", "| work_min |", "| stall_min |"))]
        self.assertEqual(len(rows), 3)
        for ln in rows:
            self.assertIn("median 9 / p90 20 (n=5)", ln)
            self.assertNotIn("significant", ln)
        self.assertEqual(bm._fmt_stat({"n": 3, "mean": 1.0, "median": 1.0, "ci": [1, 1]}, robust=True),
                         "median 1 / p90 n/a (n=3)")  # old snapshot without p90

    def test_delta_and_significance(self):
        d = bm.delta(stat(2.0, 1.5, 2.5), stat(4.0, 3.0, 5.0))
        self.assertEqual((d["abs"], d["pct"], d["significant"]), (-2.0, -50.0, True))
        d = bm.delta(stat(3.0, 2.0, 4.5), stat(4.0, 3.0, 5.0))
        self.assertFalse(d["significant"])
        self.assertIsNone(bm.delta(stat(3.0, 2.0, 4.0), stat(0.0, 0.0, 0.0))["pct"])

    def test_baseline_selection(self):
        snap = snap_with({"claude-code/2.70.0": group(5, 4, 6), "claude-code/2.80.0": group(2, 1, 3),
                          "claude-code/2.81.0": group(3, 2, 4, sufficient=False, n=2)})
        snap["merged"] = {
            "claude-code/2.70.0": {**group(5, 4, 6), "versions": ["claude-code/2.70.0"]},
            "claude-code/2.80.0-2.81.0": {**group(2, 1, 3, n=7),
                                          "versions": ["claude-code/2.80.0", "claude-code/2.81.0"]}}
        self.assertEqual(bm.pick_baseline_group(snap, {"version": "claude-code/2.70.0"}),
                         ("claude-code/2.70.0", "pinned"))
        self.assertEqual(bm.pick_baseline_group(snap, {"version": "claude-code/2.81.0"})[0],
                         "claude-code/2.80.0-2.81.0")
        key, note = bm.pick_baseline_group(snap, None)
        self.assertEqual(key, "claude-code/2.70.0")
        self.assertIn("oldest", note)
        key, note = bm.pick_baseline_group(snap, {"version": "2026-W29"})
        self.assertEqual(key, "claude-code/2.70.0")
        self.assertIn("not in this snapshot", note)
        self.assertEqual(bm.latest_sufficient(snap, bm.headline_groups(snap)), "claude-code/2.80.0-2.81.0")
        self.assertEqual(bm.latest_sufficient(snap), "claude-code/2.80.0")

    def test_baseline_never_pins_legacy_partition(self):
        snap = snap_with({"claude-code/2.70.0": group(5, 4, 6), "legacy": group(1, 0, 2)})  # pre-merge snapshot
        key, note = bm.pick_baseline_group(snap, {"version": "legacy"})
        self.assertEqual(key, "claude-code/2.70.0")
        self.assertIn("not in this snapshot", note)

    def test_baseline_fallback_stays_on_latest_host(self):
        snap = snap_with({})
        snap["merged"] = {"aaa/1.0.0": group(1, 0, 2), "claude-code/2.0.0": group(2, 1, 3),
                          "claude-code/2.1.0": group(3, 2, 4)}
        self.assertEqual(bm.pick_baseline_group(snap, None)[0], "claude-code/2.0.0")

    def test_render_contains_sections(self):
        snap = snap_with({"claude-code/2.70.0": group(5, 4, 6), "claude-code/2.80.0": group(2, 1, 3), "claude-code/2.81.0": group(3, 2, 4, sufficient=False, n=2)})
        snap["unlinked"] = [{"run_id": "r9", "project": "p", "ticket_id": "T-9", "reason": "no transcript matched"}]
        prev = snap_with({"claude-code/2.80.0": group(2.5, 1, 3)}, sid="20260901T000000Z")
        caches = {"r1": {"run_id": "r1", "n1_version": "2.80.0", "eligible": True, "project": "p", "ticket_id": "T-1",
                         "transcript_path": "/t/r1.jsonl", "metrics": {"corrections": 3.0},
                         "turns": [{"label": "correction", "reason": "wrong file"}, {"label": "correction", "reason": "wrong file"},
                                   {"label": "correction", "reason": "bad plan"}]}}
        text = bm.render_report(snap, prev, "claude-code/2.70.0", "pinned", caches)
        self.assertIn("claude-code/2.80.0 vs baseline claude-code/2.70.0", text)
        self.assertIn("interventions", text)
        # partition table uses compound keys
        self.assertIn("Per-partition metrics", text)
        self.assertIn("quality_cov", text)
        self.assertIn("| claude-code/2.81.0 |", text)
        self.assertIn("(insufficient, n<5)", text)
        self.assertIn("Insufficient sample", text)
        self.assertIn("claude-code/2.81.0 (2 runs)", text)
        self.assertIn("Unlinked runs", text)
        self.assertIn("r9", text)
        self.assertIn("Worst runs", text)
        self.assertIn("wrong file (2)", text)
        self.assertIn("Previous snapshot: 20260901T000000Z", text)
        self.assertIn("rubric v1", text)
        self.assertIn("Tool efficiency", text)
        self.assertIn("bash_calls_per_run", text)
        self.assertIn("api_calls_per_run", text)

    def test_render_includes_codex_review_coverage(self):
        snapshot = snap_with({"claude-code/2.80.0": group(2, 1, 3)})
        snapshot["groups"]["claude-code/2.80.0"]["codex_review"] = {
            "pr_runs": 3, "prs": 3, "reviewed_runs": 1, "reviewed_prs": 1,
            "coverage_rate": 1 / 3,
            "outcomes": {"ran": 1, "skipped": 1, "failed": 0, "timeout": 0, "missing": 1},
        }

        text = bm.render_report(snapshot, None, None, "", {})

        self.assertIn("Codex review coverage", text)
        self.assertIn("1/3", text)
        self.assertIn("33%", text)
        self.assertIn("ran 1", text)
        self.assertIn("missing 1", text)

    def _gate_snap(self, headline_rates, old_rates, run_ids=("r1", "r2")):
        snap = snap_with({"claude-code/2.79.0": {**group(2, 1, 3, n=1, sufficient=False),
                                                 "gate_activation_rates": old_rates},
                          "claude-code/2.80.0": group(2, 1, 3)})
        snap["merged"] = {"claude-code/2.79.0-2.80.0": {
            **group(2, 1, 3), "versions": ["claude-code/2.79.0", "claude-code/2.80.0"],
            "run_ids": list(run_ids), "gate_activation_rates": headline_rates}}
        return snap

    @staticmethod
    def _gate_caches():
        rec = lambda res: {"run_record": {"decisions": [{"id": "review-tier", "result": res}]}}
        return {"r1": rec(True), "r2": rec(True)}

    def test_gate_table_uses_headline_partition_not_oldest_group(self):
        snap = self._gate_snap({"review-tier": 100.0}, {"review-tier": 0.0})
        text = bm.render_report(snap, None, None, "", self._gate_caches())
        self.assertIn("| review-tier | 100.0% (2/2) |", text)
        self.assertNotIn("0.0%", text.replace("100.0%", ""))

    def test_gate_table_annotates_gate_without_headline_events(self):
        snap = self._gate_snap({"review-tier": 100.0}, {"old-gate": 0.0})
        text = bm.render_report(snap, None, None, "", self._gate_caches())
        self.assertIn("| old-gate | n/a (no events in headline) |", text)

    def test_gate_table_counts_unavailable_without_caches(self):
        snap = self._gate_snap({"review-tier": 100.0}, {})
        text = bm.render_report(snap, None, None, "", {})
        self.assertIn("| review-tier | 100.0% (counts unavailable) |", text)

    def test_gate_table_counts_unavailable_with_partial_caches(self):
        snap = self._gate_snap({"review-tier": 0.0}, {})
        caches = {"r1": {"run_record": {"decisions": [{"id": "review-tier", "result": False}]}}}
        text = bm.render_report(snap, None, None, "", caches)
        self.assertIn("| review-tier | 0.0% (counts unavailable) |", text)

    def test_gate_counts_skip_improvised_ids(self):
        # N1-596: _gate_counts must apply the same registry filter as aggregate().
        decisions = [{"id": "review-tier", "result": True}, {"id": "review-rerun", "result": True},
                     {"id": "finish-merge", "result": True}, {"id": "", "result": True}]
        caches = {rid: {"run_record": {"decisions": decisions}} for rid in ("r1", "r2")}
        self.assertEqual(bm._gate_counts(["r1", "r2"], caches), {"review-tier": (2, 2)})

    def test_gate_table_omitted_without_sufficient_partition(self):
        snap = self._gate_snap({"review-tier": 100.0}, {"review-tier": 0.0})
        snap["merged"]["claude-code/2.79.0-2.80.0"]["sufficient"] = False
        snap["groups"]["claude-code/2.80.0"]["sufficient"] = False
        text = bm.render_report(snap, None, None, "", self._gate_caches())
        self.assertIn("No sufficient headline partition; gate rates not reported.", text)
        self.assertNotIn("| review-tier |", text)

    def test_render_cross_host_no_delta(self):
        # claude-code and codex partitions must not produce cross-host deltas.
        # Without per-host isolation, codex/2.80.0 would inherit claude-code/2.80.0 as
        # its prev_key and emit a spurious delta cell.
        snap = snap_with({"claude-code/2.80.0": group(2, 1, 3), "codex/2.80.0": group(4, 3, 5)})
        text = bm.render_report(snap, None, "claude-code/2.80.0", "pinned", {})
        self.assertIn("same host", text)
        # table row for codex is the first codex partition — no prior same-host entry to delta against
        table_rows = [l for l in text.splitlines() if l.startswith("| codex/2.80.0")]
        self.assertTrue(table_rows, "codex/2.80.0 table row missing from rendered output")
        # delta markers ("better"/"worse") appear only when a prior same-host partition exists
        self.assertNotIn("better", table_rows[0])
        self.assertNotIn("worse", table_rows[0])

    def test_cmd_report_writes_summary_and_full(self):
        d = TempDirs()
        snap = snap_with({"claude-code/2.80.0": group(2, 1, 3)})
        snap["merged"] = {"claude-code/2.80.0": {**group(2, 1, 3), "versions": ["claude-code/2.80.0"]}}
        bm.write_snapshot(d.out, snap)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(bm.main(["report", "--out", str(d.out)]), 0)
        full = d.out / "reports" / "20260905T000000Z.full.md"
        self.assertTrue(full.is_file())
        self.assertIn("Per-partition metrics", full.read_text())
        summary = (d.out / "reports" / "20260905T000000Z.md").read_text()
        self.assertEqual(buf.getvalue(), summary)
        self.assertIn(f"full report: {full}", summary)
        self.assertNotIn("Per-partition metrics", summary)

    def test_summary_is_short_on_large_snapshot(self):
        groups = {f"claude-code/5.{i}.0": group(2, 1, 3, sufficient=i % 2 == 0, n=5 if i % 2 == 0 else 2)
                  for i in range(60)}
        groups["legacy"] = group(1, 0, 2, n=86)
        snap = snap_with(groups)
        cells = {f"{t}/{p}": stat(1.0, 0.5, 1.5, n=6)
                 for t in ("simple", "standard", "complex", "unknown") for p in ("plan", "direct", "none")}
        cells["simple/plan"] = stat(1.0, 0.5, 1.5, n=2)
        snap["merged"] = {f"claude-code/5.{i}.0-5.{i + 1}.0": {**group(2 + i / 100, 1, 3), "cells": cells,
                                                              "n_inferred": 1, "versions": []}
                          for i in range(0, 60, 2)}
        snap["unlinked"] = [{"run_id": f"u{i}", "project": "", "ticket_id": "T", "reason": "no project"}
                            for i in range(81)]
        snap["unlinked_causes"] = {"no project": 40, "no timestamps": 15, "no transcript matched": 26}
        text = bm.render_summary(snap, "claude-code/5.0.0-5.1.0", "pinned", "/x/full.md")
        lines = text.splitlines()
        self.assertLess(len(lines), 80)
        self.assertIn("claude-code/5.58.0-5.59.0 vs baseline claude-code/5.0.0-5.1.0", lines[2])
        self.assertNotIn("legacy", lines[2])
        self.assertIn("no project 40", text)
        self.assertIn("legacy partition (unknown host or version): 86", text)
        self.assertIn("insufficient (n<5 on a side): 1", text)
        self.assertEqual(lines[-1], "full report: /x/full.md")

    def test_summary_tolerates_old_snapshot(self):
        snap = snap_with({"unknown/unknown": group(1, 0, 2, n=86), "claude-code/5.20.0": group(2, 1, 3)})
        text = bm.render_summary(snap, None, "no baseline pinned", "/x/full.md")
        self.assertIn("re-run finalize", text)
        self.assertIn("legacy partition (unknown host or version): 86", text)

    def test_cmd_report_without_snapshots(self):
        d = TempDirs()
        self.assertEqual(bm.main(["report", "--out", str(d.out)]), 0)


class SkillRootResolutionTest(unittest.TestCase):
    """N1-482 AC5: with CLAUDE_PLUGIN_ROOT unset both skills fall back to ~/.n1/host.json
    instead of accepting an empty root because /lib exists on the machine."""

    def test_root_resolves_from_host_json_when_env_unset(self):
        home = Path(tempfile.mkdtemp())
        (home / ".n1").mkdir()
        (home / ".n1" / "host.json").write_text(json.dumps({"pluginRoot": str(REPO)}), encoding="utf-8")
        env = {"HOME": str(home), "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        for name in ("n1-benchmark", "n1-telemetry-analyzer"):
            skill = (REPO / ".claude" / "skills" / name / "SKILL.md").read_text(encoding="utf-8")
            line = next(l for l in skill.splitlines() if l.startswith("N1_ROOT="))
            res = subprocess.run(["bash", "-c", line + '\nprintf %s "$N1_ROOT"'], env=env,
                                 capture_output=True, text=True)
            self.assertEqual(res.stdout, str(REPO), f"{name}: {res.stderr}")


class SkillInvocationTest(unittest.TestCase):
    """N1-29: the n1-benchmark skill passed --host after N1-63 removed it, so
    argparse exited before collect ran and no snapshot was written after Sep 5."""

    def test_skill_collect_invocation_parses(self):
        skill = (REPO / ".claude" / "skills" / "n1-benchmark" / "SKILL.md").read_text(encoding="utf-8")
        line = next(l for l in skill.splitlines() if '"$SCRIPT" collect' in l)
        rest = line.split('"$SCRIPT"', 1)[1].replace("DATE", "2026-01-01").replace("[", "").replace("]", "")
        try:
            args = bm.build_parser().parse_args(shlex.split(rest))
        except SystemExit as e:
            self.fail(f"SKILL.md collect invocation rejected by argparse (exit {e.code}): {line}")
        self.assertEqual(args.cmd, "collect")

    def test_skill_finalize_passes_judge_model(self):
        skill = (REPO / ".claude" / "skills" / "n1-benchmark" / "SKILL.md").read_text(encoding="utf-8")
        line = next(l for l in skill.splitlines() if '"$SCRIPT" finalize' in l)
        rest = line.split('"$SCRIPT"', 1)[1].replace("[", "").replace("]", "")
        args = bm.build_parser().parse_args(shlex.split(rest))
        self.assertEqual(args.judge_model, "haiku")


if __name__ == "__main__":
    unittest.main()

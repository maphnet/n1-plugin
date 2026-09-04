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


_UNSET = object()


def make_run(run_id="n1-run-1", version="2.80.0", project="proj", ticket="T-1",
             started="2026-09-01T10:00:00Z", completed=_UNSET,
             outcome="pr_created", steps=_UNSET, outcomes=_UNSET, summary=_UNSET, orchestrator=_UNSET):
    return {
        "schema_version": 2, "run_id": run_id, "session_id": None, "n1_version": version,
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
        self.assertEqual(cache["per_step"]["brainstorm"]["corrections"], 1)
        self.assertEqual(cache["per_step"]["implementation"]["interventions"], 1)

    def test_telemetry_metrics(self):
        cache = {"run_record": make_run(), "turns": []}
        bm.compute_run_metrics(cache)
        m = cache["metrics"]
        self.assertEqual(m["fix_cycles"], 1.0)
        self.assertEqual(m["review_pass_first_try"], 1.0)
        self.assertEqual(m["duration_min"], 60.0)
        self.assertEqual(m["orchestrator_output_tokens"], 5000.0)
        self.assertEqual(m["compactions"], 2.0)

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

    def test_metric_registry_shape(self):
        names = [m.name for m in bm.METRICS]
        self.assertEqual(names, ["interventions", "answers", "corrections", "fix_cycles",
                                 "review_pass_first_try", "duration_min", "orchestrator_output_tokens", "compactions"])
        self.assertTrue(all(m.direction in ("lower", "higher") for m in bm.METRICS))


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


def cache_for(version, run_id, interventions, eligible=True, started="2026-09-01T10:00:00Z", link="heuristic"):
    return {"run_id": run_id, "n1_version": version, "eligible": eligible, "started_at": started,
            "link_method": link if eligible else "skipped", "project": "p", "ticket_id": "T",
            "metrics": {"interventions": interventions, "answers": interventions, "corrections": 0.0,
                        "fix_cycles": 1.0, "review_pass_first_try": 1.0, "duration_min": 10.0,
                        "orchestrator_output_tokens": None, "compactions": 0.0} if eligible else {},
            "turns": []}


class AggregateTest(unittest.TestCase):
    def test_version_key_sorts_numerically(self):
        vs = ["2.10.0", "2.9.0", "2.52.17", "2.52.3", "unknown", ""]
        self.assertEqual(sorted(vs, key=bm.version_key), ["", "unknown", "2.9.0", "2.10.0", "2.52.3", "2.52.17"])

    def test_group_keys(self):
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1), "version"), "2.80.0")
        self.assertEqual(bm.group_key(cache_for("", "a", 1), "version"), "unknown")
        self.assertEqual(bm.group_key(cache_for("2.80.0", "a", 1), "week"), "2026-W36")

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
        g = agg["2.80.0"]
        self.assertEqual((g["n_runs"], g["n_all"], g["sufficient"]), (5, 6, True))
        self.assertEqual(g["metrics"]["interventions"]["n"], 5)
        self.assertEqual(g["metrics"]["interventions"]["mean"], 2.0)
        self.assertEqual(g["metrics"]["interventions"]["median"], 2.0)
        self.assertIsNone(g["metrics"]["orchestrator_output_tokens"])
        self.assertAlmostEqual(g["abandon_rate"], 1 / 6)
        h = agg["2.81.0"]
        self.assertFalse(h["sufficient"])
        self.assertEqual(h["metrics"]["interventions"]["n"], 1)


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
        rc = bm.main(["finalize", "--labels", str(lf), "--out", str(self.d.out), "--plugin-version", "2.83.0"])
        self.assertEqual(rc, 0)
        return bm.load_snapshots(self.d.out)[-1]

    def test_finalize_writes_snapshot_and_updates_cache(self):
        snap = self.finalize([{"id": "n1-run-1#0", "label": "correction", "reason": "revert"}])
        self.assertEqual(snap["judge_fallbacks"], 1)
        self.assertEqual(snap["plugin_version"], "2.83.0")
        self.assertEqual(snap["rubric_version"], bm.RUBRIC_VERSION)
        g = snap["groups"]["2.80.0"]
        self.assertEqual(g["metrics"]["corrections"]["mean"], 1.0)
        self.assertFalse(g["sufficient"])
        cache = bm.load_cache(self.d.out)["n1-run-1"]
        self.assertEqual(cache["metrics"]["interventions"], 1.0)
        self.assertEqual(cache["judge_model"], bm.DEFAULT_JUDGE_MODEL)
        self.assertEqual([t["label_source"] for t in cache["turns"]], ["judge", "fallback"])

    def test_finalize_accepts_dict_labels_and_is_idempotent(self):
        self.finalize({"n1-run-1#0": {"label": "correction"}, "n1-run-1#1": {"label": "instruction"}})
        snap = self.finalize([])
        self.assertEqual(snap["judge_fallbacks"], 0)
        self.assertEqual(len(bm.load_snapshots(self.d.out)), 2)


class BaselineTest(unittest.TestCase):
    def test_set_and_show(self):
        d = TempDirs()
        self.assertEqual(bm.main(["baseline", "set", "2.80.0", "--out", str(d.out)]), 0)
        self.assertEqual(bm.load_baseline(d.out)["version"], "2.80.0")
        self.assertEqual(bm.main(["baseline", "show", "--out", str(d.out)]), 0)
        self.assertEqual(bm.main(["baseline", "set", "--out", str(d.out)]), 2)


def stat(mean, lo, hi, n=5):
    return {"n": n, "mean": mean, "median": mean, "ci": [lo, hi]}


def snap_with(groups, sid="20260905T000000Z"):
    return {"snapshot_id": sid, "created_at": "2026-09-05T00:00:00Z", "by": "version", "plugin_version": "2.83.0",
            "rubric_version": 1, "judge_model": "m", "judge_fallbacks": 0, "malformed_lines": 0,
            "groups": groups, "run_ids": [], "unlinked": []}


def group(mean_interventions, lo, hi, sufficient=True, n=5):
    metrics = {m.name: stat(mean_interventions if m.name == "interventions" else 1.0, lo, hi, n) for m in bm.METRICS}
    return {"n_runs": n, "n_all": n, "sufficient": sufficient, "metrics": metrics, "abandon_rate": 0.0, "run_ids": []}


class ReportTest(unittest.TestCase):
    def test_delta_and_significance(self):
        d = bm.delta(stat(2.0, 1.5, 2.5), stat(4.0, 3.0, 5.0))
        self.assertEqual((d["abs"], d["pct"], d["significant"]), (-2.0, -50.0, True))
        d = bm.delta(stat(3.0, 2.0, 4.5), stat(4.0, 3.0, 5.0))
        self.assertFalse(d["significant"])
        self.assertIsNone(bm.delta(stat(3.0, 2.0, 4.0), stat(0.0, 0.0, 0.0))["pct"])

    def test_baseline_selection(self):
        snap = snap_with({"2.70.0": group(5, 4, 6), "2.80.0": group(2, 1, 3), "2.81.0": group(3, 2, 4, sufficient=False, n=2)})
        self.assertEqual(bm.pick_baseline_group(snap, {"version": "2.70.0"})[0], "2.70.0")
        key, note = bm.pick_baseline_group(snap, None)
        self.assertEqual(key, "2.70.0")
        self.assertIn("oldest", note)
        key, note = bm.pick_baseline_group(snap, {"version": "9.9.9"})
        self.assertEqual(key, "2.70.0")
        self.assertIn("not found", note)
        self.assertEqual(bm.latest_sufficient(snap), "2.80.0")

    def test_render_contains_sections(self):
        snap = snap_with({"2.70.0": group(5, 4, 6), "2.80.0": group(2, 1, 3), "2.81.0": group(3, 2, 4, sufficient=False, n=2)})
        snap["unlinked"] = [{"run_id": "r9", "project": "p", "ticket_id": "T-9", "reason": "no transcript matched"}]
        prev = snap_with({"2.80.0": group(2.5, 1, 3)}, sid="20260901T000000Z")
        caches = {"r1": {"run_id": "r1", "n1_version": "2.80.0", "eligible": True, "project": "p", "ticket_id": "T-1",
                         "transcript_path": "/t/r1.jsonl", "metrics": {"corrections": 3.0},
                         "turns": [{"label": "correction", "reason": "wrong file"}, {"label": "correction", "reason": "wrong file"},
                                   {"label": "correction", "reason": "bad plan"}]}}
        text = bm.render_report(snap, prev, "2.70.0", "pinned", caches)
        self.assertIn("2.80.0 vs baseline 2.70.0", text)
        self.assertIn("interventions", text)
        self.assertIn("| 2.81.0 |", text)
        self.assertIn("Insufficient sample", text)
        self.assertIn("2.81.0 (2 runs)", text)
        self.assertIn("Unlinked runs", text)
        self.assertIn("r9", text)
        self.assertIn("Worst runs", text)
        self.assertIn("wrong file (2)", text)
        self.assertIn("Previous snapshot: 20260901T000000Z", text)
        self.assertIn("rubric v1", text)

    def test_cmd_report_writes_file(self):
        d = TempDirs()
        bm.write_snapshot(d.out, snap_with({"2.80.0": group(2, 1, 3)}))
        self.assertEqual(bm.main(["report", "--out", str(d.out)]), 0)
        self.assertTrue((d.out / "reports" / "20260905T000000Z.md").is_file())

    def test_cmd_report_without_snapshots(self):
        d = TempDirs()
        self.assertEqual(bm.main(["report", "--out", str(d.out)]), 0)


if __name__ == "__main__":
    unittest.main()

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
        write_jsonl(self.run_path(run), [run, *extra_lines])
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


if __name__ == "__main__":
    unittest.main()

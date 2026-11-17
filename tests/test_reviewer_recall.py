import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("reviewer_recall", REPO / "scripts" / "reviewer_recall.py")
rr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rr)


class WilsonTest(unittest.TestCase):
    def test_known_values(self):
        # Bug caught: a normal-approximation or mistyped formula gives a zero-width
        # interval at k=0/k=n or wrong bounds; the report's headline intervals would be wrong.
        for (k, n), (lo, hi) in {(0, 10): (0.0, 0.2775), (10, 10): (0.7225, 1.0),
                                 (5, 10): (0.2366, 0.7634)}.items():
            got = rr.wilson(k, n)
            self.assertAlmostEqual(got[0], lo, delta=1e-3)
            self.assertAlmostEqual(got[1], hi, delta=1e-3)
        self.assertEqual(rr.wilson(0, 0), (None, None))


class SplitTest(unittest.TestCase):
    def test_seeded_disjoint_split(self):
        # Bug caught: an unseeded or order-dependent split moves tickets between tune and
        # test across runs, so the "fixed test set" re-run after a persona change is not fixed.
        tickets = [f"N1-{i}" for i in range(10)]
        tune, test = rr.split_tickets(tickets, 629, 0.5)
        self.assertEqual((tune, test), rr.split_tickets(list(reversed(tickets)), 629, 0.5))
        self.assertEqual((len(tune), len(test)), (5, 5))
        self.assertFalse(tune & test)
        self.assertTrue(any(rr.split_tickets(tickets, s, 0.5)[0] != tune for s in range(1, 10)))


class MatchControlsTest(unittest.TestCase):
    def test_nearest_size_without_reuse(self):
        # Bug caught: one control reused for two missed tickets, or a far-off size picked,
        # making the over-flag comparison meaningless; a shortfall silently ignored.
        pairs, unmatched = rr.match_controls({"A": 100, "B": 50}, {"X": 98, "Y": 55, "Z": 500})
        self.assertEqual((pairs, unmatched), ({"A": "X", "B": "Y"}, []))
        pairs, _ = rr.match_controls({"A": 100, "B": 99}, {"X": 100, "Z": 10})
        self.assertEqual(pairs, {"A": "X", "B": "Z"})
        pairs, unmatched = rr.match_controls({"A": 100, "B": 50}, {"X": 98})
        self.assertEqual((pairs, unmatched), ({"A": "X"}, ["B"]))


class ParserTest(unittest.TestCase):
    def test_reply_and_triage_parsers(self):
        # Bugs caught: findings miscounted in the persona's Output Format (over-flag rate wrong);
        # a malformed judge reply accepted as a verdict; answer keys carrying the fix text,
        # the wrong file, or numbering that drifts from findings.tsv ids.
        review = ("## Code Review Findings\n\n### High\n- **[CR-1]** A\n  - File: a.sh:1\n"
                  "### Medium\n- **[CR-2]** B (correctness)\n### Test Quality\n- **[TQ-1]** C\n"
                  "### Cross-Repo Advisories\n- **[XREPO-1]** D\n\n### Verdict: FAIL\n")
        self.assertEqual(rr.count_findings(review), (3, False))
        self.assertEqual(rr.count_findings("## Code Review Findings\n### High\n(none)\n### Verdict: PASS\n"), (0, False))
        self.assertEqual(rr.count_findings("I could not review this."), (0, True))

        self.assertEqual(rr.parse_judge('x {"verdict":"caught","finding_ref":"CR-2","reason":"r"} y')["finding_ref"], "CR-2")
        self.assertIsNone(rr.parse_judge("not json"))
        self.assertIsNone(rr.parse_judge('{"verdict":"maybe"}'))

        triage = ("## Codex\n\n### Auto-Fixed\n"
                  "- [P1] Children merged after the final PR can be incorrectly marked landed (lib/queue.sh:302): "
                  "`n1_queue_final_landed` now reads `mergedAt`.\n"
                  "- Resuming can overlap detached review processes: `n1_review_codex_start` now reuses a run "
                  "(lib/review-step.sh, tests/test_review_codex_step7.sh).\n\n"
                  "### Dismissed by validator\n- Something: INVALID.\n")
        got = rr.parse_auto_fixed(triage)
        self.assertEqual([(f["n"], f["severity"], f["file"]) for f in got],
                         [(1, "P1", "lib/queue.sh:302"), (2, None, "lib/review-step.sh")])
        self.assertEqual(got[0]["answer_key"], "Children merged after the final PR can be incorrectly marked landed (lib/queue.sh:302)")
        self.assertEqual(got[1]["answer_key"], "Resuming can overlap detached review processes (lib/review-step.sh)")
        self.assertEqual(rr.parse_auto_fixed("### Summary\nnothing\n"), [])


GIT = ["git", "-c", "user.name=t", "-c", "user.email=t@localhost", "-c", "commit.gpgsign=false",
       "-c", "init.defaultBranch=main"]
TRIAGE = ("## Codex\n\n### Auto-Fixed\n- [P1] Echo drops the last line (a.sh:2): fixed.\n"
          "- **Second bug** (`a.sh`): fixed.\n\n### Dismissed by validator\n- none\n")


def sh(cwd, *args):
    return subprocess.run(GIT + [str(a) for a in args], cwd=cwd, check=True,
                          capture_output=True, text=True).stdout.strip()


def make_repo(root):
    """Base commit, then a case commit (+2 lines) and a control commit (+3 lines vs base)."""
    repo = root / "repo"
    (repo / "agents").mkdir(parents=True)
    sh(repo, "init", "-q")
    (repo / "CLAUDE.md").write_text("# rules\n")
    (repo / "agents" / "code-reviewer.md").write_text(
        "---\nname: code-reviewer\ntools: Read, Grep, Glob, Write\neffort: high\n---\nReview the diff.\n")
    (repo / "a.sh").write_text("echo a\n")
    sh(repo, "add", "-A")
    sh(repo, "commit", "-qm", "base")
    base = sh(repo, "rev-parse", "HEAD")
    (repo / "a.sh").write_text("echo a\necho b\necho c\n")
    sh(repo, "commit", "-qam", "case change")
    head_a = sh(repo, "rev-parse", "HEAD")
    (repo / "a.sh").write_text("echo a\necho b\necho c\necho d\n")
    sh(repo, "commit", "-qam", "control change")
    return repo, base, head_a, sh(repo, "rev-parse", "HEAD")


def make_memory(root, base):
    mem = root / "memory"
    for t in ("N1-1", "N1-2"):
        (mem / t).mkdir(parents=True)
        (mem / t / "branch-point").write_text(base + "\n")
    (mem / "N1-1" / "codex-triage.posted.md").write_text(TRIAGE)
    (mem / "N1-1" / "ticket.md").write_text("# ticket\n")
    runs = mem / "N1-1" / "telemetry" / "runs"
    runs.mkdir(parents=True)
    (runs / "r.jsonl").write_text(json.dumps({"steps": [
        {"step": "head", "completed_at": "2026-01-02T00:00:00Z", "metadata": {"head": "x", "from": "late"}},
        {"step": "head", "completed_at": "2026-01-01T00:00:00Z", "metadata": {"head": "y", "from": "early"}}]}) + "\n")
    return mem


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="rr-test-"))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)
        self.repo, self.base, self.head_a, self.head_c = make_repo(self.tmp)
        self.mem = make_memory(self.tmp, self.base)
        self.findings = self.tmp / "findings.tsv"
        self.findings.write_text("finding\tclass\trationale\nN1-1#1\tmissed\tnot listed\nN1-1#2\tcaught\tCR-1 same bug\n")
        self.shas = self.tmp / "sha.tsv"
        self.shas.write_text("ticket\tgroup\treviewhead\treach\tcodex7\treach\tprefix\treach\tbranchpoint\n"
                             f"N1-1\tA\t{self.head_a}\tY\t\tN\t\tN\t{self.base}\n"
                             f"N1-2\tC\t{self.head_c}\tY\t\tN\t\tN\t{self.base}\n")
        self.cases = self.tmp / "cases.jsonl"

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = rr.main([str(a) for a in argv])
        return rc, out.getvalue(), err.getvalue()

    def build(self, *extra):
        return self.run_main("build", "--findings", self.findings, "--shas", self.shas, "--cases", self.cases,
                             "--min-pairs", "1", "--repo", self.repo, "--memory-root", self.mem, *extra)


class BuildTest(Fixture):
    def test_build_case_file(self):
        # Bugs caught: diff size measured on the wrong range (bad size matching); answer key or
        # severity not taken from the triage block; replay SHA source or first head-event `from`
        # missing (AC1/D4); test set silently rebuilt without --force; shortfall below 15 accepted.
        rc, _, err = self.build()
        self.assertEqual(rc, 0, err)
        meta, rows = rr.load_cases(self.cases)
        self.assertEqual(meta["seed"], 629)
        f1, f2, ctl = rows
        self.assertEqual((f1["id"], f1["class"], f1["severity"], f1["answer_key"]),
                         ("N1-1#1", "missed", "P1", "Echo drops the last line (a.sh:2)"))
        self.assertEqual((f1["replay_sha"], f1["branch_point"], f1["diff_lines"], f1["reachable"]),
                         (self.head_a, self.base, 2, True))
        self.assertEqual((f1["first_head_from"], f1["split"]), ("early", "test"))
        self.assertIn("step:review", f1["sha_source"])
        self.assertEqual((f2["class"], f2["severity"], f2["split"]), ("caught", None, "test"))
        self.assertEqual((ctl["kind"], ctl["ticket"], ctl["matched_to"], ctl["diff_lines"], ctl["delta_lines"], ctl["split"]),
                         ("control", "N1-2", "N1-1", 3, 1, "test"))
        self.assertEqual(self.build()[0], 1)
        self.assertEqual(self.build("--force")[0], 0)
        self.cases = self.tmp / "short.jsonl"
        self.assertEqual(self.build("--min-pairs", "15")[0], 1)
        self.assertFalse(self.cases.exists())


if __name__ == "__main__":
    unittest.main()

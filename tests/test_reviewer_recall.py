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


FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
sid = a[a.index("--session-id") + 1]
prompt = a[a.index("-p") + 1]
log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log, "a") as fh:
        fh.write(json.dumps({"cwd": os.getcwd(), "argv": a, "env": sorted(os.environ)}) + "\n")
if "against an answer key" in prompt:
    result = "not json" if os.environ.get("FAKE_JUDGE") == "bad" else '{"verdict":"caught","finding_ref":"CR-1","reason":"same defect"}'
else:
    result = ("## Code Review Findings\n\n### High\n- **[CR-1]** Echo drops the last line\n  - File: a.sh:2\n\n"
              "### Verdict: FAIL\n0 critical, 1 high, 0 medium, 0 low findings\n")
print(json.dumps({"session_id": sid, "result": result, "total_cost_usd": 0.01,
                  "usage": {"input_tokens": 1, "output_tokens": 2}}))
'''


class ClaudeFixture(Fixture):
    def setUp(self):
        super().setUp()
        self.claude = self.tmp / "fake-claude"
        self.claude.write_text(FAKE_CLAUDE)
        self.claude.chmod(0o755)
        self.log = self.tmp / "claude.log"
        self.env = {"FAKE_CLAUDE_LOG": str(self.log), "N1_PROBE": "leak"}
        self.assertEqual(self.build()[0], 0)

    def calls(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.exists() else []

    def replay(self, *extra):
        with mock.patch.dict(os.environ, self.env):
            rc, out, err = self.run_main("replay", "--cases", self.cases, "--out", self.tmp / "out",
                                         "--claude", self.claude, "--repo", self.repo, "--memory-root", self.mem,
                                         "--persona", self.repo / "agents" / "code-reviewer.md", *extra)
        return rc, Path(out.strip().splitlines()[-1]), err


class ReplayTest(ClaudeFixture):
    def test_one_case_end_to_end_in_detached_worktree(self):
        # Bugs caught (AC2): reviewer run in the main checkout, with Write or skip-permissions;
        # worktree left registered or on disk; main checkout HEAD/status changed; persona commit
        # not recorded (D6); N1_* leaking into the child env; diff not delivered to the reviewer;
        # the ticket memory dir (codex-triage answer key, stored reviews) readable by the reviewer.
        head_before = sh(self.repo, "rev-parse", "HEAD")
        rc, run_dir, err = self.replay("--case", "N1-1#1")
        self.assertEqual(rc, 0, err)
        rows = rr.read_jsonl(run_dir / "replay.jsonl")
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r["id"], r["kind"], r["status"], r["n_findings"], r["replay_sha"]),
                         ("N1-1", "missed", "ok", 1, self.head_a))
        self.assertEqual(r["persona_commit"], sh(self.repo, "log", "-1", "--format=%H", "--", "agents/code-reviewer.md"))
        self.assertIn("+echo b", (run_dir / "N1-1.diff").read_text())
        call = self.calls()[0]
        self.assertEqual(Path(call["cwd"]).resolve(), (run_dir / "wt-N1-1").resolve())
        self.assertEqual(call["argv"][call["argv"].index("--tools") + 1], "Read,Grep,Glob")
        self.assertNotIn("--dangerously-skip-permissions", call["argv"])
        self.assertNotIn("N1_PROBE", call["env"])
        # answer-key isolation: the reviewer gets copies of the review inputs only, never the ticket memory dir
        prompt = call["argv"][call["argv"].index("-p") + 1]
        self.assertNotIn(str(self.mem), prompt)
        self.assertNotIn(str(self.mem / "N1-1"), call["argv"])
        self.assertEqual((run_dir / "N1-1.inputs" / "ticket.md").read_text(), "# ticket\n")
        self.assertFalse((run_dir / "N1-1.inputs" / "codex-triage.posted.md").exists())
        self.assertFalse((run_dir / "wt-N1-1").exists())
        self.assertEqual(sh(self.repo, "worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertEqual(sh(self.repo, "rev-parse", "HEAD"), head_before)
        self.assertEqual(sh(self.repo, "status", "--porcelain"), "")

    def test_split_loop_covers_controls_and_resumes(self):
        # Bug caught: the loop skips control tickets, or a resumed loop pays again for
        # tickets already in replay.jsonl.
        rc, run_dir, err = self.replay("--split", "all")
        self.assertEqual(rc, 0, err)
        self.assertEqual(sorted(r["id"] for r in rr.read_jsonl(run_dir / "replay.jsonl")), ["N1-1", "N1-2"])
        rc, _, err = self.replay("--split", "all", "--run-dir", run_dir)
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(len(rr.read_jsonl(run_dir / "replay.jsonl")), 2)

    def test_resume_retries_error_rows_without_duplicates(self):
        # Bug caught: a resumed loop skips tickets whose earlier row was error/timeout, or keeps the
        # stale row next to the retry so the ticket is counted twice.
        rc, run_dir, err = self.replay("--split", "all")
        self.assertEqual(rc, 0, err)
        f = run_dir / "replay.jsonl"
        rows = rr.read_jsonl(f)
        rows[0]["status"] = "error"
        f.write_text("".join(json.dumps(r) + "\n" for r in rows))
        rc, _, err = self.replay("--split", "all", "--run-dir", run_dir)
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(self.calls()), 3)
        after = rr.read_jsonl(f)
        self.assertEqual(sorted(r["id"] for r in after), ["N1-1", "N1-2"])
        self.assertEqual({r["status"] for r in after}, {"ok"})

    def test_unreachable_sha_is_a_status_not_a_crash(self):
        # Bug caught: a garbage-collected squash-merge SHA aborts the loop or is counted as a miss.
        rows = rr.read_jsonl(self.cases)
        for r in rows:
            if r.get("ticket") == "N1-1":
                r["replay_sha"] = "0" * 40
        self.cases.write_text("".join(json.dumps(r) + "\n" for r in rows))
        rc, run_dir, err = self.replay("--case", "N1-1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(rr.read_jsonl(run_dir / "replay.jsonl")[0]["status"], "unreachable")
        self.assertEqual(self.calls(), [])


def rule_text(enforcement, paths, body):
    return (f"---\ndescription: test rule\ntopic: reliability\napplies_to: [code-reviewer]\n"
            f"enforcement: {enforcement}\npaths: {paths}\n---\n\n{body}\n")


class ReplayRulesTest(ClaudeFixture):
    GATE_BODY = "Every echo line in a.sh is kept."
    QUEUE_BODY = "Queue gates fail closed."
    DENY_BODY = "Never write a.sh directly."

    def make_rules(self):
        d = self.tmp / "rules"
        d.mkdir(exist_ok=True)
        (d / "gate-a.rule.md").write_text(rule_text("gate", "a.sh", self.GATE_BODY))
        (d / "gate-queue.rule.md").write_text(rule_text("gate", "lib/queue.sh", self.QUEUE_BODY))
        (d / "deny-a.rule.md").write_text(rule_text("deny", "a.sh", self.DENY_BODY))
        return d

    def prompts(self):
        return [c["argv"][c["argv"].index("-p") + 1] for c in self.calls()]

    def replay_rc(self, *extra):
        with mock.patch.dict(os.environ, self.env):
            rc, _, err = self.run_main("replay", "--cases", self.cases, "--claude", self.claude, "--repo", self.repo,
                                       "--memory-root", self.mem,
                                       "--persona", self.repo / "agents" / "code-reviewer.md", *extra)
        return rc, err

    def test_without_flag_prompt_and_rows_carry_no_rules(self):
        # Bug caught: the default replay (the N1-629 baseline path) changes when no --rules-dir is given.
        rc, run_dir, err = self.replay("--case", "N1-1")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("Project Rules", self.prompts()[0])
        r = rr.read_jsonl(run_dir / "replay.jsonl")[0]
        self.assertEqual((r["rules_files"], r["rules_sha256"]), ([], None))

    def test_gate_rules_matching_changed_files_reach_the_prompt(self):
        # Bugs caught: rules never reach the replayed reviewer (AC3 would measure nothing); the paths
        # filter is ignored (a lib/queue.sh rule leaks into an a.sh diff); deny rules injected as gate rules.
        d = self.make_rules()
        rc, run_dir, err = self.replay("--split", "all", "--rules-dir", d)
        self.assertEqual(rc, 0, err)
        prompts = self.prompts()
        self.assertEqual(len(prompts), 2)
        for p in prompts:
            self.assertIn("## Project Rules (non-negotiable)", p)
            self.assertIn(self.GATE_BODY, p)
            self.assertNotIn(self.QUEUE_BODY, p)
            self.assertNotIn(self.DENY_BODY, p)
        rows = rr.read_jsonl(run_dir / "replay.jsonl")
        self.assertEqual({tuple(r["rules_files"]) for r in rows}, {("gate-a.rule.md",)})
        self.assertEqual({r["rules_sha256"] for r in rows}, {rr.rules_digest(d)})

    def test_no_matching_rule_gives_an_unchanged_prompt(self):
        # Bug caught: an empty rules block still adds a "Project Rules" header to the prompt.
        d = self.tmp / "rules"
        d.mkdir()
        (d / "gate-queue.rule.md").write_text(rule_text("gate", "lib/queue.sh", self.QUEUE_BODY))
        rc, run_dir, err = self.replay("--case", "N1-1", "--rules-dir", d)
        self.assertEqual(rc, 0, err)
        self.assertNotIn("Project Rules", self.prompts()[0])
        self.assertEqual(rr.read_jsonl(run_dir / "replay.jsonl")[0]["rules_files"], [])

    def test_resume_refuses_changed_rules(self):
        # Bug caught: rows measured with different rules (or none) pooled in one run dir and one report.
        d = self.make_rules()
        rc, run_dir, err = self.replay("--case", "N1-1", "--rules-dir", d)
        self.assertEqual(rc, 0, err)
        (d / "gate-a.rule.md").write_text(rule_text("gate", "a.sh", "Changed body."))
        rc, err = self.replay_rc("--split", "all", "--run-dir", run_dir, "--rules-dir", d)
        self.assertEqual(rc, 1)
        self.assertIn("rules changed", err)
        rc, err = self.replay_rc("--split", "all", "--run-dir", run_dir)
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.calls()), 1)

    def test_missing_rules_dir_exits_before_any_run(self):
        # Bug caught: a typo in --rules-dir silently measures without rules.
        rc, err = self.replay_rc("--case", "N1-1", "--out", self.tmp / "out", "--rules-dir", self.tmp / "nope")
        self.assertEqual(rc, 1)
        self.assertIn("--rules-dir", err)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.tmp / "out").exists())


class GradeTest(ClaudeFixture):
    def grade(self, run_dir):
        with mock.patch.dict(os.environ, self.env):
            return self.run_main("grade", "--cases", self.cases, "--replay", run_dir, "--claude", self.claude)

    def test_grades_missed_findings_once(self):
        # Bugs caught: judge spent on caught findings or controls; judge given tools; verdict not
        # recorded; a re-run pays again for findings already graded; sample file missing (D5).
        _, run_dir, _ = self.replay("--split", "all")
        n_calls = len(self.calls())
        rc, _, err = self.grade(run_dir)
        self.assertEqual(rc, 0, err)
        grades = rr.read_jsonl(run_dir / "grades.jsonl")
        self.assertEqual([(g["id"], g["status"], g["verdict"]) for g in grades], [("N1-1#1", "ok", "caught")])
        judge = self.calls()[n_calls]
        self.assertEqual(judge["argv"][judge["argv"].index("--tools") + 1], "")
        self.assertTrue((run_dir / "grade-sample.md").read_text().startswith("sample: 1\n"))
        self.grade(run_dir)
        self.assertEqual(len(self.calls()), n_calls + 1)

    def test_unparseable_judge_reply_is_error_not_miss(self):
        # Bug caught: a malformed judge reply silently counted as `missed`, lowering recall.
        _, run_dir, _ = self.replay("--case", "N1-1")
        self.env["FAKE_JUDGE"] = "bad"
        self.grade(run_dir)
        g = rr.read_jsonl(run_dir / "grades.jsonl")[0]
        self.assertEqual((g["status"], g["verdict"]), ("error", None))
        # Bug caught: failed judge rows skipped forever on retry; stale confirmation kept for a new sample.
        (run_dir / "grade-sample.confirmed").write_text("0\n")
        self.env["FAKE_JUDGE"] = "ok"
        self.grade(run_dir)
        self.assertEqual([x["status"] for x in rr.read_jsonl(run_dir / "grades.jsonl")], ["ok"])
        self.assertFalse((run_dir / "grade-sample.confirmed").exists())


def finding(fid, cls, split, file="lib/q.sh:1"):
    return {"id": fid, "kind": "finding", "ticket": fid.split("#")[0], "class": cls, "split": split,
            "answer_key": "k", "codex_text": "c", "severity": "P2", "file": file, "diff_lines": 10}


def replay_row(t, kind, split, n):
    return {"id": t, "ticket": t, "kind": kind, "split": split, "status": "ok", "n_findings": n,
            "unparsed": False, "persona_commit": "abc", "persona_sha256": "f" * 64, "cost_usd": 0.5}


class ReportTest(unittest.TestCase):
    def fixture(self):
        meta = {"kind": "meta", "seed": 629, "tune_frac": 0.5}
        cases = [finding("N1-1#1", "missed", "test"), finding("N1-2#1", "missed", "test", "lib/q.sh"),
                 finding("N1-3#1", "missed", "tune", "x.sh"), finding("N1-4#1", "caught", None),
                 finding("N1-5#1", "partial", None), finding("N1-6#1", "unknown", None),
                 {"id": "N1-9", "kind": "control", "ticket": "N1-9", "split": "test", "matched_to": "N1-1",
                  "diff_lines": 12, "delta_lines": 2, "reachable": True}]
        replays = [replay_row("N1-1", "missed", "test", 2), replay_row("N1-2", "missed", "test", 4),
                   replay_row("N1-3", "missed", "tune", 1), replay_row("N1-9", "control", "test", 3)]
        grades = [{"id": "N1-1#1", "status": "ok", "verdict": "caught", "reason": "same", "cost_usd": 0.1},
                  {"id": "N1-2#1", "status": "ok", "verdict": "missed", "reason": "other", "cost_usd": 0.1},
                  {"id": "N1-3#1", "status": "error", "verdict": None, "reason": None, "cost_usd": 0.1}]
        return meta, cases, replays, grades

    def test_recall_overflag_exclusions(self):
        # Bugs caught: partial/unknown or judge errors entering a denominator (D3); tune and test
        # pooled; controls mixed into recall; recurring-miss list (AC5 input) grouping by full
        # file:line instead of file; two persona versions silently pooled in one report (D6).
        meta, cases, replays, grades = self.fixture()
        r = rr.compute_report(meta, cases, replays, grades, None)
        self.assertEqual((r["final"]["caught"], r["final"]["n"], r["final"]["partial"], r["final"]["unknown"]), (1, 4, 1, 1))
        self.assertEqual((r["raw"]["test"]["caught"], r["raw"]["test"]["n"]), (1, 2))
        self.assertEqual(r["raw"]["test"]["ci"], list(rr.wilson(1, 2)))
        self.assertEqual(r["raw"]["tune"]["n"], 0)
        self.assertEqual(r["exclusions"]["judge_error"], ["N1-3#1"])
        self.assertEqual((r["overflag"]["test_control"]["mean"], r["overflag"]["test_missed"]["mean"]), (3, 3))
        self.assertEqual(r["recurring"], {"lib/q.sh": ["N1-1#1", "N1-2#1"]})
        replays[0]["persona_commit"] = "other"
        with self.assertRaises(ValueError):
            rr.compute_report(meta, cases, replays, grades, None)
        replays[0]["persona_commit"] = "abc"
        replays[0]["persona_sha256"] = "e" * 64  # same commit, edited file
        with self.assertRaises(ValueError):
            rr.compute_report(meta, cases, replays, grades, None)

    def test_cli_report_and_manual_check_status(self):
        # Bug caught: the manual check (D5) reported as done before a human confirmed the sample.
        meta, cases, replays, grades = self.fixture()
        tmp = Path(tempfile.mkdtemp(prefix="rr-report-"))
        self.addCleanup(shutil.rmtree, str(tmp), True)
        (tmp / "cases.jsonl").write_text("".join(json.dumps(r) + "\n" for r in [meta] + cases))
        run = tmp / "run"
        run.mkdir()
        (run / "replay.jsonl").write_text("".join(json.dumps(r) + "\n" for r in replays))
        (run / "grades.jsonl").write_text("".join(json.dumps(r) + "\n" for r in grades))
        (run / "grade-sample.md").write_text("sample: 5\n")
        argv = ["report", "--cases", str(tmp / "cases.jsonl"), "--replay", str(run), "--report-out", str(tmp / "report.md")]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(rr.main(argv), 0)
        self.assertIn("manual check: pending", (tmp / "report.md").read_text())
        self.assertEqual(json.loads((tmp / "report.json").read_text())["raw"]["test"]["caught"], 1)
        (run / "grade-sample.confirmed").write_text("1\n")
        with contextlib.redirect_stdout(io.StringIO()):
            rr.main(argv)
        self.assertIn("manual check: 4/5 agree", (tmp / "report.md").read_text())


if __name__ == "__main__":
    unittest.main()

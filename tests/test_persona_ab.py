import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("persona_ab", REPO / "scripts" / "persona_ab.py")
ab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ab)


def row(task, arm, passed, out=100, turns=3, wall=1000, cost=0.01):
    return {"task": task, "arm": arm, "run": 0, "session_id": "s", "status": "ok", "passed": passed,
            "tokens": {"input_tokens": 10, "cache_read_input_tokens": 20,
                       "cache_creation_input_tokens": 30, "output_tokens": out},
            "num_turns": turns, "wall_ms": wall, "cost_usd": cost}


class ArmStatsTest(unittest.TestCase):
    def test_medians_over_passed_runs_only(self):
        rows = [row("t1", "baseline", True, out=100), row("t1", "baseline", True, out=300),
                row("t1", "baseline", False, out=9999, wall=999999)]
        s = ab.compute_arm_stats(rows)["baseline"]
        self.assertEqual(s["runs"], 3)
        self.assertEqual(s["passed"], 2)
        self.assertAlmostEqual(s["pass_rate"], 2 / 3)
        self.assertEqual(s["medians"]["output_tokens"], 200)
        self.assertEqual(s["medians"]["wall_ms"], 1000)

    def test_all_failed_arm_has_null_medians(self):
        s = ab.compute_arm_stats([row("t1", "candidate", False)])["candidate"]
        self.assertEqual(s["pass_rate"], 0)
        self.assertIsNone(s["medians"]["output_tokens"])
        self.assertIsNone(s["medians"]["num_turns"])

    def test_arms_are_separate(self):
        stats = ab.compute_arm_stats([row("t1", "baseline", True, out=1), row("t1", "candidate", True, out=2)])
        self.assertEqual(stats["baseline"]["medians"]["output_tokens"], 1)
        self.assertEqual(stats["candidate"]["medians"]["output_tokens"], 2)


class IntersectionTest(unittest.TestCase):
    def test_only_tasks_every_arm_passed_every_run(self):
        rows = [row("t1", "baseline", True), row("t1", "baseline", True),
                row("t1", "candidate", True, out=500),
                row("t2", "baseline", True), row("t2", "candidate", False),
                row("t3", "baseline", True)]  # t3 never ran on candidate
        p = ab.compute_intersection_stats(rows)
        self.assertEqual(p["tasks"], ["t1"])
        self.assertEqual(p["arms"]["baseline"]["output_tokens"], 100)
        self.assertEqual(p["arms"]["candidate"]["output_tokens"], 500)

    def test_empty_intersection(self):
        p = ab.compute_intersection_stats([row("t1", "baseline", False), row("t1", "candidate", True)])
        self.assertEqual(p, {"tasks": [], "arms": {}})


class ValidateRowTest(unittest.TestCase):
    def test_ok_row_with_matching_ids(self):
        self.assertIsNone(ab.validate_row({"session_id": "abc", "status": "ok", "raw": {"session_id": "abc"}}, "abc"))

    def test_missing_or_empty_session_id_rejected(self):
        self.assertIsNotNone(ab.validate_row({"status": "error"}, "abc"))
        self.assertIsNotNone(ab.validate_row({"session_id": None, "status": "error"}, "abc"))
        self.assertIsNotNone(ab.validate_row({"session_id": "", "status": "error"}, "abc"))

    def test_harness_id_mismatch_rejected(self):
        self.assertIsNotNone(ab.validate_row({"session_id": "zzz", "status": "error"}, "abc"))

    def test_ok_row_without_claude_session_id_rejected(self):
        self.assertIsNotNone(ab.validate_row({"session_id": "abc", "status": "ok", "raw": {}}, "abc"))
        self.assertIsNotNone(ab.validate_row({"session_id": "abc", "status": "ok", "raw": None}, "abc"))

    def test_ok_row_with_other_claude_session_id_rejected(self):
        self.assertIsNotNone(ab.validate_row({"session_id": "abc", "status": "ok", "raw": {"session_id": "x"}}, "abc"))

    def test_failed_row_keeps_harness_id(self):
        self.assertIsNone(ab.validate_row({"session_id": "abc", "status": "timeout", "raw": None}, "abc"))


class HelpersTest(unittest.TestCase):
    def test_strip_frontmatter_and_tools(self):
        meta, body = ab.strip_frontmatter("---\nname: x\ntools: Read, Grep, Write\neffort: high\n---\n\n# Body\n")
        self.assertEqual(body, "# Body\n")
        self.assertEqual(meta["effort"], "high")
        self.assertEqual(ab.tools_arg(meta), "Read,Grep,Write")

    def test_no_frontmatter(self):
        self.assertEqual(ab.strip_frontmatter("# Body\n"), ({}, "# Body\n"))
        self.assertEqual(ab.tools_arg({}), "default")

    def test_real_personas_parse(self):
        for name in ab.PERSONAS:
            meta, body = ab.strip_frontmatter((REPO / "agents" / f"{name}.md").read_text(encoding="utf-8"))
            self.assertEqual(meta["name"], name)
            self.assertTrue(meta["tools"])
            self.assertFalse(body.startswith("---"))

    def test_token_split(self):
        self.assertEqual(ab.token_split({"usage": {"input_tokens": 5, "output_tokens": 7}}),
                         {"input_tokens": 5, "cache_read_input_tokens": 0,
                          "cache_creation_input_tokens": 0, "output_tokens": 7})
        self.assertEqual(ab.token_split(None), dict.fromkeys(ab.TOKEN_KEYS, 0))

    def test_queue_interleaves_arms_and_is_seeded(self):
        q = ab.build_queue(["t1", "t2"], ["baseline", "candidate"], 3, seed=1)
        ordered = [(t, a, r) for t in ["t1", "t2"] for a in ["baseline", "candidate"] for r in range(3)]
        self.assertEqual(sorted(q), ordered)
        self.assertNotEqual(q, ordered)
        self.assertEqual(q, ab.build_queue(["t1", "t2"], ["baseline", "candidate"], 3, seed=1))

    def test_summarize_totals(self):
        s = ab.summarize([row("t1", "baseline", True), row("t1", "candidate", False)], 1, {"runs": "1"})
        self.assertEqual(s["rejected"], 1)
        self.assertEqual(s["total_cost_usd"], 0.02)
        self.assertEqual(s["tokens_total"]["cache_read_input_tokens"], 40)
        self.assertEqual(s["arms"]["candidate"]["pass_rate"], 0)
        self.assertEqual(s["paired"]["tasks"], [])
        self.assertEqual(s["args"], {"runs": "1"})


class FixtureTest(unittest.TestCase):
    def test_three_fixtures_per_persona(self):
        for persona in ab.PERSONAS:
            tasks = ab.load_fixtures(persona)
            self.assertEqual(len(tasks), 3, persona)
            for t in tasks:
                self.assertTrue(t["prompt"].strip(), t["name"])
                self.assertTrue((t["dir"] / "repo").is_dir(), t["name"])
                self.assertTrue((t["dir"] / "check.sh").is_file(), t["name"])

    def test_only_filters_by_name(self):
        self.assertEqual([t["name"] for t in ab.load_fixtures("developer", only="dev-fix-bug")], ["dev-fix-bug"])

    def test_check_fails_untouched_and_passes_with_solution(self):
        for persona in ab.PERSONAS:
            for t in ab.load_fixtures(persona):
                with self.subTest(t["name"]), tempfile.TemporaryDirectory() as tmp:
                    repo = Path(tmp) / "repo"
                    ab.prepare_repo(t["dir"], repo)
                    self.assertFalse(ab.run_check(t["dir"] / "check.sh", repo), "untouched repo must fail")
                    shutil.copytree(str(t["dir"] / "solution"), str(repo), dirs_exist_ok=True)
                    self.assertTrue(ab.run_check(t["dir"] / "check.sh", repo), "solution must pass")

    def test_modified_source_fails_qa_and_review_checks(self):
        for name, src in (("qa-fix-broken-test", "src/mathx.py"), ("cr-sql-injection", "db.py")):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                task_dir = ab.FIXTURES / name
                repo = Path(tmp) / "repo"
                ab.prepare_repo(task_dir, repo)
                shutil.copytree(str(task_dir / "solution"), str(repo), dirs_exist_ok=True)
                with open(repo / src, "a", encoding="utf-8") as fh:
                    fh.write("# edited\n")
                self.assertFalse(ab.run_check(task_dir / "check.sh", repo))


if __name__ == "__main__":
    unittest.main()

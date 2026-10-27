import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("persona_ab", REPO / "scripts" / "persona_ab.py")
ab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ab)


def row(task, arm, passed, out=100, turns=3, wall=1000, cost=0.01, run=0):
    return {"task": task, "arm": arm, "run": run, "session_id": "s", "status": "ok", "passed": passed,
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

    def test_empty_arm_is_reported(self):
        stats = ab.compute_arm_stats([row("t1", "baseline", True)])
        self.assertEqual(stats["candidate"]["runs"], 0)
        self.assertIsNone(stats["candidate"]["pass_rate"])
        self.assertIsNone(stats["candidate"]["medians"]["output_tokens"])

    def test_arms_are_separate(self):
        stats = ab.compute_arm_stats([row("t1", "baseline", True, out=1), row("t1", "candidate", True, out=2)])
        self.assertEqual(stats["baseline"]["medians"]["output_tokens"], 1)
        self.assertEqual(stats["candidate"]["medians"]["output_tokens"], 2)


class IntersectionTest(unittest.TestCase):
    def test_only_tasks_every_arm_passed_every_run(self):
        rows = [row("t1", "baseline", True), row("t1", "baseline", True, run=1),
                row("t1", "candidate", True, out=500), row("t1", "candidate", True, out=500, run=1),
                row("t2", "baseline", True), row("t2", "candidate", False),
                row("t3", "baseline", True)]  # t3 never ran on candidate
        p = ab.compute_intersection_stats(rows, runs=2)
        self.assertEqual(p["tasks"], ["t1"])
        self.assertEqual(p["arms"]["baseline"]["output_tokens"], 100)
        self.assertEqual(p["arms"]["candidate"]["output_tokens"], 500)

    def test_arm_with_fewer_runs_is_excluded(self):
        rows = [row("t1", "baseline", True), row("t1", "baseline", True, run=1),
                row("t1", "candidate", True)]  # candidate lost run 1
        self.assertEqual(ab.compute_intersection_stats(rows, runs=2)["tasks"], [])

    def test_empty_intersection(self):
        p = ab.compute_intersection_stats([row("t1", "baseline", False), row("t1", "candidate", True)])
        self.assertEqual(p["tasks"], [])

    def test_absent_arm_yields_empty_paired_set(self):
        p = ab.compute_intersection_stats([row("t1", "baseline", True)])
        self.assertEqual(p["tasks"], [])
        self.assertIsNone(p["delta"]["output_tokens"])

    def test_delta_is_candidate_minus_baseline(self):
        p = ab.compute_intersection_stats([row("t1", "baseline", True, out=100), row("t1", "candidate", True, out=70)])
        self.assertEqual(p["delta"]["output_tokens"], -30)
        self.assertEqual(p["delta"]["num_turns"], 0)


class ValidateRowTest(unittest.TestCase):
    def test_ok_row_with_matching_ids(self):
        self.assertIsNone(ab.validate_row({"session_id": "abc", "status": "ok", "raw": {"session_id": "abc"}}, "abc"))

    def test_missing_empty_or_mismatched_session_id_rejected(self):
        for sid in (None, "", "zzz"):
            self.assertIsNotNone(ab.validate_row({"session_id": sid, "status": "error"}, "abc"))
        self.assertIsNotNone(ab.validate_row({"status": "error"}, "abc"))

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

    def test_crlf_frontmatter_is_stripped(self):
        meta, body = ab.strip_frontmatter("---\r\nname: x\r\ntools: Read\r\n---\r\nBody\r\n")
        self.assertEqual(meta["tools"], "Read")
        self.assertEqual(body, "Body\n")

    def test_real_personas_parse(self):
        for name in ab.PERSONAS:
            meta, body = ab.strip_frontmatter((REPO / "agents" / f"{name}.md").read_text(encoding="utf-8"))
            self.assertEqual(meta["name"], name)
            self.assertTrue(body.strip())
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


class ScrubEnvTest(unittest.TestCase):
    def test_denylist_drops_secrets_keeps_auth_and_proxy(self):
        env = {"AWS_ACCESS_KEY_ID": "x", "AZURE_CLIENT_ID": "x", "GOOGLE_APPLICATION_CREDENTIALS": "x",
               "GH_TOKEN": "x", "GITHUB_TOKEN": "x", "DB_SECRET_KEY": "x", "NPM_TOKEN": "x", "N1_HOME": "x",
               "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_OAUTH_TOKEN": "t", "HOME": "/h", "PATH": "/bin",
               "HTTPS_PROXY": "p", "NO_PROXY": "n",
               "OPENAI_API_KEY": "x", "DB_PASSWORD": "x", "GITLAB_PAT": "x", "SVC_CREDENTIALS": "x",
               "SSH_AUTH_SOCK": "x", "DATABASE_URL": "x"}
        self.assertEqual(set(ab.scrub_env(env)), {"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "HOME",
                                                  "PATH", "HTTPS_PROXY", "NO_PROXY"})


class ProcessGroupTest(unittest.TestCase):
    def test_interrupt_kills_group(self):
        real = ab.subprocess.Popen.communicate
        calls = []

        def fake(self, *a, **kw):
            if not calls:
                calls.append(1)
                raise KeyboardInterrupt
            return real(self, *a, **kw)

        with mock.patch.object(ab.subprocess.Popen, "communicate", fake), \
                mock.patch.object(ab.os, "killpg", wraps=ab.os.killpg) as kp:
            with self.assertRaises(KeyboardInterrupt):
                ab.run_group(["sleep", "60"], ".", 30)
        kp.assert_called_once()

    def test_timeout_kills_grandchildren(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "pid"
            script = Path(tmp) / "check.sh"
            script.write_text(f'sleep 60 &\necho $! > {pidfile}\nwait\n')
            self.assertFalse(ab.run_check(script, tmp, timeout=1))
            pid = int(pidfile.read_text())
            time.sleep(0.2)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_children_do_not_see_scrubbed_env(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"GITHUB_TOKEN": "leak"}):
            script = Path(tmp) / "check.sh"
            script.write_text('[ -z "$GITHUB_TOKEN" ]\n')
            self.assertTrue(ab.run_check(script, tmp))


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

    def test_cr_check_requires_defect_description(self):
        task_dir = ab.FIXTURES / "cr-sql-injection"
        for text in ("db.py:6 - no defects found\n", "db.py:6 - looks fine\n"):
            with self.subTest(text), tempfile.TemporaryDirectory() as tmp:
                repo = Path(tmp) / "repo"
                ab.prepare_repo(task_dir, repo)
                (repo / "findings.md").write_text(text, encoding="utf-8")
                self.assertFalse(ab.run_check(task_dir / "check.sh", repo))

    def test_qa_check_kills_every_mutant(self):
        # Dropping the tax= case / the space case from the suite leaves a mutant alive.
        for name, drop in (("qa-update-test", "test_explicit_tax"), ("qa-missing-test", "test_ignores_case_and_spaces")):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                task_dir = ab.FIXTURES / name
                repo = Path(tmp) / "repo"
                ab.prepare_repo(task_dir, repo)
                shutil.copytree(str(task_dir / "solution"), str(repo), dirs_exist_ok=True)
                test_file = next(repo.glob("test_*.py"))
                src = test_file.read_text(encoding="utf-8")
                self.assertIn(drop, src)
                test_file.write_text(src.replace("def " + drop, "def _" + drop), encoding="utf-8")
                self.assertFalse(ab.run_check(task_dir / "check.sh", repo), "weakened suite must fail")


FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
sid = argv[argv.index("--session-id") + 1]
with open(argv[argv.index("--append-system-prompt-file") + 1], encoding="utf-8") as fh:
    prompt = fh.read()
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"argv": argv, "prompt": prompt, "cwd": os.getcwd()}) + "\\n")
out = {"type": "result", "is_error": False, "session_id": sid, "num_turns": 2, "duration_ms": 5,
       "total_cost_usd": 0.01, "usage": {"input_tokens": 1, "cache_read_input_tokens": 2,
                                         "cache_creation_input_tokens": 3, "output_tokens": 4}}
if os.environ.get("FAKE_DROP_SID"):
    del out["session_id"]
print(json.dumps(out))
"""


class EndToEndTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, str(self.tmp), True)
        fx = self.tmp / "fx" / "t1"
        (fx / "repo").mkdir(parents=True)
        (fx / "task.json").write_text(json.dumps({"persona": "developer", "prompt": "do it"}))
        (fx / "repo" / "a.txt").write_text("a\n")
        (fx / "check.sh").write_text("exit 0\n")
        self.fake = self.tmp / "claude"
        self.fake.write_text(FAKE_CLAUDE)
        self.fake.chmod(0o755)
        self.persona = self.tmp / "p.md"
        self.persona.write_text("---\nname: developer\ntools: Read, Edit\n---\nBODY\n")
        self.log = self.tmp / "argv.jsonl"

    def run_main(self, env, out=True):
        argv = ["--persona", "developer", "--baseline", str(self.persona), "--candidate", str(self.persona),
                "--runs", "2", "--seed", "1", "--fixtures", str(self.tmp / "fx"), "--claude", str(self.fake)]
        if out:
            argv += ["--out", str(self.tmp / "out")]
        env = dict(env, FAKE_LOG=str(self.log))
        stdout = io.StringIO()
        with mock.patch.dict(os.environ, env), contextlib.redirect_stderr(io.StringIO()), \
                contextlib.redirect_stdout(stdout):
            code = ab.main(argv)
        self.run_dir = Path(stdout.getvalue().strip())
        return code

    def test_writes_raw_and_summary(self):
        self.assertEqual(self.run_main({}), 0)
        rows = [json.loads(l) for l in (self.run_dir / "raw.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 4)
        self.assertEqual({r["arm"] for r in rows}, {"baseline", "candidate"})
        self.assertTrue(all(r["session_id"] and r["status"] == "ok" and r["passed"] for r in rows))
        self.assertEqual(len({r["session_id"] for r in rows}), 4)
        summary = json.loads((self.run_dir / "summary.json").read_text())
        self.assertEqual(summary["arms"]["baseline"]["pass_rate"], 1.0)
        self.assertEqual(summary["paired"]["tasks"], ["t1"])
        self.assertEqual(summary["rejected"], 0)
        self.assertEqual(summary["total_cost_usd"], 0.04)
        self.assertEqual(summary["tokens_total"]["output_tokens"], 16)
        calls = [json.loads(l) for l in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 4)
        for c in calls:
            a = c["argv"]
            self.assertEqual(c["prompt"], "BODY\n")
            self.assertEqual(a[a.index("--tools") + 1], "Read,Edit")
            self.assertEqual(a[a.index("--setting-sources") + 1], "")
            self.assertIn("--strict-mcp-config", a)
            self.assertIn("--dangerously-skip-permissions", a)
            self.assertNotEqual(Path(c["cwd"]).resolve(), REPO)

    def test_row_without_session_id_rejected(self):
        self.assertEqual(self.run_main({"FAKE_DROP_SID": "1"}), 2)
        self.assertEqual((self.run_dir / "raw.jsonl").read_text(), "")
        summary = json.loads((self.run_dir / "summary.json").read_text())
        self.assertEqual(summary["rejected"], 4)
        self.assertEqual(summary["rejected_cost_usd"], 0.04)

    def test_defaults_to_n1_home_scratch(self):
        home = self.tmp / "n1home"
        self.assertEqual(self.run_main({"N1_HOME": str(home)}, out=False), 0)
        self.assertEqual(self.run_dir.parent, home / "scratch" / "benchmarks")
        self.assertRegex(self.run_dir.name, r"^persona-ab-developer-\d{8}T\d{6}Z$")
        self.assertTrue((self.run_dir / "summary.json").is_file())
        self.assertTrue((self.run_dir / "raw.jsonl").is_file())

    def test_differing_tools_or_effort_rejected(self):
        for cand in ("---\nname: developer\ntools: Read\n---\nBODY\n", "BODY\n",
                     "---\nname: developer\ntools: Read, Edit\neffort: high\n---\nBODY\n"):
            other = self.tmp / "c.md"
            other.write_text(cand)
            with self.subTest(cand), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                ab.main(["--persona", "developer", "--baseline", str(self.persona), "--candidate", str(other),
                         "--fixtures", str(self.tmp / "fx"), "--claude", str(self.fake), "--out", str(self.tmp / "out")])
        self.assertFalse(self.log.exists())

    def test_summary_written_when_run_raises(self):
        with mock.patch.object(ab, "run_one", side_effect=OSError("boom")), self.assertRaises(OSError):
            self.run_main({})
        self.assertEqual(json.loads((next((self.tmp / "out").iterdir()) / "summary.json").read_text())["rejected"], 0)

    def test_no_out_and_no_n1_home_fails_fast(self):
        with mock.patch.dict(os.environ, {}), contextlib.redirect_stderr(io.StringIO()):
            os.environ.pop("N1_HOME", None)
            with self.assertRaises(SystemExit):
                ab.main(["--persona", "developer", "--baseline", str(self.persona),
                         "--candidate", str(self.persona), "--claude", str(self.fake)])
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()

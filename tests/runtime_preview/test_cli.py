from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

from test_contract import capability_report
from test_workflow import event, finding, result_for


ROOT = Path(__file__).resolve().parents[2]


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"untouchedLegacy": True, "runtimePreview": {
            "hosts": {"codex": {"models": capability_report()["models"]}}}}, indent=2) + "\n")
        self.original_config = self.config.read_bytes()
        self.capabilities = self.root / "capabilities.json"
        self.observed = self.root / "observed.json"
        self.capabilities.write_text(json.dumps(capability_report()))
        self.observed.write_text(json.dumps(capability_report()))
        self.env = dict(os.environ)

    def cli(self, *args, expected=0):
        completed = subprocess.run([sys.executable, "-m", "lib.runtime_review.cli", "--home", str(self.home),
                                    "--config-file", str(self.config), *args],
                                   cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(completed.returncode, expected, completed.stderr + completed.stdout)
        if expected == 0:
            self.assertEqual(completed.stderr, "")
        return completed

    def qualification_args(self):
        return ["--host", "codex", "--capabilities", str(self.capabilities), "--observed", str(self.observed)]

    def fixture_source(self):
        repo = self.root / "fixture"
        repo.mkdir()
        real_git = shutil.which("git")
        def git(*args):
            return subprocess.run([real_git, "-c", "core.hooksPath=/dev/null", "-C", str(repo), *args],
                                  check=True, capture_output=True, text=True).stdout.strip()
        git("init", "--quiet")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.invalid")
        (repo / "app.py").write_text("old\n")
        git("add", "app.py")
        git("commit", "--quiet", "-m", "base")
        base = git("rev-parse", "HEAD")
        (repo / "app.py").write_text("new\n")
        git("add", "app.py")
        git("commit", "--quiet", "-m", "head")
        head = git("rev-parse", "HEAD")
        fixture = self.root / "fixture.json"
        fixture.write_text(json.dumps({"metadata": {"number": 1, "title": "Example", "body": "Requirements",
                           "baseRefOid": base, "headRefOid": head, "url": "https://github.com/o/r/pull/1"},
                           "diff": git("diff", base, head) + "\n", "repo": str(repo), "git": real_git}))
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        script = ("#!" + sys.executable + "\n" +
                  "import json, os, pathlib, subprocess, sys\n"
                  "fixture = json.loads(pathlib.Path(os.environ['REVIEW_TEST_FIXTURE']).read_text())\n"
                  "args = sys.argv[1:]\n"
                  "if pathlib.Path(sys.argv[0]).name == 'gh':\n"
                  "    if args[:3] == ['pr', 'view', '1'] and args[3:5] == ['--repo', 'o/r']:\n"
                  "        print(json.dumps(fixture['metadata']))\n"
                  "    elif args == ['pr', 'diff', '1', '--repo', 'o/r', '--patch']:\n"
                  "        print(fixture['diff'], end='')\n"
                  "    else:\n"
                  "        sys.exit(91)\n"
                  "else:\n"
                  "    if 'fetch' in args:\n"
                  "        assert args[-2] == 'https://github.com/o/r.git'\n"
                  "        args[-2] = fixture['repo']\n"
                  "        args[args.index('fetch'):args.index('fetch')] = ['-c', 'protocol.file.allow=always']\n"
                  "    sys.exit(subprocess.run([fixture['git'], *args]).returncode)\n")
        for name in ("gh", "git"):
            executable = bin_dir / name
            executable.write_text(script)
            executable.chmod(0o700)
        self.env.update(PATH=str(bin_dir) + os.pathsep + self.env["PATH"], REVIEW_TEST_FIXTURE=str(fixture))

    def prepare(self):
        self.fixture_source()
        value = json.loads(self.cli("prepare", "--target", "o/r#1", *self.qualification_args()).stdout)
        self.run = self.home / "scratch" / "reviews" / value["runId"]
        return value

    def state(self):
        return json.loads((self.run / "state.json").read_text())

    def send(self, kind, expected=0, **payload):
        state = self.state()
        file = self.root / "event.json"
        file.write_text(json.dumps(event(state, kind, **payload)))
        return self.cli("event", "--run", state["runId"], "--file", str(file), expected=expected)

    def test_preflight_returns_json_and_leaves_config_and_scratch_untouched(self):
        value = json.loads(self.cli("preflight", *self.qualification_args()).stdout)
        self.assertEqual(value["host"], "codex")
        self.assertEqual(value["capabilities"]["isolatedContext"]["status"], "available")
        self.assertFalse((self.home / "scratch").exists())
        self.assertEqual(self.config.read_bytes(), self.original_config)

    def test_invalid_commands_targets_and_options_use_stderr_only(self):
        cases = [("prepare", *self.qualification_args()), ("resume",),
                 ("prepare", "--target", "1", *self.qualification_args()),
                 ("preflight", "--host", "auto", "--capabilities", str(self.capabilities), "--observed", str(self.observed)),
                 ("reader", "exec", "--root", str(self.root), "--value", "pwd"),
                 ("report", "--run", "../escape"),
                 ("prepare", "--target", "o/r#1", "--mode", "autonomous", *self.qualification_args()),
                 ("report", "--run", "run-1", "--output", "/arbitrary")]
        for args in cases:
            with self.subTest(args=args):
                value = self.cli(*args, expected=2)
                self.assertEqual(value.stdout, "")
                self.assertTrue(value.stderr)
        self.assertFalse((self.home / "scratch").exists())

    def test_prepare_revalidates_evidence_and_policies_before_dispatch(self):
        observed = capability_report()
        observed["configurationDigest"] = "d" * 64
        self.observed.write_text(json.dumps(observed))
        failure = self.cli("prepare", "--target", "o/r#1", *self.qualification_args(), expected=2)
        self.assertIn("configurationDigest", failure.stderr)
        self.assertFalse((self.home / "scratch").exists())
        self.observed.write_text(json.dumps(capability_report()))
        config = json.loads(self.config.read_text())
        config["runtimePreview"]["hosts"]["codex"]["models"]["review-verifier"] = {
            "mode": "explicit", "provider": "native", "model": "different", "effort": None}
        self.config.write_text(json.dumps(config))
        failure = self.cli("prepare", "--target", "o/r#1", *self.qualification_args(), expected=2)
        self.assertIn("review-verifier", failure.stderr)
        self.assertFalse((self.home / "scratch").exists())

    def test_prepare_persists_initial_requests_and_report_is_incomplete(self):
        value = self.prepare()
        self.assertEqual([item["request"]["role"] for item in value["actions"]], ["code-reviewer", "security-reviewer"])
        self.assertEqual(self.state()["generation"], 1)
        for action in value["actions"]:
            request = action["request"]
            self.assertEqual(json.loads((self.run / "requests" / (request["role"] + ".json")).read_text()), request)
            self.assertEqual((Path(request["cwd"]) / "app.py").read_text(), "new\n")
        report = json.loads(self.cli("report", "--run", value["runId"], expected=3).stdout)
        self.assertIn("incomplete review", report["report"])
        self.assertEqual((self.run / "report.md").read_text(), report["report"])
        self.assertEqual(self.config.read_bytes(), self.original_config)

    def test_full_review_keeps_raw_text_separate_and_returns_zero_for_defects(self):
        self.prepare()
        for role, handle in [("code-reviewer", "code-worker"), ("security-reviewer", "security-worker")]:
            self.send("spawned", requestId=self.state()["workers"][role]["request"]["requestId"], workerId=handle)
        self.send("result", result=result_for(self.state(), "code-reviewer", findings=[finding()]), rawText="original worker JSON text")
        joined = json.loads(self.send("result", result=result_for(self.state(), "security-reviewer"),
                                      rawText="original security worker JSON text").stdout)
        self.assertEqual(len(joined["actions"]), 1)
        self.assertEqual(json.loads((self.run / "inputs" / "claims").read_text()), [
            {"id": "code-reviewer:1", "title": "Bound", "file": "app.py", "line": 1, "claim": "Zero divides"}])
        self.assertEqual((self.run / "results" / "code-reviewer.raw.txt").read_text(), "original worker JSON text")
        self.assertEqual((self.run / "results" / "security-reviewer.raw.txt").read_text(),
                         "original security worker JSON text")
        self.assertEqual(json.loads((self.run / "results" / "code-reviewer.json").read_text())["status"], "completed")
        self.assertNotIn("rawText", self.state()["workers"]["code-reviewer"]["result"])
        self.send("spawned", requestId=joined["actions"][0]["request"]["requestId"], workerId="verifier-worker")
        completed = json.loads(self.send("result", result=result_for(self.state(), "review-verifier", dispositions=[
            {"id": "code-reviewer:1", "verdict": "confirmed", "reason": "Caller supplies zero"}]),
                                           rawText="original verifier worker JSON text").stdout)
        self.assertEqual((completed["status"], completed["actions"]), ("completed", [{"kind": "report"}]))
        self.assertEqual((self.run / "results" / "review-verifier.raw.txt").read_text(),
                         "original verifier worker JSON text")
        report = json.loads(self.cli("report", "--run", self.run.name).stdout)
        self.assertIn("Assessment: request changes", report["report"])

    def test_invalid_locations_cannot_become_verifier_claims(self):
        self.prepare()
        req = self.state()["workers"]["code-reviewer"]["request"]["requestId"]
        self.send("spawned", requestId=req, workerId="code-worker")
        for file, line in [("missing.py", 1), ("app.py", 2), ("../state.json", 1), (".git/config", 1)]:
            with self.subTest(file=file, line=line):
                state = self.state()
                self.send("result", expected=2, result=result_for(state, "code-reviewer", findings=[
                    {**finding(), "file": file, "line": line}]), rawText="invalid location worker JSON text")
                self.assertEqual(self.state(), state)

    def test_duplicate_and_cross_run_events_fail_without_changing_generation(self):
        value = self.prepare()
        initial = self.state()
        started = event(initial, "spawned", requestId=value["actions"][0]["request"]["requestId"], workerId="code-worker")
        file = self.root / "event.json"
        file.write_text(json.dumps(started))
        self.cli("event", "--run", self.run.name, "--file", str(file))
        accepted = self.state()
        self.cli("event", "--run", self.run.name, "--file", str(file), expected=2)
        started["eventId"] = "cross-run"
        started["runId"] = "foreign-run"
        file.write_text(json.dumps(started))
        self.cli("event", "--run", self.run.name, "--file", str(file), expected=2)
        self.assertEqual(self.state(), accepted)

    def test_session_loss_returns_incomplete_with_cancellation_actions(self):
        self.prepare()
        self.send("spawned", requestId=self.state()["workers"]["code-reviewer"]["request"]["requestId"], workerId="code-worker")
        value = json.loads(self.send("lost-session", reason="native session lost", expected=3).stdout)
        self.assertEqual(value["status"], "failed")
        self.assertIn({"kind": "cancel", "workerId": "code-worker"}, value["actions"])
        self.assertIn("code-worker", self.state()["cancellationUnconfirmed"])

    def test_reader_is_literal_bounded_and_json_only(self):
        source = self.root / "source"
        source.mkdir()
        (source / "a.txt").write_text("literal .*\nsecond\n")
        value = json.loads(self.cli("reader", "read", "--root", str(source), "--value", "a.txt").stdout)
        self.assertEqual(value, "literal .*\nsecond\n")
        matches = json.loads(self.cli("reader", "search", "--root", str(source), "--value", ".*").stdout)
        self.assertEqual(matches, [{"file": "a.txt", "line": 1, "text": "literal .*"}])
        self.assertEqual(self.cli("reader", "read", "--root", str(source), "--value", "../config.json", expected=2).stdout, "")

    def test_trusted_home_and_config_options_cannot_be_overridden(self):
        for option, path in (("--home", self.root), ("--config-file", self.capabilities)):
            with self.subTest(option=option):
                result = self.cli(option, str(path), "preflight", *self.qualification_args(), expected=2)
                self.assertIn(option, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_duplicate_json_keys_are_invalid(self):
        self.prepare()
        before = self.state()
        file = self.root / "event.json"
        file.write_text('{"kind":"cancel","kind":"lost-session","runId":"' + self.run.name +
                        '","eventId":"duplicate-key","reason":"lost"}')
        result = self.cli("event", "--run", self.run.name, "--file", str(file), expected=2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.state(), before)

    def test_null_raw_text_is_invalid_without_accepting_the_event(self):
        self.prepare()
        before = self.state()
        result = self.send("cancel", reason="cancel", rawText=None, expected=2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.state(), before)

    def test_result_requires_adapter_captured_raw_text_before_accepting_the_event(self):
        self.prepare()
        request_id = self.state()["workers"]["code-reviewer"]["request"]["requestId"]
        self.send("spawned", requestId=request_id, workerId="code-worker")
        before = self.state()
        result = self.send("result", result=result_for(before, "code-reviewer"), expected=2)
        self.assertEqual(result.stdout, "")
        self.assertIn("rawText", result.stderr)
        self.assertEqual(self.state(), before)

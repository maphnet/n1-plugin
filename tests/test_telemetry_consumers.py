import importlib.util
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


analyzer = load("telemetry_analyzer", REPO / "scripts" / "telemetry_analyzer.py")


class TelemetryConsumersTest(unittest.TestCase):
    def test_missing_usage_stays_unknown(self):
        run = {"host": "unknown", "summary": {},
               "agents": [{"agent_type": "n1-developer", "usage_status": "unknown"}]}
        totals = analyzer.extract_totals(run)
        self.assertIsNone(totals["input_tokens"])
        self.assertIsNone(totals["output_tokens"])

    def test_step_duration_is_not_elapsed_duration(self):
        self.assertIsNone(analyzer.compute_duration({'steps': [{'duration_s': 40}]}))

    def test_null_step_name_aggregates_and_compares(self):
        run = {"run_id": "r", "steps": [{"step": None, "duration_s": 3}, {"step": "x", "duration_s": 1}]}
        report = analyzer.extract_run_report(run)
        self.assertEqual([s["name"] for s in report["steps"]], ["unknown", "x"])
        agg = analyzer.aggregate_runs([report])
        self.assertIn("unknown", agg["by_step"])
        analyzer._diff_reports(report, report)

    def test_null_agent_fields_surface_as_unknown(self):
        run = {"run_id": "r", "agents": [{"agent_type": None, "step": None, "duration_s": 2}],
               "steps": [{"step": "x", "outcome": None}]}
        report = analyzer.extract_run_report(run)
        self.assertEqual(report["agents"][0]["type"], "unknown")
        self.assertEqual(report["agents"][0]["step"], "unknown")
        self.assertEqual(report["steps"][0]["outcome"], "unknown")

    def test_date_window_is_inclusive_and_applied_before_last(self):
        def r(ts):
            return {"started_at": ts}
        runs = [r("2026-09-01T23:59:59Z"), r("2026-09-02T00:00:00Z"), r("2026-09-03T23:59:59Z"),
                r("2026-09-04T00:00:00Z"), {}]
        got = analyzer.filter_and_select(list(runs), 1, None, "2026-09-02", "2026-09-03")
        self.assertEqual([x["started_at"] for x in got], ["2026-09-03T23:59:59Z"])
        got = analyzer.filter_and_select(list(runs), 10, None, "2026-09-02", "2026-09-03")
        self.assertEqual(len(got), 2)
        self.assertEqual(len(analyzer.filter_and_select(list(runs), 10, None)), 5)

    def test_window_without_last_returns_all_in_window(self):
        runs = [{"started_at": f"2026-09-02T00:00:{i:02d}Z"} for i in range(30)]
        self.assertEqual(len(analyzer.filter_and_select(list(runs), None, None, "2026-09-02")), 30)
        self.assertIsNone(analyzer.build_parser().parse_args(["collect", "--since", "2026-09-02"]).last)

    def test_malformed_date_is_rejected(self):
        with self.assertRaises(SystemExit):
            analyzer.build_parser().parse_args(["collect", "--since", "09/02/2026"])

    def _run_with_impl(self, root, slug, ticket, text):
        d = Path(root) / slug / "memory" / ticket
        (d / "telemetry" / "runs").mkdir(parents=True)
        if text is not None:
            (d / "implementation.md").write_text(text)
        return {"run_id": ticket, "_source_path": str(d / "telemetry" / "runs" / "r.jsonl"),
                "outcomes": [{"outcomes": {"fix_cycles_count": 1}}]}

    def test_fix_cycles_by_kind_and_project(self):
        import tempfile
        impl = ("## Fix Cycle 1\n## Fix Cycle 1\n## Fix Cycle 2 (soft)\n"
                "## Codex Fix Cycle 1\n## Follow-up 2 (Codex review)\n"
                "## QA Fix Cycle 1\n## Fix Cycle 1 Summary\n## Implementation Summary\n"
                "## Review Fix Cycle 3\n## Local-Test Fix Cycle 1\n")
        with tempfile.TemporaryDirectory() as root:
            a = analyzer.extract_run_report(self._run_with_impl(root, "p1", "T-1", impl))
            b = analyzer.extract_run_report(self._run_with_impl(root, "p1", "T-2", None))
            self.assertEqual((a["fix_cycles_hard"], a["fix_cycles_soft"], a["fix_cycles_codex"]), (2, 1, 2))
            self.assertIsNone(b["fix_cycles_hard"])
            p = analyzer.aggregate_runs([a, b])["by_project"]["p1"]
            self.assertEqual((p["runs"], p["kind_runs"], p["fix_cycles_mean"]), (2, 1, 1))
            self.assertEqual((p["fix_cycles_hard_mean"], p["fix_cycles_soft_mean"]), (2, 1))


if __name__ == "__main__":
    unittest.main()

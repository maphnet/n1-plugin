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
        run = {"host": "codex", "summary": {},
               "agents": [{"agent_type": "n1-developer", "usage_status": "unknown"}]}
        totals = analyzer.extract_totals(run)
        self.assertIsNone(totals["input_tokens"])
        self.assertIsNone(totals["output_tokens"])
        self.assertEqual(analyzer.extract_agents(run)[0]["tokens"], "N/A")

    def test_step_duration_is_not_elapsed_duration(self):
        self.assertIsNone(analyzer.compute_duration({'steps': [{'duration_s': 40}]}))


if __name__ == "__main__":
    unittest.main()

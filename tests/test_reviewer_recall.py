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


if __name__ == "__main__":
    unittest.main()

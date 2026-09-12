from copy import deepcopy
import unittest

from lib.runtime_review import workflow
from lib.runtime_review.workflow import claims_for_verifier


ROLES = ("code-reviewer", "security-reviewer", "review-verifier")


def prepared():
    return {"cwd": "/scratch/run/source", "inputs": [
        {"name": name, "path": "/scratch/run/inputs/" + name, "required": True}
        for name in ("diff", "requirements", "conventions")],
        "revision": {"repository": "o/r", "baseSha": "a" * 40, "headSha": "b" * 40},
        "prNumber": 1, "prTitle": "Example"}


def policies():
    return {role: {"mode": "inherit", "provider": None, "model": None, "effort": None}
            for role in ROLES}


def event(state, kind, **payload):
    return {"eventId": "event-" + str(state["generation"] + 1),
            "runId": state["runId"], "kind": kind, **payload}


def transition(state, kind, **payload):
    return workflow.advance(state, event(state, kind, **payload))


def result_for(state, role, status="completed", findings=None, dispositions=None):
    worker = state["workers"][role]
    req = worker["request"]
    return {"schemaVersion": 1, "runId": req["runId"], "requestId": req["requestId"],
            "host": req["host"], "role": role, "revision": deepcopy(req["revision"]),
            "status": status,
            "evidence": {"workerId": worker["workerId"], "requestedModel": None,
                         "effectiveModel": None, "effectiveModelReason": "Host observation unavailable",
                         "enforcement": "native-probe-digest", "tokenUsage": None},
            "output": ({"dispositions": dispositions or []} if role == "review-verifier"
                       else {"findings": findings or []}) if status == "completed" else None,
            "error": None if status == "completed" else {"code": "worker-failed", "message": "worker failed"}}


def finding(role="code-reviewer"):
    return {"id": role + ":1", "title": "Bound", "file": "app.py", "line": 1,
            "claim": "Zero divides", "severity": "High", "reasoning": "SECRET reasoning",
            "evidence": "SECRET evidence", "suggestedFix": "SECRET fix"}


def running():
    state = workflow.new_state("run-1", "codex", prepared(), policies())
    state, _ = transition(state, "start")
    for role, handle in [("code-reviewer", "code-worker"), ("security-reviewer", "security-worker")]:
        state, _ = transition(state, "spawned", requestId=state["workers"][role]["request"]["requestId"],
                              workerId=handle)
    return state


class WorkflowTests(unittest.TestCase):
    def test_verifier_context_is_allowlisted(self):
        finding = {"id": "code-reviewer:1", "title": "Bound", "file": "a.py",
                   "line": 1, "claim": "Zero divides", "reasoning": "SECRET",
                   "evidence": "SECRET", "suggestedFix": "SECRET", "severity": "High"}
        self.assertEqual(claims_for_verifier([finding]), [{
            "id": "code-reviewer:1", "title": "Bound", "file": "a.py", "line": 1,
            "claim": "Zero divides"}])

    def test_start_dispatches_both_reviewers_and_leaves_verifier_pending(self):
        state = workflow.new_state("run-1", "codex", prepared(), policies())
        original = deepcopy(state)
        self.assertEqual((state["generation"], state["status"]), (0, "pending"))
        updated, actions = transition(state, "start")
        self.assertEqual(state, original)
        self.assertEqual((updated["generation"], updated["status"]), (1, "reviewing"))
        self.assertEqual([a["kind"] for a in actions], ["spawn", "spawn"])
        self.assertEqual([a["request"]["role"] for a in actions], ["code-reviewer", "security-reviewer"])
        self.assertEqual(updated["workers"]["review-verifier"]["status"], "pending")
        ids = {item["request"]["requestId"] for item in updated["workers"].values()}
        self.assertEqual(len(ids), 3)
        self.assertEqual(updated["eventIds"], ["event-1"])

    def test_join_waits_for_both_reviewers_in_either_order_even_without_claims(self):
        for order in [("code-reviewer", "security-reviewer"), ("security-reviewer", "code-reviewer")]:
            for findings in [[], [finding(order[0])]]:
                with self.subTest(order=order, findings=findings):
                    state = running()
                    self.assertEqual(state["workers"]["code-reviewer"]["workerId"], "code-worker")
                    state, actions = transition(state, "result", result=result_for(state, order[0], findings=findings))
                    self.assertEqual(actions, [])
                    self.assertEqual(state["status"], "reviewing")
                    state, actions = transition(state, "result", result=result_for(state, order[1]))
                    self.assertEqual(state["status"], "verifying")
                    self.assertEqual(len(actions), 1)
                    self.assertEqual((actions[0]["kind"], actions[0]["request"]["role"]), ("spawn", "review-verifier"))
                    self.assertEqual(actions[0]["request"]["inputs"], [
                        {"name": "claims", "path": "/scratch/run/inputs/claims", "required": True}])
                    self.assertNotIn("SECRET", str(state["claims"]))

    def test_verifier_dispositions_complete_review_with_defects(self):
        state = running()
        state, _ = transition(state, "result", result=result_for(state, "code-reviewer", findings=[finding()]))
        state, actions = transition(state, "result", result=result_for(state, "security-reviewer"))
        state, _ = transition(state, "spawned", requestId=actions[0]["request"]["requestId"], workerId="verifier-worker")
        state, actions = transition(state, "result", result=result_for(state, "review-verifier", dispositions=[
            {"id": "code-reviewer:1", "verdict": "confirmed", "reason": "Caller supplies zero"}]))
        self.assertEqual((state["status"], actions), ("completed", [{"kind": "report"}]))
        self.assertEqual(state["dispositions"][0]["verdict"], "confirmed")

    def test_failure_traces_cancel_live_workers_and_never_spawn_verifier(self):
        for kind, status, handles in [
            ("result", "failed", ["security-worker"]),
            ("timeout", "timed-out", ["code-worker", "security-worker"]),
            ("lost-session", "failed", ["code-worker", "security-worker"]),
            ("cancel", "cancelled", ["code-worker", "security-worker"]),
        ]:
            with self.subTest(kind=kind):
                state = running()
                payload = ({"result": result_for(state, "code-reviewer", "failed")} if kind == "result"
                           else {"requestId": state["workers"]["security-reviewer"]["request"]["requestId"]}
                           if kind == "timeout" else {"reason": "native session ended"})
                updated, actions = transition(state, kind, **payload)
                self.assertEqual(updated["status"], status)
                self.assertEqual(actions, [{"kind": "cancel", "workerId": handle} for handle in handles]
                                 + [{"kind": "report"}])
                self.assertEqual(updated["cancellationUnconfirmed"], handles)
                self.assertEqual(updated["workers"]["review-verifier"]["status"], "pending")

    def test_late_spawn_is_cancelled_without_reopening_terminal_run(self):
        for kind in ("cancel", "lost-session"):
            with self.subTest(kind=kind):
                state = workflow.new_state("run-1", "codex", prepared(), policies())
                state, _ = transition(state, "start")
                state, _ = transition(state, kind, reason="controller gone")
                terminal = state["status"]
                req = state["workers"]["code-reviewer"]["request"]["requestId"]
                state, actions = transition(state, "spawned", requestId=req, workerId="late-worker")
                self.assertEqual(state["status"], terminal)
                self.assertEqual(actions, [{"kind": "cancel", "workerId": "late-worker"}])
                self.assertEqual(state["cancellationUnconfirmed"], ["late-worker"])
                state, actions = transition(state, "result", result=result_for(state, "code-reviewer", "cancelled"))
                self.assertEqual(state["status"], terminal)
                self.assertEqual(state["cancellationUnconfirmed"], [])
                self.assertEqual(actions, [{"kind": "report"}])

    def test_rejects_invalid_event_sequences_without_mutating_state(self):
        initial = workflow.new_state("run-1", "codex", prepared(), policies())
        started, _ = transition(initial, "start")
        active = running()
        finished, _ = transition(active, "result", result=result_for(active, "code-reviewer"))
        cancelled, _ = transition(active, "cancel", reason="cancelled")
        code_id = active["workers"]["code-reviewer"]["request"]["requestId"]
        bad_result = result_for(active, "code-reviewer")
        bad_result["evidence"]["workerId"] = "unknown-worker"
        wrong_head = result_for(active, "code-reviewer")
        wrong_head["revision"]["headSha"] = "c" * 40
        cases = [
            (initial, event(initial, "spawned", requestId=code_id, workerId="early-worker")),
            (started, event(started, "start")),
            (started, event(started, "result", result=result_for(active, "code-reviewer"))),
            (active, event(active, "spawned", requestId=code_id, workerId="twice-worker")),
            (active, event(active, "spawned", requestId="unknown", workerId="new-worker")),
            (active, event(active, "result", result=bad_result)),
            (active, event(active, "result", result=wrong_head)),
            (active, {**event(active, "cancel", reason="cancelled"), "runId": "run-2"}),
            (active, {**event(active, "cancel", reason="cancelled"), "eventId": "event-1"}),
            (active, event(active, "cancel", reason="cancelled", outputPath="/arbitrary")),
            (active, event(active, "retry")),
            (finished, event(finished, "result", result=result_for(active, "code-reviewer"))),
            (cancelled, event(cancelled, "cancel", reason="again")),
            (active, event(active, "timeout", requestId="unknown")),
        ]
        for state, value in cases:
            with self.subTest(event=value):
                original = deepcopy(state)
                with self.assertRaises(ValueError):
                    workflow.advance(state, value)
                self.assertEqual(state, original)

    def test_rejects_reused_native_handle_and_incomplete_verifier_coverage(self):
        state = workflow.new_state("run-1", "codex", prepared(), policies())
        state, _ = transition(state, "start")
        state, _ = transition(state, "spawned", requestId=state["workers"]["code-reviewer"]["request"]["requestId"],
                              workerId="same-worker")
        with self.assertRaisesRegex(ValueError, "workerId"):
            transition(state, "spawned", requestId=state["workers"]["security-reviewer"]["request"]["requestId"],
                       workerId="same-worker")
        state = running()
        state, _ = transition(state, "result", result=result_for(state, "code-reviewer", findings=[finding()]))
        state, actions = transition(state, "result", result=result_for(state, "security-reviewer"))
        state, _ = transition(state, "spawned", requestId=actions[0]["request"]["requestId"], workerId="verifier-worker")
        for dispositions in [[], [{"id": "unknown", "verdict": "dismissed", "reason": "No caller"}]]:
            with self.subTest(dispositions=dispositions), self.assertRaisesRegex(ValueError, "dispositions"):
                transition(state, "result", result=result_for(state, "review-verifier", dispositions=dispositions))

    def test_duplicate_finding_ids_within_a_reviewer_are_rejected(self):
        state = running()
        with self.assertRaisesRegex(ValueError, "finding.*unique"):
            transition(state, "result", result=result_for(state, "code-reviewer", findings=[finding(), finding()]))

    def test_controller_namespaces_equal_local_ids_without_changing_raw_envelopes(self):
        state = running()
        for role in ("code-reviewer", "security-reviewer"):
            state, _ = transition(state, "result", result=result_for(state, role, findings=[{**finding(role), "id": "1"}]))
        self.assertEqual([item["id"] for item in state["claims"]], ["code-reviewer:1", "security-reviewer:1"])
        self.assertEqual(state["workers"]["code-reviewer"]["result"]["output"]["findings"][0]["id"], "1")

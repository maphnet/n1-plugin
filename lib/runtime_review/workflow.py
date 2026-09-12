"""Pure advisory-review transitions; native adapters execute returned actions."""

from copy import deepcopy
from pathlib import PurePosixPath
from uuid import NAMESPACE_URL, uuid5

from .contract import CAPABILITIES, STATUSES, _identifier, _keys, _object, _text, validate_request, validate_result


REVIEWERS = ("code-reviewer", "security-reviewer")
ROLES = (*REVIEWERS, "review-verifier")
TERMINAL = STATUSES


def claims_for_verifier(findings: list[dict]) -> list[dict]:
    keys = ("id", "title", "file", "line", "claim")
    return [{key: item[key] for key in keys} for item in findings]


def new_state(run_id: str, host: str, prepared: dict, policies: dict) -> dict:
    workers = {}
    for role in ROLES:
        inputs = prepared["inputs"]
        if role == "review-verifier":
            inputs = [{"name": "claims", "path": str(PurePosixPath(inputs[0]["path"]).parent / "claims"),
                       "required": True}]
        request = validate_request({
            "schemaVersion": 1, "runId": run_id,
            "requestId": str(uuid5(NAMESPACE_URL, run_id + "/" + role)),
            "host": host, "role": role, "cwd": prepared["cwd"], "inputs": inputs,
            "revision": prepared["revision"], "modelPolicy": policies[role],
            "requiredCapabilities": sorted(CAPABILITIES),
        })
        workers[role] = {"request": request, "status": "pending", "workerId": None, "result": None}
    return deepcopy({"runId": run_id, "host": host, "generation": 0, "status": "pending",
                     "revision": prepared["revision"], "prNumber": prepared["prNumber"],
                     "prTitle": prepared["prTitle"], "workers": workers, "eventIds": [],
                     "findings": [], "claims": [], "dispositions": [],
                     "cancellationUnconfirmed": [], "reason": None})


def _worker(state, request_id):
    _identifier(request_id, "requestId")
    for worker in state["workers"].values():
        if worker["request"]["requestId"] == request_id:
            return worker
    raise ValueError("requestId is unknown for this run")


def _cancel_worker(state, worker):
    worker["status"] = "cancel-requested"
    state["cancellationUnconfirmed"].append(worker["workerId"])
    return {"kind": "cancel", "workerId": worker["workerId"]}


def _fail(state, status, reason):
    state["status"], state["reason"] = status, reason
    actions = [_cancel_worker(state, worker) for worker in state["workers"].values()
               if worker["workerId"] is not None and worker["status"] not in TERMINAL]
    return actions + [{"kind": "report"}]


def _accept_result(state, worker, result):
    if worker["status"] not in {"running", "cancel-requested"}:
        raise ValueError("result requires a spawned nonterminal worker")
    if result["evidence"]["workerId"] != worker["workerId"]:
        raise ValueError("evidence.workerId must match spawned workerId")
    worker["result"], worker["status"] = result, result["status"]
    if state["status"] in TERMINAL:
        # A native terminal receipt confirms termination, but cannot restore a failed review.
        state["cancellationUnconfirmed"].remove(worker["workerId"])
        return [{"kind": "report"}]
    if result["status"] != "completed":
        return _fail(state, result["status"], result["error"]["message"])
    if result["role"] in REVIEWERS:
        findings = [{**finding, "id": role + ":" + finding["id"].removeprefix(role + ":")}
                    for role in REVIEWERS if state["workers"][role]["status"] == "completed"
                    for finding in state["workers"][role]["result"]["output"]["findings"]]
        if len({item["id"] for item in findings}) != len(findings):
            raise ValueError("finding IDs must be unique across reviewers")
        state["findings"] = findings
        if all(state["workers"][role]["status"] == "completed" for role in REVIEWERS):
            state["claims"] = claims_for_verifier(findings)
            verifier = state["workers"]["review-verifier"]
            verifier["status"] = "dispatched"
            state["status"] = "verifying"
            return [{"kind": "spawn", "request": deepcopy(verifier["request"])}]
        return []
    dispositions = result["output"]["dispositions"]
    if {item["id"] for item in dispositions} != {item["id"] for item in state["claims"]}:
        raise ValueError("dispositions must cover every claim exactly once")
    state["dispositions"] = dispositions
    state["status"] = "completed"
    return [{"kind": "report"}]


def advance(state: dict, event: dict) -> tuple[dict, list[dict]]:
    """Accept one observed event, without I/O, retries, or caller-owned mutations.

    Terminal runs only accept pending spawn receipts (immediately cancelled) and
    terminal results from cancellation targets. Adapters must send those native
    receipts; a cancellation action alone does not prove the worker stopped.
    """
    _object(event, "event")
    kind = event.get("kind")
    fields = {"start": set(), "spawned": {"requestId", "workerId"}, "result": {"result"},
              "timeout": {"requestId"}, "cancel": {"reason"}, "lost-session": {"reason"}}
    if type(kind) is not str or kind not in fields:
        raise ValueError("event.kind must be a known event")
    _keys(event, "event", {"eventId", "runId", "kind"} | fields[kind])
    _identifier(event["eventId"], "eventId")
    if event["runId"] != state["runId"]:
        raise ValueError("event.runId must match run")
    if event["eventId"] in state["eventIds"]:
        raise ValueError("eventId is duplicate")
    if state["status"] in TERMINAL and kind not in {"spawned", "result"}:
        raise ValueError("run is terminal")
    updated = deepcopy(state)
    actions = []
    if kind == "start":
        if updated["status"] != "pending":
            raise ValueError("start requires a pending run")
        updated["status"] = "reviewing"
        for role in REVIEWERS:
            worker = updated["workers"][role]
            worker["status"] = "dispatched"
            actions.append({"kind": "spawn", "request": deepcopy(worker["request"])})
    elif kind == "spawned":
        worker = _worker(updated, event["requestId"])
        _identifier(event["workerId"], "workerId")
        if worker["status"] != "dispatched":
            raise ValueError("spawned requires a dispatched request")
        if any(item["workerId"] == event["workerId"] for item in updated["workers"].values()):
            raise ValueError("workerId must be fresh for each request")
        worker["workerId"], worker["status"] = event["workerId"], "running"
        if updated["status"] in TERMINAL:
            actions.append(_cancel_worker(updated, worker))
    elif kind == "result":
        _object(event["result"], "result")
        worker = _worker(updated, event["result"].get("requestId"))
        result = validate_result(worker["request"], event["result"])
        actions = _accept_result(updated, worker, result)
    elif kind == "timeout":
        worker = _worker(updated, event["requestId"])
        if worker["status"] not in {"running", "dispatched"}:
            raise ValueError("timeout requires a dispatched nonterminal request")
        actions = _fail(updated, "timed-out", "request timed out: " + event["requestId"])
    else:
        _text(event["reason"], "event.reason")
        actions = _fail(updated, "cancelled" if kind == "cancel" else "failed", event["reason"])
    updated["generation"] += 1
    updated["eventIds"].append(event["eventId"])
    return updated, actions

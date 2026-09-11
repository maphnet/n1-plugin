"""Validation for versioned, host-neutral runtime-review messages.

These functions only validate the wire contract.  In particular, they do not
probe paths, infer host capabilities, or attempt to resolve a model.
"""

from copy import deepcopy
import re


HOSTS = {"claude-code", "codex", "pi"}
ROLES = {"code-reviewer", "security-reviewer", "review-verifier"}
STATUSES = {"completed", "failed", "cancelled", "timed-out", "unsupported"}
CAPABILITIES = {"readSearchEnforced", "isolatedContext", "lifecycleControl"}
SEVERITIES = {"critical", "high", "medium", "low"}
VERDICTS = {"confirmed", "dismissed"}
IDENTIFIER = re.compile(r"[A-Za-z0-9_-]{1,128}")
SHA = re.compile(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})")


def positive_int(value, field):
    if type(value) is not int or value <= 0:
        raise ValueError(field + " must be a positive integer")
    return value


def _object(value, field):
    if type(value) is not dict:
        raise ValueError(field + " must be an object")
    return value


def _keys(value, field, required, optional=()):
    _object(value, field)
    required = set(required)
    allowed = required | set(optional)
    missing = required - set(value)
    unexpected = set(value) - allowed
    if missing:
        raise ValueError(field + "." + sorted(missing)[0] + " is required")
    if unexpected:
        raise ValueError(field + "." + sorted(unexpected)[0] + " is unexpected")


def _identifier(value, field):
    if type(value) is not str or not IDENTIFIER.fullmatch(value):
        raise ValueError(field + " must be an identifier")
    return value


def _text(value, field):
    if type(value) is not str or not value:
        raise ValueError(field + " must be a nonempty string")
    return value


def _nullable_text(value, field):
    if value is not None:
        _text(value, field)
    return value


def _absolute_path(value, field):
    if type(value) is not str or not value.startswith("/"):
        raise ValueError(field + " must be an absolute path")
    return value


def _revision(value, field):
    _keys(value, field, {"repository", "baseSha", "headSha"})
    _text(value["repository"], field + ".repository")
    for name in ("baseSha", "headSha"):
        if type(value[name]) is not str or not SHA.fullmatch(value[name]):
            raise ValueError(field + "." + name + " must be a 40- or 64-character hexadecimal SHA")
    return value


def _model_policy(value, field):
    _keys(value, field, {"mode", "provider", "model", "effort"})
    if type(value["mode"]) is not str or value["mode"] not in {"inherit", "explicit"}:
        raise ValueError(field + ".mode must be inherit or explicit")
    for name in ("provider", "model", "effort"):
        _nullable_text(value[name], field + "." + name)
    if value["mode"] == "inherit":
        if any(value[name] is not None for name in ("provider", "model", "effort")):
            raise ValueError(field + " inherit must not include explicit model values")
    elif value["provider"] is None or value["model"] is None:
        raise ValueError(field + " explicit requires provider and model")
    return value


def validate_request(value: dict) -> dict:
    """Return a detached, schema-validated runtime-review request."""
    value = deepcopy(value)
    _keys(value, "request", {
        "schemaVersion", "runId", "requestId", "host", "role", "cwd", "inputs",
        "revision", "modelPolicy", "requiredCapabilities",
    }, {"timeoutSeconds"})
    if value["schemaVersion"] != 1 or type(value["schemaVersion"]) is not int:
        raise ValueError("schemaVersion must be 1")
    _identifier(value["runId"], "runId")
    _identifier(value["requestId"], "requestId")
    if type(value["host"]) is not str or value["host"] not in HOSTS:
        raise ValueError("host must be a known host")
    if type(value["role"]) is not str or value["role"] not in ROLES:
        raise ValueError("role must be a known role")
    _absolute_path(value["cwd"], "cwd")
    if type(value["inputs"]) is not list:
        raise ValueError("inputs must be a list")
    names = set()
    for index, item in enumerate(value["inputs"]):
        field = "inputs[{}]".format(index)
        _keys(item, field, {"name", "path", "required"})
        _identifier(item["name"], field + ".name")
        if item["name"] in names:
            raise ValueError(field + ".name must be unique")
        names.add(item["name"])
        _absolute_path(item["path"], field + ".path")
        if type(item["required"]) is not bool:
            raise ValueError(field + ".required must be a boolean")
    _revision(value["revision"], "revision")
    _model_policy(value["modelPolicy"], "modelPolicy")
    if type(value["requiredCapabilities"]) is not list:
        raise ValueError("requiredCapabilities must be a list")
    seen_capabilities = set()
    for index, capability in enumerate(value["requiredCapabilities"]):
        if type(capability) is not str or capability not in CAPABILITIES:
            raise ValueError("requiredCapabilities[{}] must be a known capability".format(index))
        if capability in seen_capabilities:
            raise ValueError("requiredCapabilities must not contain duplicates")
        seen_capabilities.add(capability)
    value["timeoutSeconds"] = positive_int(value.get("timeoutSeconds", 600), "timeoutSeconds")
    return deepcopy(value)


def _model_evidence(value, field):
    if value is None:
        return None
    _keys(value, field, {"provider", "model", "effort"})
    for name in ("provider", "model", "effort"):
        _nullable_text(value[name], field + "." + name)
    return value


def _model_observation(value, request):
    _keys(value, "modelObservation", {"requested", "effective", "reason"})
    requested = _model_evidence(value["requested"], "modelObservation.requested")
    effective = _model_evidence(value["effective"], "modelObservation.effective")
    reason = value["reason"]
    unknown_requested = requested is None or any(
        requested[name] is None for name in ("provider", "model")
    )
    unknown_effective = effective is None or any(
        effective[name] is None for name in ("provider", "model")
    )
    if unknown_requested or unknown_effective:
        _text(reason, "modelObservation.reason")
    elif reason is not None:
        _text(reason, "modelObservation.reason")
    expected_requested = {
        name: request["modelPolicy"][name] for name in ("provider", "model", "effort")
    }
    if requested is not None and requested != expected_requested:
        raise ValueError("modelObservation.requested must match modelPolicy")


def _finding(value, field):
    _keys(value, field, {"id", "severity", "path", "line", "message"})
    _identifier(value["id"], field + ".id")
    if type(value["severity"]) is not str or value["severity"] not in SEVERITIES:
        raise ValueError(field + ".severity must be a known severity")
    _absolute_path(value["path"], field + ".path")
    positive_int(value["line"], field + ".line")
    _text(value["message"], field + ".message")


def _review_output(value, field):
    _keys(value, field, {"summary", "findings"})
    _text(value["summary"], field + ".summary")
    if type(value["findings"]) is not list:
        raise ValueError(field + ".findings must be a list")
    ids = set()
    for index, finding in enumerate(value["findings"]):
        finding_field = field + ".findings[{}]".format(index)
        _finding(finding, finding_field)
        if finding["id"] in ids:
            raise ValueError(finding_field + ".id must be unique")
        ids.add(finding["id"])


def _verifier_output(value, field):
    _keys(value, field, {"summary", "verdicts"})
    _text(value["summary"], field + ".summary")
    if type(value["verdicts"]) is not list:
        raise ValueError(field + ".verdicts must be a list")
    ids = set()
    for index, verdict in enumerate(value["verdicts"]):
        verdict_field = field + ".verdicts[{}]".format(index)
        _keys(verdict, verdict_field, {"findingId", "verdict", "reason"})
        _identifier(verdict["findingId"], verdict_field + ".findingId")
        if verdict["findingId"] in ids:
            raise ValueError(verdict_field + ".findingId must be unique")
        ids.add(verdict["findingId"])
        if type(verdict["verdict"]) is not str or verdict["verdict"] not in VERDICTS:
            raise ValueError(verdict_field + ".verdict must be a known verdict")
        _text(verdict["reason"], verdict_field + ".reason")


def _error(value):
    _keys(value, "error", {"code", "message"})
    _identifier(value["code"], "error.code")
    _text(value["message"], "error.message")


def validate_result(request: dict, value: dict) -> dict:
    """Return a detached result after checking it against its request."""
    request = validate_request(request)
    value = deepcopy(value)
    _keys(value, "result", {
        "schemaVersion", "runId", "requestId", "host", "role", "revision", "status",
        "modelObservation", "output", "error",
    })
    if value["schemaVersion"] != request["schemaVersion"] or type(value["schemaVersion"]) is not int:
        raise ValueError("schemaVersion must match request")
    for name in ("runId", "requestId", "host", "role"):
        if value[name] != request[name]:
            raise ValueError(name + " must match request")
    _revision(value["revision"], "revision")
    if value["revision"] != request["revision"]:
        raise ValueError("revision must match request")
    if type(value["status"]) is not str or value["status"] not in STATUSES:
        raise ValueError("status must be a known status")
    _model_observation(value["modelObservation"], request)
    if value["status"] == "completed":
        if value["error"] is not None:
            raise ValueError("error must be null for completed results")
        if request["role"] in {"code-reviewer", "security-reviewer"}:
            _review_output(value["output"], "output")
        else:
            _verifier_output(value["output"], "output")
    else:
        if value["output"] is not None:
            raise ValueError("output must be null for noncompleted results")
        _error(value["error"])
    return deepcopy(value)

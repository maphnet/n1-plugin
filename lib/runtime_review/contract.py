"""Validation for versioned, host-neutral runtime-review messages.

These functions validate the wire contract and compare trusted native probe
observations. They do not probe paths, execute host tools, or resolve a model.
"""

from copy import deepcopy
import re


HOSTS = {"claude-code", "codex", "pi"}
ROLES = {"code-reviewer", "security-reviewer", "review-verifier"}
STATUSES = {"completed", "failed", "cancelled", "timed-out", "unsupported"}
CAPABILITIES = {"readSearchEnforced", "isolatedContext", "lifecycleControl"}
SEVERITIES = {"Critical", "High", "Medium", "Low"}
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
    if any(type(key) is not str for key in value):
        raise ValueError(field + " keys must be strings")
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
    expected_inputs = (
        {"claims"}
        if value["role"] == "review-verifier"
        else {"diff", "requirements", "conventions"}
    )
    if names != expected_inputs:
        raise ValueError("inputs must contain exactly the required artifacts for the role")
    if any(not item["required"] for item in value["inputs"]):
        raise ValueError("inputs required artifacts must be marked required")
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


def _evidence(value):
    _keys(value, "evidence", {
        "workerId", "requestedModel", "effectiveModel", "effectiveModelReason",
        "enforcement", "tokenUsage",
    })
    _identifier(value["workerId"], "evidence.workerId")
    _nullable_text(value["requestedModel"], "evidence.requestedModel")
    _nullable_text(value["effectiveModel"], "evidence.effectiveModel")
    if value["effectiveModel"] is None:
        _text(value["effectiveModelReason"], "evidence.effectiveModelReason")
    elif value["effectiveModelReason"] is not None:
        _text(value["effectiveModelReason"], "evidence.effectiveModelReason")
    # This is an adapter assertion retained for diagnostics.  Capability
    # qualification is deliberately performed only by controller preflight.
    _text(value["enforcement"], "evidence.enforcement")
    if value["tokenUsage"] is not None and type(value["tokenUsage"]) is not dict:
        raise ValueError("evidence.tokenUsage must be an object or null")


def _finding(value, field):
    _keys(value, field, {
        "id", "title", "file", "line", "claim", "severity", "reasoning", "evidence",
        "suggestedFix",
    })
    _text(value["id"], field + ".id")
    _text(value["title"], field + ".title")
    if type(value["file"]) is not str or not value["file"] or value["file"].startswith("/"):
        raise ValueError(field + ".file must be a relative path")
    positive_int(value["line"], field + ".line")
    _text(value["claim"], field + ".claim")
    if type(value["severity"]) is not str or value["severity"] not in SEVERITIES:
        raise ValueError(field + ".severity must be a known severity")
    _text(value["reasoning"], field + ".reasoning")
    _text(value["evidence"], field + ".evidence")
    _text(value["suggestedFix"], field + ".suggestedFix")


def _review_output(value, field):
    _keys(value, field, {"findings"})
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
    _keys(value, field, {"dispositions"})
    if type(value["dispositions"]) is not list:
        raise ValueError(field + ".dispositions must be a list")
    ids = set()
    for index, verdict in enumerate(value["dispositions"]):
        verdict_field = field + ".dispositions[{}]".format(index)
        _keys(verdict, verdict_field, {"id", "verdict", "reason"})
        _text(verdict["id"], verdict_field + ".id")
        if verdict["id"] in ids:
            raise ValueError(verdict_field + ".id must be unique")
        ids.add(verdict["id"])
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
        "evidence", "output", "error",
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
    _evidence(value["evidence"])
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


def _capability_observations(value, field):
    identity = {"host", "hostVersion", "packageDigest", "configurationDigest", "toolInventoryDigest"}
    _keys(value, field, identity | {"capabilities", "models", "reasons"})
    if type(value["host"]) is not str or value["host"] not in HOSTS:
        raise ValueError(field + ".host must be a known host")
    _text(value["hostVersion"], field + ".hostVersion")
    for name in ("packageDigest", "configurationDigest", "toolInventoryDigest"):
        if type(value[name]) is not str or not re.fullmatch(r"[0-9a-f]{64}", value[name]):
            raise ValueError(field + "." + name + " must be a SHA-256 digest")
    _keys(value["reasons"], field + ".reasons", set(), CAPABILITIES | ROLES)
    for name, reason in value["reasons"].items():
        _text(reason, field + ".reasons." + name)
    _keys(value["capabilities"], field + ".capabilities", set(), CAPABILITIES)
    for name in sorted(CAPABILITIES):
        label = field + ".capabilities." + name
        entry = value["capabilities"].get(name)
        reason = value["reasons"].get(name, "required native probe evidence is missing")
        if entry is None:
            raise ValueError(label + " is missing: " + reason)
        _keys(entry, label, {"status", "evidence"})
        if type(entry["status"]) is not str or entry["status"] not in {"available", "unavailable", "unverified"}:
            raise ValueError(label + ".status must be available, unavailable, or unverified")
        if type(entry["evidence"]) is not list:
            raise ValueError(label + ".evidence must be a list")
        for item in entry["evidence"]:
            _text(item, label + ".evidence")
        if entry["status"] != "available" or not entry["evidence"]:
            raise ValueError(label + " lacks available native evidence: " + reason)
    _keys(value["models"], field + ".models", ROLES)
    for role in sorted(ROLES):
        _model_policy(value["models"][role], field + ".models." + role)
    return identity


def validate_capabilities(report: dict, observed: dict) -> dict:
    """Match probe qualification against fresh, controller-collected native facts.

    Both inputs use the same strict shape. ``observed`` must originate from the
    native adapter, never reviewer prose. This comparison is not a host probe or
    a model availability check; adapters must execute those before prepare.
    """
    report, observed = deepcopy(report), deepcopy(observed)
    identity = _capability_observations(report, "report")
    _capability_observations(observed, "observed")
    for name in sorted(identity):
        if report[name] != observed[name]:
            raise ValueError(name + " changed; capability evidence is stale")
    for name in sorted(CAPABILITIES):
        if report["capabilities"][name] != observed["capabilities"][name]:
            raise ValueError("capabilities." + name + ".evidence does not match observed native evidence")
    for role in sorted(ROLES):
        if report["models"][role] != observed["models"][role]:
            raise ValueError("models." + role + " does not match observed model policy")
    return report

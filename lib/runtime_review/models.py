"""Resolution for advisory runtime-preview model policy.

This intentionally does not consult the legacy ``models.<persona>`` mapping,
or make any claim about a provider's installed models or native effort levels.
Adapters perform those host-specific checks.
"""

from copy import deepcopy

from .contract import HOSTS, ROLES


_POLICY_FIELDS = {"mode", "provider", "model", "effort"}


def _object(value, field):
    if type(value) is not dict:
        raise ValueError(field + " must be an object")
    return value


def _keys(value, field, allowed, required=()):
    _object(value, field)
    missing = set(required) - set(value)
    unexpected = set(value) - set(allowed)
    if missing:
        raise ValueError(field + "." + sorted(missing)[0] + " is required")
    if unexpected:
        raise ValueError(field + "." + sorted(unexpected)[0] + " is unexpected")


def _optional_text(value, field):
    if value is not None and (type(value) is not str or not value):
        raise ValueError(field + " must be a nonempty string or null")
    return value


def _missing_policy(host, role):
    raise ValueError(
        "runtimePreview.hosts.{}.models.{} must be explicit: choose inherit or explicit".format(
            host, role
        )
    )


def resolve_policy(config: dict, host: str, role: str) -> dict:
    """Return a detached, normalized policy for one preview host and role."""
    if type(host) is not str or host not in HOSTS:
        raise ValueError("host must be a known host")
    if type(role) is not str or role not in ROLES:
        raise ValueError("role must be a known role")
    _object(config, "config")
    preview = config.get("runtimePreview")
    if preview is None:
        _missing_policy(host, role)
    _keys(preview, "runtimePreview", {"hosts"}, {"hosts"})
    hosts = preview["hosts"]
    _object(hosts, "runtimePreview.hosts")
    unknown_hosts = set(hosts) - HOSTS
    if unknown_hosts:
        raise ValueError("runtimePreview.hosts.{} is unexpected".format(sorted(unknown_hosts)[0]))
    host_config = hosts.get(host)
    if host_config is None:
        _missing_policy(host, role)
    host_field = "runtimePreview.hosts." + host
    _keys(host_config, host_field, {"models"}, {"models"})
    models = host_config["models"]
    _object(models, host_field + ".models")
    unknown_roles = set(models) - ROLES
    if unknown_roles:
        raise ValueError(host_field + ".models.{} is unexpected".format(sorted(unknown_roles)[0]))
    policy = models.get(role)
    if policy is None:
        _missing_policy(host, role)
    field = host_field + ".models." + role
    _keys(policy, field, _POLICY_FIELDS, {"mode"})
    mode = policy["mode"]
    if type(mode) is not str or mode not in {"inherit", "explicit"}:
        raise ValueError(field + ".mode must be inherit or explicit")
    values = {name: policy.get(name) for name in ("provider", "model", "effort")}
    for name, value in values.items():
        _optional_text(value, field + "." + name)
    if mode == "inherit":
        if any(value is not None for value in values.values()):
            raise ValueError(field + " inherit must not include explicit model values")
    elif values["provider"] is None or values["model"] is None:
        raise ValueError(field + " explicit requires provider and model")
    return deepcopy({"mode": mode, **values})

# Codex advisory preview adapter

## Selected host observations

Observed Codex CLI `0.154.0` on 2026-09-12. The package validator accepts the
scaffolded package. An installed-host `codex --strict-config ... doctor` probe
loaded each custom-agent TOML through `agents.<name>.config_file` without
starting a model session. These templates intentionally omit `model`,
`model_provider`, and `model_reasoning_effort`: that is explicit inheritance at
package time, because the shared T4 request owns policy and a disposable
qualification installer must render its resolved values using those supported
keys. The probe does not demonstrate the effective values.

The native collaboration surface available to this controller exposes generic
agent spawning, waiting, and interruption, but no observed argument binds a
spawn to one of these custom-agent profiles. Spawned agents inherit the
parent's tools and can spawn nested agents, and model/effort arguments can
override inherited settings. The role `sandbox_mode = "read-only"` is therefore
only a default: it does not remove inherited shell/MCP/connector/dynamic-
discovery/delegation surfaces or prove that parent permission/configuration
overrides are absent.

No live or paid native call was authorized. The installed host was not placed
in a disposable qualification environment, no plugin or role was installed,
and no hook was trusted. Consequently there are no observed dispatch returns,
wait results, cancellation results, tool-denial receipts, hook-failure
receipts, disabled-trust receipts, fresh-context receipts, or effective
model/provider/effort observations. The adapter is **unsupported** and must not
dispatch. `qualification.json` is the package-owned current record, and
`preflight.py` rejects the preview before the shared bridge can receive
caller-supplied capability evidence.

## Mapping after disposable qualification

Qualification must first identify and record a supported role/profile binding
that selects each exact packaged custom-agent profile. A generic spawn with a
descriptive label is not a binding and is never a fallback. Only after that
binding is proven may each initial T4 spawn action start the two roles
independently, register each returned handle, and submit both `spawned` events
before the first wait. Wait within the request's 600-second deadline. Submit
only observed completion/error data and preserve the exact native response as
`rawText`; never synthesize a completed envelope. Execute every T4 cancel action
through the separately qualified native interruption operation and await a
terminal receipt. Run the verifier only for a returned verifier spawn action,
using its proven profile binding in a fresh nonforked context. A report action
maps only to the existing shared CLI's controller-rendered local report.

Exact native arguments and results cannot be recorded until Task 9 exercises
the package in an authorized disposable environment. If dispatch, wait,
cancellation, context isolation, hook ordering/trust, path policy, inherited
surface removal, or effective policy observation is absent, the qualification
must record the actual failure and remain unsupported.

## Reader and hook boundary

Codex workers currently require a shell bridge for bounded reads. The hook
allows only canonical `/absolute/python /absolute/reader.py read|search VALUE`
commands; canonical equality rules out shell operators, redirects, environment
prefixes, extra arguments, and unquoted substitutions. The controller supplies
`N1_REVIEW_POLICY` and `N1_REVIEW_POLICY_DIGEST` outside the checked command.
The reader validates a read-only, nonsymlink policy containing one source root
and explicit read-only input paths, rejects absolute/traversing model paths,
maps those inputs only to `inputs/<basename>`, and does not expose the
controller CLI's `--root` form.

`hooks/hooks.json` remains empty. Plugin hooks require review/trust, and the
selected host has not proven a package hook can be scoped to only these workers
with controller-bound executable, reader, and policy values before their first
tool call. Registering the hook globally would alter unrelated Codex behavior;
registering it without proven worker identity would fail open. Either state
blocks support. No hook-trust or sandbox bypass flag is permitted.

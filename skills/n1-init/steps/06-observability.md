<!-- Purpose: Discover and configure observability MCP servers (Sentry, Loki, Langfuse, kubectl). -->

## Observability Configuration

Detect available observability MCP servers via dynamic discovery — scan all connected MCP servers, classify by observability category, infer environments from server names, and present a confidence-ranked selection list.

### Step 1 — Discovery

Enumerate all available MCP tools from the tool list (on hosts with deferred tools, search for `mcp__` first, per HOST ROUTING). Group tools by their MCP server prefix (the segment between `mcp__` and the next `__`). This produces a map of server name → list of tool names.

### Step 2 — Classification

For each server, match its tool names against the signature table:

| Category | Tool name patterns | Known providers |
|----------|-------------------|-----------------|
| Error tracking | `*sentry*`, `*error*issue*`, `*exception*` | Sentry |
| Log querying | `*loki*`, `*log*query*` | Loki |
| Tracing/APM | `*trace*`, `*observation*`, `*session*` combined with `*exception*` | Langfuse |

A server matches a category when 2+ of its tools hit any of the patterns for that category. Each tool counts at most once regardless of how many patterns it matches. This threshold prevents false positives from servers that happen to have one tool with a matching name.

Known provider names are also checked against the server name (e.g., server name contains "sentry" → Sentry).

### Step 3 — Environment inference

Parse the MCP server name for environment tokens by splitting on `-` and matching:

- Tokens: `dev`, `prod`, `production`, `staging`, `stg`, `stage`, `local`, `test`
- Examples: `publius-dev-loki-mcp` → `dev`, `publius-prod-loki-mcp` → `prod`, `publius-sentry` → `all`
- No token match → mark as `all` (single-MCP-for-all-envs)

### Step 4 — Confidence scoring

| Score | Criteria |
|-------|----------|
| high | Known provider exact match (server name contains the provider name AND tools match the signature) |
| medium | Category match via tool patterns but not a known provider name |
| low | Few matching tools or ambiguous pattern overlap |

Sort candidates descending by confidence.

### Step 5 — Present to user

**If no candidates detected:** set `"observability": null` silently and skip this section.

**If candidates detected:**

```
Observability MCP servers detected:

  1. [high]   sentry (publius-sentry) — error tracking, all envs
  2. [high]   loki (publius-dev-loki-mcp) — log querying, dev
  3. [high]   loki (publius-prod-loki-mcp) — log querying, prod
  4. [medium] langfuse (publius-dev-langfuse-mcp) — tracing/APM, dev

Select which to enable (comma-separated numbers, or 0 to skip):
```

**If 0 or no selection:**
```json
{
  "observability": null
}
```

### Step 6 — Environment tagging

For servers marked `all` (no env in name), ask:

```
What environment does <provider> (<mcp-server>) serve?
1 — All environments (global — always active)
2 — prod
3 — dev
4 — Enter custom name
```

When the user picks option 1 (global), the provider gets no `env` field — making it always active regardless of `observability.default`.

For options 2-4, the provider gets `"env": "<chosen value>"`.

For servers with inferred environments (e.g., `publius-prod-loki-mcp` → `prod`), the inference is shown in the Step 5 list and the user's selection implicitly confirms it. Tag with `"env": "<inferred env>"`.

### Step 7 — Sentry intake fields

When a Sentry provider is among the selected servers:

1. Call `mcp__<detected-sentry-mcp>__list_projects` to get the project list.
2. Present selection — number each project, plus a manual-entry option:
   ```
   Select Sentry project:
   1 — my-backend (my-org)
   2 — my-frontend (my-org)
   3 — Enter manually
   ```
   - If numbered option: extract `orgSlug` and `projectSlug` from the selected project.
   - If "Enter manually": ask for `orgSlug` and `projectSlug` separately.
3. Auto-generate `urlPattern`: `sentry\\.io/issues/|<orgSlug>\\.sentry\\.io/issues/`
4. Store these intake fields on the Sentry provider entry alongside `mcp` and `operations`:
   ```json
   {
     "sentry": {
       "mcp": "publius-sentry",
       "operations": { "searchIssues": "search_sentry_issues" },
       "urlPattern": "sentry\\.io/issues/|my-org\\.sentry\\.io/issues/",
       "orgSlug": "my-org",
       "projectSlug": "my-backend"
     }
   }
   ```

### Step 8 — Auto-detect operations

For known providers, use preset operation maps:

| Provider | Key operations |
|----------|---------------|
| Sentry | `searchIssues=search_sentry_issues`, `getIssue=get_sentry_issue`, `getAiAnalysis=get_autofix_state`, `listProjects=list_projects` |
| Loki | `query=loki_query`, `labelNames=loki_label_names`, `labelValues=loki_label_values` |
| Langfuse | `findExceptions=find_exceptions`, `fetchTraces=fetch_traces`, `getSessionDetails=get_session_details` |

For unknown providers (discovered generically), store all tools that matched the observability category patterns as operations.

### Step 8b — Auto-generate instructions

For each selected provider, generate a default `instructions` string based on the provider type:

| Provider | Default instructions |
|----------|---------------------|
| Sentry | `"Search Sentry for errors related to the task. Use project slug '<projectSlug>', org '<orgSlug>'."` (substitute actual values from Step 7; omit the slug clause if no intake fields) |
| Loki | `"Query Loki for application logs. Filter by app label matching the service name."` |
| Langfuse | `"Query Langfuse for traces, sessions, and exceptions related to the task."` |
| Unknown | `"Query <provider-name> via MCP for observability data related to the task."` |

Present the generated instructions for confirmation:
```
Generated instructions for selected providers:
  sentry: "Search Sentry for errors related to the task. Use project slug 'publius', org 'publius-bb'."
  loki-prod: "Query Loki for application logs. Filter by app label matching the service name."

Edit any? Enter provider name to edit, or Enter to accept all:
```

If the user enters a provider name, let them type replacement instructions text. Repeat until Enter.

### Step 8c — Kubectl log access (optional)

Ask:
```
Add kubectl-based log access?
1 — Yes
2 — No (default)
```

**If 1 (Yes):**

Ask: `"Kube context name for log access? (e.g., observability)"`

Ask: `"Default namespace? (Enter for dynamic — discover with kubectl get ns)"`

Generate provider entry:
- Provider key: `k8s-logs`
- `context`: the entered context name
- `instructions`: `"Use kubectl --context <context> to query pod logs. <namespace clause>. Look for pods matching the service name."`
  - If a default namespace was given: namespace clause = `"Service runs in the '<namespace>' namespace"`
  - If dynamic: namespace clause = `"Discover namespaces with 'kubectl get ns'"`

Show the generated entry for confirmation:
```
kubectl provider:
  k8s-logs:
    context: observability
    instructions: "Use kubectl --context observability to query pod logs. Discover namespaces with 'kubectl get ns'. Look for pods matching the service name."

Accept? 1 — Yes / 2 — Edit instructions / 3 — Skip
```

If 2: let the user type replacement instructions. If 3: discard this provider.

### Step 9 — Set default environment and confirm

Pick the default from env-tagged providers: the `env` value with the most providers. If tied, prefer `prod`. If all providers are global (no `env` field), omit `observability.default`.

**Provider naming rule:** When the same provider type appears in multiple envs (e.g., Loki in prod and dev), use `<type>-<env>` as the key (e.g., `loki-prod`, `loki-dev`). Single-env providers keep their base name (e.g., `sentry`).

**Ask about additional MCP servers:**

```
Add another observability MCP server not in the list? Enter MCP server name (or Enter to skip):
```

If entered: probe to identify provider type from the tool list, ask which env it serves, detect operations, generate instructions, add to providers. Repeat until Enter.

**Confirm summary:**

```
Observability integration:
  Default: prod
  Providers:
    sentry [prod] → publius-sentry (searchIssues)
    loki-prod [prod] → publius-prod-loki-mcp (query, labelNames, labelValues)
    langfuse-dev [dev] → publius-dev-langfuse-mcp (findExceptions, fetchTraces)
    k8s-logs [global] → kubectl --context observability
```

Result config block:
```json
{
  "observability": {
    "default": "prod",
    "providers": {
      "sentry": {
        "env": "prod",
        "mcp": "publius-sentry",
        "operations": { "searchIssues": "search_sentry_issues" },
        "instructions": "Search Sentry for errors related to the task. Use project slug 'my-backend', org 'my-org'.",
        "urlPattern": "sentry\\.io/issues/|my-org\\.sentry\\.io/issues/",
        "orgSlug": "my-org",
        "projectSlug": "my-backend"
      },
      "loki-prod": {
        "env": "prod",
        "mcp": "publius-prod-loki-mcp",
        "operations": { "query": "loki_query", "labelNames": "loki_label_names", "labelValues": "loki_label_values" },
        "instructions": "Query Loki for application logs. Filter by app label matching the service name."
      },
      "langfuse-dev": {
        "env": "dev",
        "mcp": "publius-dev-langfuse-mcp",
        "operations": { "findExceptions": "find_exceptions", "fetchTraces": "fetch_traces", "getSessionDetails": "get_session_details" },
        "instructions": "Query Langfuse for traces, sessions, and exceptions related to the task."
      },
      "k8s-logs": {
        "context": "observability",
        "instructions": "Use kubectl --context observability to query pod logs. Discover namespaces with 'kubectl get ns'. Look for pods matching the service name."
      }
    }
  }
}
```

### Migration from `environments` format

**Gate:** Only when `observability.environments` exists in config but `observability.providers` does not.

Auto-migration logic during n1-init:

1. **Flatten providers:** For each `environments.<env>.<provider>` entry, create a top-level provider:
   - Provider key: `<provider>` if it appears in only one env, `<provider>-<env>` if multiple envs.
   - Copy `mcp`, `operations`, and all extra fields (`urlPattern`, `orgSlug`, `projectSlug`).
   - Add `"env": "<env>"`.
   - Auto-generate `instructions` using the provider-type templates from Step 8b.

2. **Preserve default:** Set `observability.default` from the old `observability.default`.

3. **Write new format:** Replace `observability.environments` with `observability.providers`.

4. **Present:** Show the migrated config for confirmation:
   ```
   Migrated observability config from environments to providers format:

   Providers:
     sentry [prod] → publius-sentry
     loki-prod [prod] → publius-prod-loki-mcp
     loki-dev [dev] → publius-dev-loki-mcp

   1 — Accept
   2 — Edit (re-run full observability setup)
   ```

### Migration from `errorTracking` + `logging`

**Gate:** Only when old blocks exist (`errorTracking` and/or `logging` are present and not null) but no `observability` block exists.

Same auto-migration logic as the current n1-init (convert to `observability` block), but write the flat `providers` format instead of `environments`. Follow the provider-type templates from Step 8b for auto-generating `instructions`. Each provider entry gets an `"env"` tag from its source environment.

Clean up: remove old `errorTracking` and `logging` blocks from config.

### On reconfiguration (n1-init re-run):

If `observability` already exists and is not null:
```
Current observability:
  Default: prod
  Providers:
    sentry [prod]: Search Sentry for errors...
    loki-prod [prod]: Query Loki for application logs...
    k8s-logs [global]: Use kubectl --context observability...

1 — Keep current
2 — Add/remove providers
3 — Change default environment
4 — Edit provider instructions
5 — Disable
```

- **1** — leave unchanged.
- **2** — re-run MCP discovery (Steps 1–4). Show results with status labels:
  ```
  Observability MCP servers detected:

    1. [configured] sentry (publius-sentry) — error tracking, prod
    2. [configured] loki (publius-prod-loki-mcp) — log querying, prod
    3. [new]        langfuse (publius-dev-langfuse-mcp) — tracing/APM, dev

  Add new providers (comma-separated numbers), or remove existing ones?
  Type + followed by numbers to add, - followed by numbers to remove, or Enter to keep as-is:
  ```
  Also offer: `"Add kubectl-based log access? 1 — Yes / 2 — No"` (run Step 8c).
  Adding follows env tagging → instructions generation → operations flow. Removing deletes the provider entry.
- **3** — select from configured env values.
- **4** — show each provider with its current instructions, ask which to edit. Let the user type replacement text.
- **5** — set `"observability": null`.

If `observability` is `null` or absent (and no old blocks to migrate), re-run detection from scratch (Steps 1–9).

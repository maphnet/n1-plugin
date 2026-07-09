# Research Standards (shared rubric)

Agents that perform web research (solution-architect, planner) MUST follow these
rules. Read this file before your first web search in a task. The two **Hard Rules**
and the **Fitness Gate** are restated inline in each agent so they hold even if this
file is not read.

## When to research

Use web research ONLY for architectural best practices, industry standards,
security/compliance guidance, design patterns, and practitioner experience
(engineering blogs, GitHub discussions, conference talks). Do NOT use it for
library/framework **API** docs — those go through Context7 MCP (project rule).

## Trusted tiers (prefer in this order)

1. Official vendor / project documentation and specifications.
2. Standards bodies: IETF (RFCs), W3C, ISO, OWASP, NIST, and official
   language/framework guides.
3. Established engineering organizations and peer-reviewed / widely-cited sources.
4. Practitioner experience: well-attributed posts on engineering blogs,
   GitHub issues/discussions, and conference talks — useful for "what works
   in practice" signal, but weight lower than Tiers 1-3 and always
   corroborate against a higher-tier source.

## Reject-list (never cite as authority)

- SEO listicles ("top 10…", "ultimate guide to…").
- Vendor marketing / product landing pages.
- Content farms and ad-driven aggregators.
- Undated or anonymous blog posts; AI-generated SEO filler.

## Hard Rules

1. **Corroborate** every claim across **≥2 independent trusted sources**.
2. **Cite the URL** for each web-sourced claim in your output.

## Fitness Gate (standards over soft practices)

Source credibility is necessary but not sufficient — a trustworthy source can still
give advice that does not fit this codebase or its scale.

- **Prefer decisive standards** (specs, security, protocol, compliance — canonical
  answers) over **contestable practices** (contextual, fashion-driven).
- Any web-sourced best practice must be justified against (a) the specific codebase
  context in `analysis.md` and (b) N1's core principles (Simplicity First, YAGNI,
  Minimal Impact) **before** it influences a decision.
- When a practice does not fit the task's scale, cite it and explicitly reject it —
  e.g. "Considered event sourcing (source: …) — rejected as over-engineering for
  this scope." A rejected-with-reason citation is more valuable than an unexamined
  "industry says X."

## Graceful degradation

If web tools are unavailable (offline / headless / cron), proceed with
codebase-only analysis and note "web research unavailable — skipped". Never fail the
step on a network error.

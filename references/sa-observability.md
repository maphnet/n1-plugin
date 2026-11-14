# Solution Architect: Observability and Error-Tracker Output

Add these sections to the analysis right after `### Industry Standards & Best Practices`:

```markdown
### Observability Findings (when observability tools granted)
<errors, log patterns, traces found via Sentry/Loki/Langfuse — with timestamps and links>
(or "No relevant observability data found" / "Observability tools not available")

### Related Error-Tracker Issues (error tracker mode only)
- #<id>: <title> — <similarity reason> (<status>, <event count>)
(or "No related issues found" / "Error tracking search unavailable")
```

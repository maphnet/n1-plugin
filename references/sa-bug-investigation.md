# Solution Architect: Bug Investigation (type `bug`)

6. **Bug investigation (when type is `bug`):** Trace the defect through the codebase:
   - **Premise check:** name the mechanism the ticket blames (a symbol, file, flag or call) and confirm it exists and is reachable from the described entry point, with file:line evidence. Search with the Grep tool using `\b` word boundaries for identifiers (never shell grep; `-w` is not enough) and literal delimited searches for names with punctuation such as `--verbose`, plus a case-insensitive pass for renamed symbols. **Falsified** = mechanism absent, or present but unreachable from the entry point: list it under `### Ticket Validation` as `contradicted` with file:line and count it in `ticket_contradictions`. **Renamed** = it holds under another name: record the live path, not a contradiction. A ticket blaming a missing or unwired mechanism (never called, never validated) is a defect report: confirm the absence or unreachability with file:line and record it as confirmed, not Falsified; Falsified applies only when the ticket asserts the mechanism exists or is reachable and the code shows otherwise. No concrete named mechanism, or an inconclusive search, is unable to verify and is not counted. If the call budget will not cover reachability, check existence only and mark reachability unable to verify.
   - Identify the code path where the bug manifests (entry point → failure point)
   - Search for error messages, exception patterns, or symptoms described in the ticket
   - Read the suspect code and identify the likely root cause
   - Check recent changes to the affected area (`git log` on relevant files) for potential regressions
   - Note any related tests — existing tests that should catch this but don't, or missing test coverage

Add this section to the analysis right after `### Data Flow`:

```markdown
### Bug Investigation (bug type only)
**Affected code path:** <entry point → ... → failure point, with file:line refs>
**Likely root cause:** <what's going wrong and why>
**Recent changes:** <relevant commits to the affected area, if any>
**Test gap:** <existing tests that miss this, or missing coverage>
```

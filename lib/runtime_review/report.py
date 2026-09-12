"""Local advisory Markdown; execution completion is distinct from approval."""

import html
import re


def _text(value):
    # Model/source fields remain a single escaped inline value. In particular,
    # neither ATX/setext headings, raw HTML, nor fenced blocks can create sections.
    value = " ".join(str(value).split())
    value = html.escape(value, quote=True)
    return re.sub(r"([\\`*_{}\[\]()#+.!|>=~-])", r"\\\1", value)


def render_report(state: dict) -> str:
    findings = state.get("findings", [])
    dispositions = state.get("dispositions", [])
    by_id = {item["id"]: item for item in dispositions}
    confirmed = [item for item in findings if by_id.get(item["id"], {}).get("verdict") == "confirmed"]
    dismissed = [item for item in findings if by_id.get(item["id"], {}).get("verdict") == "dismissed"]
    workers = state.get("workers")
    complete = (state.get("status") == "completed" and not state.get("cancellationUnconfirmed")
                and len(by_id) == len(dispositions) == len(findings)
                and len(confirmed) + len(dismissed) == len(findings)
                and type(workers) is dict
                and all(type(workers.get(role)) is dict
                        and workers[role].get("status") == "completed"
                        and workers[role].get("result") is not None
                        for role in ("code-reviewer", "security-reviewer", "review-verifier")))
    assessment = ("request changes" if confirmed else "approve" if complete
                  else "needs discussion — incomplete review")
    revision = state["revision"]
    lines = ["# Advisory review", "",
             "PR: " + _text(state.get("prNumber", "unknown")) + " — " + _text(state.get("prTitle", "")),
             "Repository: " + _text(revision["repository"]),
             "Reviewed base: " + _text(revision["baseSha"]),
             "Reviewed head: " + _text(revision["headSha"]), ""]
    for severity in ("Critical", "High", "Medium", "Low"):
        lines.extend(["## " + severity, ""])
        group = [item for item in confirmed if item["severity"] == severity]
        if not group:
            lines.extend(["None.", ""])
        for item in group:
            lines.extend(["- " + _text(item["title"]) + " (" + _text(item["file"]) + ":" + str(item["line"]) + ")",
                          "  Claim: " + _text(item["claim"]),
                          "  Reasoning: " + _text(item["reasoning"]),
                          "  Evidence: " + _text(item["evidence"]),
                          "  Suggested fix: " + _text(item["suggestedFix"]),
                          "  Verification: " + _text(by_id[item["id"]]["reason"]), ""])
    lines.extend(["## Dismissed (False Positives)", ""])
    if not dismissed:
        lines.extend(["None.", ""])
    for item in dismissed:
        lines.extend(["- " + _text(item["title"]) + ": " + _text(by_id[item["id"]]["reason"]), ""])
    lines.extend(["## Summary", "", "Assessment: " + assessment,
                  "Execution: " + _text(state.get("status", "unknown")),
                  "Confirmed: " + str(len(confirmed)) + "; dismissed: " + str(len(dismissed)) + ".", "",
                  "Evidence limitations: read/search only; project code and tests were not executed."])
    if state.get("reason"):
        lines.append("Execution limitation: " + _text(state["reason"]))
    if len(confirmed) + len(dismissed) != len(findings):
        lines.append("Some claims have no verified disposition; review coverage is incomplete.")
    if state.get("cancellationUnconfirmed"):
        lines.append("Cancellation unconfirmed: " + ", ".join(_text(item) for item in state["cancellationUnconfirmed"]))
    for role, worker in state.get("workers", {}).items():
        result = worker.get("result")
        if result:
            evidence = result["evidence"]
            if evidence["effectiveModel"] is None:
                lines.append(_text(role) + " effective model unknown: " + _text(evidence["effectiveModelReason"]))
            if evidence["tokenUsage"] is None:
                lines.append(_text(role) + " token usage was not observed.")
    return "\n".join(lines) + "\n"

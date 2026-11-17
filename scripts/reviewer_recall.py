#!/usr/bin/env python3
"""Reviewer recall measurement for the N1 code-reviewer persona (N1-629).

Answer key: pre-push Codex `### Auto-Fixed` findings (codex-triage.posted.md),
classified missed/caught/partial/unknown against the stored N1 review files.

  build   write cases.jsonl: one row per Auto-Fixed finding (class, answer key,
          severity, replay SHA and its source, diff size), size-matched control
          tickets and a seeded tune/test split by ticket. Refuses to overwrite
          an existing file without --force, so the test set stays fixed.
  replay  run the current agents/code-reviewer.md body with `claude -p` on one
          ticket (--case) or a split, each in a detached worktree at the replay
          SHA, with a pre-computed diff file and read-only tools (Read,Grep,Glob).
  grade   `claude -p` judge (no tools) per missed finding vs its answer key;
          writes a seeded sample for the manual check.
  report  deterministic recall / over-flag report with Wilson intervals.

Reuses scripts/persona_ab.py (scrubbed env, process-group kill, claude JSON
parsing, session-id validation). replay and grade make real, paid claude calls,
capped per call by --max-budget-usd and per loop by --budget-total-usd. Outputs
go to <out>/reviewer-recall-<UTC stamp>/ (default out: $N1_HOME/scratch/benchmarks);
a row whose session id does not match is rejected and the exit code is 2.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
import random
import re
import shutil
import statistics
import sys
import tempfile
import time
import uuid
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
_spec = importlib.util.spec_from_file_location("persona_ab", HERE / "persona_ab.py")
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)

REVIEWER_TOOLS = "Read,Grep,Glob"  # persona tools minus Write: the replay must not write anywhere
MEMORY_INPUTS = ("ticket.md", "review-spec.md", "plan.md", "qa-facts.md", "analysis.md")
FINDING_RE = re.compile(r"^\s*[-*]\s*\**\[(?:CR|TQ|RULE)-\d+\]", re.M)  # [XREPO-n] is advisory, not counted
VERDICT_RE = re.compile(r"^#+\s*Verdict\b", re.M)
FILE_RE = re.compile(r"[\w./-]+\.(?:sh|md|py|jsonl|json)\b(?::\d+)?")
SEV_RE = re.compile(r"\[(P\d)\]")
JUDGE_MARKER = "You grade a code review against an answer key."
VERDICTS = ("caught", "partial", "missed")


def wilson(k, n, z=1.96):
    """Wilson score interval for k successes out of n; (None, None) when n == 0."""
    if n == 0:
        return (None, None)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - h) / d, (c + h) / d)


def split_tickets(tickets, seed, tune_frac):
    """Seeded split of ticket ids into (tune, test); independent of input order."""
    order = sorted(tickets)
    random.Random(seed).shuffle(order)
    k = round(len(order) * tune_frac)
    return set(order[:k]), set(order[k:])


def match_controls(missed, candidates):
    """Greedy size match, {ticket: diff_lines} in, ({missed: control}, [unmatched missed]) out.
    Largest missed ticket first takes the unused candidate with the smallest |delta|
    (ties: lower ticket id); a candidate is never reused."""
    pool = dict(candidates)
    pairs, unmatched = {}, []
    for t in sorted(missed, key=lambda x: (-missed[x], x)):
        if not pool:
            unmatched.append(t)
            continue
        c = min(sorted(pool), key=lambda x: abs(pool[x] - missed[t]))
        pairs[t] = c
        del pool[c]
    return pairs, unmatched


def count_findings(text):
    """(n, unparsed) for reviewer output in the code-reviewer Output Format.
    Counts [CR-n], [TQ-n], [RULE-n] bullets. unparsed: no finding bullet and no
    Verdict heading, so the reply is not in the persona format."""
    text = text or ""
    n = len(FINDING_RE.findall(text))
    return n, n == 0 and not VERDICT_RE.search(text)


def parse_judge(text):
    """First {...} JSON object of the judge reply, or None if invalid or the verdict is unknown."""
    m = re.search(r"\{.*?\}", text or "", re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
    except ValueError:
        return None
    if not isinstance(obj, dict) or obj.get("verdict") not in VERDICTS:
        return None
    return obj


def parse_auto_fixed(text):
    """Bullets of the `### Auto-Fixed` block, numbered from 1 like findings.tsv ids (<ticket>#<n>).
    answer_key = the defect title (text before the first ": "), plus the file when the title lacks it."""
    m = re.search(r"^### Auto-Fixed\n(.*?)(?=^### |\Z)", text, re.S | re.M)
    if not m:
        return []
    out = []
    bullets = [b.strip() for b in m.group(1).split("\n") if b.strip().startswith(("-", "*"))]
    for n, b in enumerate(bullets, 1):
        sev = SEV_RE.search(b)
        files = FILE_RE.findall(b)
        file = next((f for f in files if "/" in f), files[0] if files else None)
        plain = SEV_RE.sub("", re.sub(r"\*\*|`", "", b.lstrip("-* "))).strip()
        title = plain.split(": ", 1)[0].strip(" .")
        key = title if not file or file.split(":")[0] in title else f"{title} ({file})"
        out.append({"n": n, "severity": sev.group(1) if sev else None, "file": file,
                    "answer_key": key, "codex_text": plain})
    return out


def read_jsonl(path):
    path = Path(path)
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_cases(path):
    """(meta row, other rows) of cases.jsonl."""
    rows = read_jsonl(path)
    meta = next((r for r in rows if r.get("kind") == "meta"), {})
    return meta, [r for r in rows if r.get("kind") != "meta"]


SHA_SOURCE = "telemetry step:review head (sha.tsv reviewhead)"
TICKET_KEYS = ("replay_sha", "sha_source", "first_head_from", "branch_point", "diff_lines", "reachable")


def git(repo, *args, check=True, timeout=120):
    """git in repo through persona_ab.run_group (scrubbed env, own process group)."""
    proc = ab.run_group(["git", *[str(a) for a in args]], str(repo), timeout, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(map(str, args))} failed: {proc.stderr.strip()[-300:]}")
    return proc


def commit_exists(repo, sha):
    return bool(sha) and git(repo, "cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0


def diff_lines(repo, base, head):
    """insertions + deletions of `git diff --shortstat base..head`."""
    out = git(repo, "diff", "--shortstat", f"{base}..{head}").stdout
    return sum(int(n) for n in re.findall(r"(\d+) (?:insertion|deletion)", out))


def read_tsv(path):
    """Data rows as lists, header skipped (sha.tsv repeats the `reach` column name, so index by position)."""
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    return [line.split("\t") for line in lines[1:] if line.strip()]


def first_head_from(ticket_dir):
    """`from` SHA of the earliest step:"head" event in telemetry/runs/*.jsonl, or None."""
    events = []
    for f in sorted((Path(ticket_dir) / "telemetry" / "runs").glob("*.jsonl")):
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            for s in rec.get("steps") or []:
                meta = s.get("metadata") or {}
                if s.get("step") == "head" and meta.get("from"):
                    events.append((s.get("completed_at") or "~", meta["from"]))
    return min(events)[1] if events else None


def cmd_build(args):
    if args.cases.exists() and not args.force:
        print(f"{args.cases} exists; pass --force to rebuild (the test set must stay fixed)", file=sys.stderr)
        return 1
    classes = {r[0]: (r[1], r[2] if len(r) > 2 else "") for r in read_tsv(args.findings)}
    tickets, findings = {}, []
    for row in read_tsv(args.shas):
        # sha.tsv columns: ticket, group (A case | C control), reviewhead, reach, codex7, reach, prefix, reach, branchpoint
        ticket, group, sha = row[0], row[1], row[2].strip()
        bp_file = args.memory_root / ticket / "branch-point"
        bp = (bp_file.read_text(encoding="utf-8").strip() if bp_file.is_file() else "") or row[8].strip()
        reachable = commit_exists(args.repo, sha) and commit_exists(args.repo, bp)
        tickets[ticket] = {"group": group, "replay_sha": sha, "sha_source": SHA_SOURCE,
                           "first_head_from": first_head_from(args.memory_root / ticket), "branch_point": bp,
                           "diff_lines": diff_lines(args.repo, bp, sha) if reachable else None,
                           "reachable": reachable}
        if group != "A":
            continue
        triage = args.memory_root / ticket / "codex-triage.posted.md"
        for f in parse_auto_fixed(triage.read_text(encoding="utf-8") if triage.is_file() else ""):
            fid = f"{ticket}#{f['n']}"
            cls, why = classes.get(fid, ("unknown", "not in findings.tsv"))
            findings.append({"id": fid, "kind": "finding", "ticket": ticket, "class": cls,
                             "answer_key": f["answer_key"], "severity": f["severity"], "file": f["file"],
                             "codex_text": f["codex_text"], "evidence": why})
    missed = sorted({f["ticket"] for f in findings if f["class"] == "missed" and tickets[f["ticket"]]["reachable"]})
    candidates = {t: v["diff_lines"] for t, v in tickets.items() if v["group"] == "C" and v["reachable"]}
    pairs, unmatched = match_controls({t: tickets[t]["diff_lines"] for t in missed}, candidates)
    if len(missed) < args.min_pairs or len(pairs) < args.min_pairs:
        print(f"need {args.min_pairs} missed tickets and matched controls; have {len(missed)} missed, "
              f"{len(pairs)} pairs, unmatched {unmatched}", file=sys.stderr)
        return 1
    tune, _ = split_tickets(missed, args.seed, args.tune_frac)
    split_of = {t: "tune" if t in tune else "test" for t in missed}
    rows = [{"kind": "meta", "seed": args.seed, "tune_frac": args.tune_frac,
             "built_with": git(REPO, "rev-parse", "HEAD").stdout.strip(), "unmatched": unmatched}]
    for f in findings:
        t = tickets[f["ticket"]]
        rows.append({**f, **{k: t[k] for k in TICKET_KEYS}, "split": split_of.get(f["ticket"])})
    for m, c in sorted(pairs.items()):
        t = tickets[c]
        rows.append({"id": c, "kind": "control", "ticket": c, **{k: t[k] for k in TICKET_KEYS},
                     "matched_to": m, "delta_lines": t["diff_lines"] - tickets[m]["diff_lines"],
                     "split": split_of[m]})
    args.cases.parent.mkdir(parents=True, exist_ok=True)
    args.cases.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    print(f"{args.cases}: {len(findings)} findings, {len(missed)} missed tickets, {len(pairs)} controls, "
          f"tune {len(tune)} / test {len(missed) - len(tune)} tickets", file=sys.stderr)
    return 0


def add_repo_args(sp):
    sp.add_argument("--repo", type=Path, default=REPO,
                    help="git repo holding the replay SHAs (default: this checkout)")
    sp.add_argument("--memory-root", type=Path, help="per-ticket memory root (default $N1_HOME/memory)")


COMMANDS = {"build": cmd_build}


def main(argv=None):
    p = argparse.ArgumentParser(description="Measure N1 code-reviewer recall against Codex Auto-Fixed findings.")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="write cases.jsonl")
    b.add_argument("--findings", required=True, type=Path, help="findings.tsv (finding, class, rationale)")
    b.add_argument("--shas", required=True, type=Path, help="sha.tsv (ticket, group A|C, reviewhead, ..., branchpoint)")
    b.add_argument("--cases", required=True, type=Path)
    b.add_argument("--seed", type=int, default=629)
    b.add_argument("--tune-frac", type=float, default=0.5)
    b.add_argument("--force", action="store_true", help="overwrite an existing cases.jsonl")
    b.add_argument("--min-pairs", type=int, default=15, help=argparse.SUPPRESS)
    add_repo_args(b)
    args = p.parse_args(argv)
    if getattr(args, "memory_root", False) is None:
        if not os.environ.get("N1_HOME"):
            p.error("set N1_HOME or pass --memory-root")
        args.memory_root = Path(os.environ["N1_HOME"]) / "memory"
    if getattr(args, "memory_root", None):
        args.memory_root = args.memory_root.resolve()  # the reviewer runs with cwd=<worktree>
    return COMMANDS[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())

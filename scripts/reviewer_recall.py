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

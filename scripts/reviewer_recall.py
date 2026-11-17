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


def persona_info(path):
    """(frontmatter, body, last commit touching the persona file, sha256 of the file)."""
    path = Path(path).resolve()
    raw = path.read_text(encoding="utf-8")
    meta, body = ab.strip_frontmatter(raw)
    commit = git(path.parent, "log", "-1", "--format=%H", "--", path.name).stdout.strip()
    return meta, body, commit, hashlib.sha256(raw.encode("utf-8")).hexdigest()


def reviewer_prompt(ticket_dir, base, diff_file, files_file, claude_md, claude_diff):
    lines = ["Review this change. Inputs:"]
    for name in MEMORY_INPUTS:
        f = Path(ticket_dir) / name
        lines.append(f"- {name}: {f}" if f.is_file() else f"- {name}: not available")
    lines += [f"- CLAUDE_MD (base copy): {claude_md}" if claude_md else "- CLAUDE_MD: not available",
              f"- CLAUDE_DIFF: {claude_diff}" if claude_diff else "- CLAUDE_DIFF: (none)",
              f"- Base branch: {base}",
              f"- Diff file: {diff_file} (the unified `git diff {base}...HEAD`; it replaces the git commands of Process step 3)",
              f"- Changed files: {files_file}",
              "The checked-out tree in your working directory is the post-change code.",
              "Return the full Output Format report inline. Do not write any file."]
    return "\n".join(lines)


def replay_ticket(case, args, persona, run_dir):
    """One reviewer run for one ticket in a detached worktree; returns (row, harness session id)."""
    meta, prompt_file, commit, digest = persona
    t, sha, base = case["ticket"], case["replay_sha"], case["branch_point"]
    sid = str(uuid.uuid4())
    row = {"id": t, "kind": case["kind"], "ticket": t, "split": case.get("split"), "status": "unreachable",
           "session_id": sid, "persona_commit": commit, "persona_sha256": digest, "replay_sha": sha,
           "findings_text": None, "n_findings": None, "unparsed": False, "tokens": ab.token_split(None),
           "cost_usd": 0.0, "wall_ms": 0, "error": None, "raw": None}
    if not (commit_exists(args.repo, sha) and commit_exists(args.repo, base)):
        return row, sid
    wt = run_dir / f"wt-{t}"
    add = git(args.repo, "worktree", "add", "--detach", wt, sha, check=False)
    if add.returncode != 0:
        row.update(status="error", error=add.stderr.strip()[-300:])
        return row, sid
    try:
        diff_file, files_file = run_dir / f"{t}.diff", run_dir / f"{t}.files"
        diff_file.write_text(git(args.repo, "diff", f"{base}...{sha}").stdout, encoding="utf-8")
        files_file.write_text(git(args.repo, "diff", "--name-only", f"{base}...{sha}").stdout, encoding="utf-8")
        claude_md = claude_diff = None
        shown = git(args.repo, "show", f"{base}:CLAUDE.md", check=False)
        if shown.returncode == 0:
            claude_md = run_dir / f"{t}.CLAUDE.md"
            claude_md.write_text(shown.stdout, encoding="utf-8")
        cd = git(args.repo, "diff", f"{base}...{sha}", "--", "CLAUDE.md").stdout
        if cd.strip():
            claude_diff = run_dir / f"{t}.CLAUDE.diff"
            claude_diff.write_text(cd, encoding="utf-8")
        # Copy only the review inputs: the ticket memory dir also holds the answer key
        # (codex-triage.posted.md, review*.md, implementation.md), so it is never exposed to the reviewer.
        inputs = run_dir / f"{t}.inputs"
        inputs.mkdir(exist_ok=True)
        for name in MEMORY_INPUTS:
            if (args.memory_root / t / name).is_file():
                shutil.copy(args.memory_root / t / name, inputs / name)
        cmd = [args.claude, "-p", reviewer_prompt(inputs, base, diff_file, files_file, claude_md, claude_diff),
               "--output-format", "json", "--session-id", sid,
               "--append-system-prompt-file", str(prompt_file), "--tools", REVIEWER_TOOLS,
               "--add-dir", str(run_dir),
               "--model", args.model, "--max-budget-usd", str(args.max_budget_usd),
               "--setting-sources", "", "--strict-mcp-config"]
        if meta.get("effort"):
            cmd += ["--effort", meta["effort"]]
        start = time.monotonic()
        status, data, err = ab.run_claude(cmd, str(wt), args.timeout)
        text = (data or {}).get("result") if status == "ok" else None
        n, unparsed = count_findings(text) if text is not None else (None, False)
        row.update(status=status, findings_text=text, n_findings=n, unparsed=unparsed,
                   tokens=ab.token_split(data), cost_usd=float((data or {}).get("total_cost_usd") or 0),
                   wall_ms=int((time.monotonic() - start) * 1000), error=err, raw=data)
        return row, sid
    except RuntimeError as e:  # a failing git diff/show must be an error row, not abort the loop
        row.update(status="error", error=str(e)[-300:])
        return row, sid
    finally:
        rm = git(args.repo, "worktree", "remove", "--force", wt, check=False)
        git(args.repo, "worktree", "prune", check=False)
        if rm.returncode != 0:
            row["cleanup_error"] = rm.stderr.strip()[-300:]


def select_cases(cases, args):
    """Ticket-level replay units: one per missed ticket with a split, one per control."""
    units = {}
    for c in cases:
        if c["kind"] == "control":
            units[c["ticket"]] = {**c, "kind": "control"}
        elif c.get("class") == "missed" and c.get("split"):
            units.setdefault(c["ticket"], {**c, "kind": "missed"})
    if args.case:
        t = args.case.split("#")[0]
        return [units[t]] if t in units else []
    return [u for _, u in sorted(units.items())
            if args.split in ("all", u["split"]) and args.role in ("all", u["kind"])]


def new_run_dir(out):
    if out is None:
        if not os.environ.get("N1_HOME"):
            raise SystemExit("set N1_HOME or pass --out")
        out = Path(os.environ["N1_HOME"]) / "scratch" / "benchmarks"
    return Path(out) / f"reviewer-recall-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"


def write_summary(run_dir, name, rows, rejected, args):
    statuses = Counter(r.get("status") for r in rows)
    summary = {"args": {k: str(v) for k, v in vars(args).items()}, "rows": len(rows), "rejected": rejected,
               "statuses": dict(statuses), "total_cost_usd": round(sum(r.get("cost_usd") or 0 for r in rows), 4)}
    (run_dir / f"{name}-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")


def cmd_replay(args):
    if not shutil.which(str(args.claude)):
        print(f"claude binary not found: {args.claude}", file=sys.stderr)
        return 1
    _, cases = load_cases(args.cases)
    todo = select_cases(cases, args)
    if not todo:
        print("no matching cases", file=sys.stderr)
        return 1
    # absolute: git worktree add runs with cwd=<repo>, so a relative --out would land inside the checkout
    run_dir = (Path(args.run_dir) if args.run_dir else new_run_dir(args.out)).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    out_file = run_dir / "replay.jsonl"
    existing = read_jsonl(out_file)
    kept = [r for r in existing if r.get("status") in ("ok", "unreachable")]
    if len(kept) != len(existing):  # drop stale error/timeout rows so a retry does not leave duplicates
        out_file.write_text("".join(json.dumps(r) + "\n" for r in kept), encoding="utf-8")
    done = {r["id"] for r in kept}
    meta, body, commit, digest = persona_info(args.persona)
    prompt_file = run_dir / "persona.md"
    prompt_file.write_text(body, encoding="utf-8")
    rows, rejected, spent = [], 0, 0.0
    try:
        with open(out_file, "a", encoding="utf-8") as fh:
            for i, case in enumerate(todo, 1):
                if case["ticket"] in done:
                    continue
                if args.budget_total_usd is not None and spent >= args.budget_total_usd:
                    print(f"total budget ${args.budget_total_usd} reached; stopping", file=sys.stderr)
                    break
                row, sid = replay_ticket(case, args, (meta, prompt_file, commit, digest), run_dir)
                spent += row["cost_usd"]
                reason = ab.validate_row(row, sid)
                if reason:
                    rejected += 1
                    print(f"[{i}/{len(todo)}] REJECTED {case['ticket']}: {reason}", file=sys.stderr)
                    continue
                rows.append(row)
                fh.write(json.dumps(row) + "\n")
                fh.flush()
                print(f"[{i}/{len(todo)}] {case['ticket']} {case['kind']}: {row['status']} "
                      f"findings={row['n_findings']} cost=${row['cost_usd']:.4f}", file=sys.stderr)
    finally:
        write_summary(run_dir, "replay", rows, rejected, args)
        print(run_dir)
    return 2 if rejected else 0


JUDGE_PROMPT = (JUDGE_MARKER + " Answer key: {key}. Codex finding text: {codex}\n\nReview findings:\n{review}\n\n"
                "Verdict `caught` only if a finding describes the same defect (same mechanism, same code location "
                "or function). `partial` if it names the same file or symptom but a different mechanism. "
                "Otherwise `missed`. Reply with one JSON object: "
                '{{"verdict":"caught|partial|missed","finding_ref":"<id or null>","reason":"<one sentence>"}}.')


def write_sample(run_dir, cases, grades, replays, seed):
    """Seeded 20% (min 5) sample of ok grades for the manual check (D5)."""
    graded = sorted((g for g in grades if g.get("status") == "ok"), key=lambda g: g["id"])
    k = min(len(graded), max(5, math.ceil(len(graded) * 0.2)))
    by_id = {c["id"]: c for c in cases}
    lines = [f"sample: {k}", "",
             "Check each verdict against the answer key, then write the number of disagreements as the "
             "first line of grade-sample.confirmed in this directory.", ""]
    for g in sorted(random.Random(seed).sample(graded, k), key=lambda g: g["id"]):
        c = by_id[g["id"]]
        lines += [f"## {g['id']} ({c.get('split')})", f"- Answer key: {c['answer_key']}",
                  f"- Codex text: {c.get('codex_text')}",
                  f"- Judge: {g['verdict']} ({g.get('finding_ref')}): {g.get('reason')}", "",
                  "<details><summary>review</summary>", "", replays[c["ticket"]].get("findings_text") or "", "",
                  "</details>", ""]
    (run_dir / "grade-sample.md").write_text("\n".join(lines), encoding="utf-8")


def cmd_grade(args):
    if not shutil.which(str(args.claude)):
        print(f"claude binary not found: {args.claude}", file=sys.stderr)
        return 1
    meta, cases = load_cases(args.cases)
    run_dir = Path(args.replay)
    replays = {r["ticket"]: r for r in read_jsonl(run_dir / "replay.jsonl") if r.get("status") == "ok"}
    out_file = run_dir / "grades.jsonl"
    done = {g["id"] for g in read_jsonl(out_file)}
    todo = [c for c in cases if c["kind"] == "finding" and c["class"] == "missed"
            and c["ticket"] in replays and c["id"] not in done]
    rows, rejected = [], 0
    try:
        with open(out_file, "a", encoding="utf-8") as fh:
            for c in todo:
                sid = str(uuid.uuid4())
                prompt = JUDGE_PROMPT.format(key=c["answer_key"], codex=c.get("codex_text") or "",
                                             review=replays[c["ticket"]].get("findings_text") or "(empty)")
                cmd = [args.claude, "-p", prompt, "--output-format", "json", "--session-id", sid, "--tools", "",
                       "--model", args.model, "--max-budget-usd", str(args.max_budget_usd),
                       "--setting-sources", "", "--strict-mcp-config"]
                cwd = tempfile.mkdtemp(prefix="reviewer-recall-judge-")
                try:
                    status, data, err = ab.run_claude(cmd, cwd, args.timeout)
                finally:
                    shutil.rmtree(cwd, ignore_errors=True)
                verdict = parse_judge((data or {}).get("result")) if status == "ok" else None
                row = {"id": c["id"], "ticket": c["ticket"], "split": c.get("split"),
                       "status": "ok" if verdict else "error", "verdict": (verdict or {}).get("verdict"),
                       "finding_ref": (verdict or {}).get("finding_ref"), "reason": (verdict or {}).get("reason"),
                       "session_id": sid, "cost_usd": float((data or {}).get("total_cost_usd") or 0),
                       "error": None if verdict else (err or "unparseable judge reply"), "raw": data}
                reason = ab.validate_row(row, sid)
                if reason:
                    rejected += 1
                    print(f"REJECTED {c['id']}: {reason}", file=sys.stderr)
                    continue
                rows.append(row)
                fh.write(json.dumps(row) + "\n")
                fh.flush()
                print(f"{c['id']}: {row['status']} {row['verdict']}", file=sys.stderr)
    finally:
        write_summary(run_dir, "grade", rows, rejected, args)
    write_sample(run_dir, cases, read_jsonl(out_file), replays, meta.get("seed", 629))
    print(run_dir / "grades.jsonl")
    return 2 if rejected else 0


def compute_report(meta, cases, replays, grades, manual):
    """Pure aggregation, no claude calls. Raises ValueError when replay rows mix persona commits."""
    commits = sorted({r["persona_commit"] for r in replays if r.get("persona_commit")})
    if len(commits) > 1:
        raise ValueError(f"replay rows mix persona commits {commits}; report one persona version at a time")
    findings = [c for c in cases if c["kind"] == "finding"]
    missed = [c for c in findings if c["class"] == "missed"]
    cls = Counter(c["class"] for c in findings)
    n_final = cls["caught"] + cls["missed"]
    final = {"caught": cls["caught"], "missed": cls["missed"], "partial": cls["partial"],
             "unknown": cls["unknown"], "n": n_final, "ci": list(wilson(cls["caught"], n_final))}
    ok_grades = {g["id"]: g for g in grades if g.get("status") == "ok"}
    ok = [r for r in replays if r.get("status") == "ok"]
    raw, over = {}, {}
    for s in ("tune", "test"):
        vs = [ok_grades[c["id"]]["verdict"] for c in missed if c.get("split") == s and c["id"] in ok_grades]
        k, m = vs.count("caught"), vs.count("missed")
        raw[s] = {"total": sum(1 for c in missed if c.get("split") == s), "caught": k, "n": k + m,
                  "partial": vs.count("partial"), "ci": list(wilson(k, k + m))}
        for kind in ("control", "missed"):
            ns = [r["n_findings"] for r in ok if r.get("split") == s and r["kind"] == kind and not r.get("unparsed")]
            over[f"{s}_{kind}"] = {"tickets": len(ns), "mean": statistics.mean(ns) if ns else None,
                                   "median": ab._median(ns)}
    by_file = {}
    for c in missed:
        if c.get("file"):
            by_file.setdefault(c["file"].split(":")[0], []).append(c)
    recurring = {f: sorted(c["id"] for c in cs) for f, cs in sorted(by_file.items())
                 if len({c["ticket"] for c in cs}) >= 2}
    lines_of = {c["ticket"]: c.get("diff_lines") for c in findings}
    pairs = [{"missed": c["matched_to"], "control": c["ticket"], "split": c.get("split"),
              "missed_lines": lines_of.get(c["matched_to"]), "control_lines": c.get("diff_lines"),
              "delta": c.get("delta_lines")} for c in cases if c["kind"] == "control"]
    exclusions = {
        "unreachable": sorted({c["ticket"] for c in cases if c.get("reachable") is False}
                              | {r["id"] for r in replays if r.get("status") == "unreachable"}),
        "replay_error": sorted(r["id"] for r in replays if r.get("status") in ("error", "timeout")),
        "unparsed": sorted(r["id"] for r in ok if r.get("unparsed")),
        "judge_error": sorted(g["id"] for g in grades if g.get("status") != "ok")}
    persona = next((r for r in replays if r.get("persona_commit")), {})
    return {"persona_commit": persona.get("persona_commit"), "persona_sha256": persona.get("persona_sha256"),
            "seed": meta.get("seed"), "tune_frac": meta.get("tune_frac"),
            "split_tickets": {s: len({c["ticket"] for c in missed if c.get("split") == s}) for s in ("tune", "test")},
            "final": final, "raw": raw, "overflag": over, "pairs": pairs, "recurring": recurring,
            "exclusions": exclusions, "manual": manual,
            "cost_usd": {"replay": round(sum(r.get("cost_usd") or 0 for r in replays), 4),
                         "judge": round(sum(g.get("cost_usd") or 0 for g in grades), 4)}}


def _num(x):
    return "-" if x is None else f"{x:.2f}"


def _rate(k, n, ci):
    if not n:
        return f"{k}/0 (no denominator)"
    return f"{k}/{n} = {k / n:.0%} (95% Wilson {ci[0]:.0%} to {ci[1]:.0%})"


def manual_line(manual):
    if not manual:
        return "manual check: pending (run grade first)"
    if manual.get("disagreements") is None:
        return (f"manual check: pending (confirm the {manual['sample']} verdicts in grade-sample.md, "
                "then write the disagreement count to grade-sample.confirmed)")
    return f"manual check: {manual['sample'] - manual['disagreements']}/{manual['sample']} agree"


def render_report(rep, cases, grades):
    f, raw, ov = rep["final"], rep["raw"], rep["overflag"]
    g_by = {g["id"]: g for g in grades}
    L = ["# Reviewer recall report (N1-629)", "",
         f"- Persona commit: {rep['persona_commit']} (sha256 {rep['persona_sha256']})",
         f"- Replay run: {rep.get('run_dir')}",
         f"- Script commit: {rep.get('script_commit')}",
         f"- Seed {rep['seed']}, tune_frac {rep['tune_frac']}; missed tickets tune {rep['split_tickets']['tune']}, "
         f"test {rep['split_tickets']['test']}; missed findings tune {raw['tune']['total']}, test {raw['test']['total']}",
         "", "## Final-verdict recall (stored review history)", "",
         f"caught / (caught + missed): {_rate(f['caught'], f['n'], f['ci'])}. "
         f"Excluded from the denominator: partial {f['partial']}, unknown {f['unknown']}. "
         "Cycle-0 reviewer text was overwritten for many tickets, so `missed` is an upper bound.",
         "", "## Raw recall (replay, current persona)", "",
         "Conditional on a historical miss: the share of earlier misses the current reviewer now catches. "
         "Headline: test split.", ""]
    for s in ("test", "tune"):
        r = raw[s]
        L.append(f"- {s}: {_rate(r['caught'], r['n'], r['ci'])}; partial verdicts (excluded): {r['partial']}")
    L += ["", "## Control over-flag rate (findings per ticket)", "",
          "| split | controls mean (n) | controls median | missed-ticket mean (n) | missed-ticket median |",
          "|---|---|---|---|---|"]
    for s in ("test", "tune"):
        c, m = ov[f"{s}_control"], ov[f"{s}_missed"]
        L.append(f"| {s} | {_num(c['mean'])} ({c['tickets']}) | {_num(c['median'])} | "
                 f"{_num(m['mean'])} ({m['tickets']}) | {_num(m['median'])} |")
    L += ["", "| missed ticket | control | split | diff lines missed / control | delta |", "|---|---|---|---|---|"]
    for p in rep["pairs"]:
        L.append(f"| {p['missed']} | {p['control']} | {p['split']} | {p['missed_lines']} / {p['control_lines']} | {p['delta']} |")
    L += ["", "## Per-case results", "", "| id | class | split | severity | replay verdict | reason | judge cost |",
          "|---|---|---|---|---|---|---|"]
    for c in (c for c in cases if c["kind"] == "finding"):
        g = g_by.get(c["id"], {})
        L.append(f"| {c['id']} | {c['class']} | {c.get('split') or '-'} | {c.get('severity') or '-'} | "
                 f"{g.get('verdict') or '-'} | {(g.get('reason') or '').replace('|', '/')} | {_num(g.get('cost_usd'))} |")
    L += ["", "## Exclusions", ""]
    for k, ids in rep["exclusions"].items():
        L.append(f"- {k}: {', '.join(ids) if ids else 'none'}")
    L += ["", "## Costs and caveats", "",
          f"- Cost USD: replay {rep['cost_usd']['replay']}, judge {rep['cost_usd']['judge']}",
          f"- {manual_line(rep['manual'])}",
          "- The judge model grades the same model family as the reviewer (self-grading bias); the manual sample is the check.",
          "- Test n is small, so Wilson intervals are wide and cannot detect a small persona change.",
          "- Replay gives the reviewer a pre-computed diff and no Bash, unlike live dispatch; ~/.claude/CLAUDE.md still loads.",
          "- Replay inputs omit implementation.md and qa.md (they can carry post-review fix text), so the "
          "test-weakening guard sees no citation and can add findings on missed and control tickets alike.",
          "", "## Recurring misses (same file in 2+ tickets)", ""]
    L += [f"- {f}: {', '.join(ids)}" for f, ids in rep["recurring"].items()] or ["- none"]
    return "\n".join(L) + "\n"


def cmd_report(args):
    meta, cases = load_cases(args.cases)
    run_dir = Path(args.replay)
    replays, grades = read_jsonl(run_dir / "replay.jsonl"), read_jsonl(run_dir / "grades.jsonl")
    manual = None
    sample, confirmed = run_dir / "grade-sample.md", run_dir / "grade-sample.confirmed"
    if sample.is_file():
        m = re.match(r"sample: (\d+)", sample.read_text(encoding="utf-8"))
        manual = {"sample": int(m.group(1)) if m else 0, "disagreements": None}
        if confirmed.is_file():
            d = re.match(r"\s*(\d+)", confirmed.read_text(encoding="utf-8"))
            manual["disagreements"] = int(d.group(1)) if d else None
    try:
        rep = compute_report(meta, cases, replays, grades, manual)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 1
    rep["run_dir"] = str(run_dir)
    rep["script_commit"] = git(REPO, "rev-parse", "HEAD").stdout.strip()
    args.report_out.parent.mkdir(parents=True, exist_ok=True)
    args.report_out.write_text(render_report(rep, cases, grades), encoding="utf-8")
    args.report_out.with_suffix(".json").write_text(json.dumps(rep, indent=2) + "\n", encoding="utf-8")
    print(args.report_out)
    return 0


COMMANDS = {"build": cmd_build, "replay": cmd_replay, "grade": cmd_grade, "report": cmd_report}


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
    r = sub.add_parser("replay", help="replay the current reviewer persona on cases (paid claude calls)")
    r.add_argument("--cases", required=True, type=Path)
    sel = r.add_mutually_exclusive_group(required=True)
    sel.add_argument("--case", help="one ticket id (or <ticket>#<n>)")
    sel.add_argument("--split", choices=("tune", "test", "all"))
    r.add_argument("--role", choices=("missed", "control", "all"), default="all")
    r.add_argument("--model", default="sonnet")
    r.add_argument("--timeout", type=int, default=600, help="seconds per reviewer run")
    r.add_argument("--max-budget-usd", type=float, default=2.0, help="spend cap per reviewer run")
    r.add_argument("--budget-total-usd", type=float, help="stop the loop once this much was spent")
    r.add_argument("--out", type=Path, help="output dir (default $N1_HOME/scratch/benchmarks)")
    r.add_argument("--run-dir", type=Path, help="resume into an existing run dir; tickets already replayed are skipped")
    r.add_argument("--persona", type=Path, default=REPO / "agents" / "code-reviewer.md", help=argparse.SUPPRESS)
    r.add_argument("--claude", default="claude", help=argparse.SUPPRESS)
    add_repo_args(r)
    g = sub.add_parser("grade", help="judge replayed reviews against answer keys (paid claude calls)")
    g.add_argument("--cases", required=True, type=Path)
    g.add_argument("--replay", required=True, type=Path, help="replay run dir (grades.jsonl is written there)")
    g.add_argument("--model", default="sonnet")
    g.add_argument("--timeout", type=int, default=180, help="seconds per judge call")
    g.add_argument("--max-budget-usd", type=float, default=0.5, help="spend cap per judge call")
    g.add_argument("--claude", default="claude", help=argparse.SUPPRESS)
    rp = sub.add_parser("report", help="write report.md and report.json (no claude calls)")
    rp.add_argument("--cases", required=True, type=Path)
    rp.add_argument("--replay", required=True, type=Path, help="replay run dir holding replay.jsonl and grades.jsonl")
    rp.add_argument("--report-out", required=True, type=Path, help="report .md path; .json is written beside it")
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

#!/usr/bin/env python3
"""Find prior upstream work and gate publication of a PR.

Usage: fm-upstream-prior-art.py scan --repo OWNER/REPO
         --title TEXT --summary-file FILE --record FILE --base REF
       fm-upstream-prior-art.py decide --record FILE --decisions-file FILE
       fm-upstream-prior-art.py check --record FILE --repo OWNER/REPO
         --title TEXT --summary-file FILE --base REF
       fm-upstream-prior-art.py publish [check options] --body-file FILE
         [--head OWNER:BRANCH]
       fm-upstream-prior-art.py verify --record FILE --repo OWNER/REPO
         --head SHA [--published]

The record is a local JSON receipt, not a forge write. The decisions file is
JSON with verdict (none-found, distinct, overlaps), items keyed by candidate
URL with verdict and one-line reason, and captain_decision when overlaps.
A scan that hits its request or time budget writes an incomplete record,
exits nonzero, and cannot be decided or published. Query and per-query hit
caps are disclosed in coverage (truncated, read/total counts, dropped queries).
captured_at must carry a timezone; the one-hour freshness limit applies to
check, publish, and verify, but not to verify --published. verify --published
accepts a forge head equal to the scanned head or one the forge compares as
strictly ahead of it (no force-push or rewrite).
Only publish calls gh-axi pr create; all other operations are read-only on GitHub.
"""

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote

SCHEMA = "fm-upstream-prior-art.v1"
FRESH_SECONDS = 3600
CLOSED_DAYS = 30
MAX_FILE_PAGES = 30
PAGE_SIZE = 100
READ_ATTEMPTS = 5
RATE_WAIT_MAX = 120
# A scan reads only the most relevant search hits per query and stops at a
# fixed request and time budget, well inside the freshness window.
MAX_QUERIES = 8
SEARCH_HITS = 10
SCAN_REQUESTS = 250
SCAN_SECONDS = 600
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SHA = re.compile(r"^[a-f0-9]{40,64}$")
WORD = re.compile(r"[A-Za-z][A-Za-z0-9_]{3,}")
STOP = {"about", "after", "again", "also", "before", "change", "changes", "could", "from", "have", "into", "issue", "more", "pull", "request", "should", "that", "their", "there", "these", "this", "when", "with", "would"}
# Rows are kept compact so busy repositories need few gh-axi calls: bodies are
# reduced to their issue references and URLs are rebuilt from numbers.
BODY = ('([(.body // "") | scan("(?i)https://github\\\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+|[A-Za-z0-9]?#[0-9]+")]'
        ' | unique | .[0:10] | join(" "))')
ROW = f"number, author: .user.login, title, body: {BODY}, state"
ISSUE_FIELDS = f"{{{ROW}, pull_request: (.pull_request != null)}}"


def fail(message):
    raise ValueError(message)


class BudgetSpent(Exception):
    """A scan bound was reached; the scan is recorded as incomplete."""


BUDGET = {}


def spend():
    if not BUDGET:
        return
    if BUDGET["requests"] >= SCAN_REQUESTS:
        raise BudgetSpent(f"request budget of {SCAN_REQUESTS} GitHub calls reached")
    if time.monotonic() >= BUDGET["deadline"]:
        raise BudgetSpent(f"time budget of {SCAN_SECONDS} seconds reached")
    BUDGET["requests"] += 1


def run(command, *, input_text=None):
    for _ in range(READ_ATTEMPTS):
        if command[0] == "gh-axi":
            spend()
        result = subprocess.run(command, input=input_text, text=True, capture_output=True, check=False)
        if not result.returncode:
            return result.stdout
        if command[0] != "gh-axi" or "RATE_LIMITED" not in result.stdout + result.stderr:
            break
        time.sleep(rate_limit_wait())
    fail(f"command failed ({' '.join(command[:2])}): {result.stderr.strip() or result.stdout.strip()}")


def rate_limit_wait():
    # Search allows 30 calls a minute; wait out a short window, but refuse
    # rather than stall for the hourly core window.
    limits = api("rate_limit", "{search: .resources.search, core: .resources.core}")
    try:
        resets = [int(limit["reset"]) for limit in limits.values() if int(limit["remaining"]) == 0]
    except (AttributeError, KeyError, TypeError, ValueError):
        fail("GitHub rate limit status was malformed")
    wait = max(resets, default=time.time() + 60) - time.time() + 1
    if wait > RATE_WAIT_MAX or (BUDGET and time.monotonic() + wait >= BUDGET["deadline"]):
        if not BUDGET:
            fail(f"GitHub API rate limit resets in {int(wait)} seconds; retry later")
        raise BudgetSpent(f"GitHub API rate limit resets in {int(wait)} seconds")
    return max(wait, 1)


def git(*args):
    return run(["git", *args]).strip()


def api(path, selector=".", *, split=False):
    # gh-axi's bounded envelope needs a selector to return unambiguous JSON.
    output = run(["gh-axi", "api", path, "--jq", f"({selector})|tojson|@base64"])
    if split and re.search(r"^  truncated: true$", output, re.M):
        return None
    match = re.search(r"^  body: ([A-Za-z0-9+/=]+)$", output, re.M)
    if not match or not re.search(r"^  truncated: false$", output, re.M):
        fail(f"unreadable or truncated GitHub response: {path}")
    try:
        return json.loads(base64.b64decode(match.group(1), validate=True))
    except (ValueError, json.JSONDecodeError) as error:
        fail(f"invalid GitHub JSON for {path}: {error}")


def rows(path, fields, *, base=".", key=".number", head=""):
    # gh-axi truncates large output, so read one GitHub page in adaptive slices
    # and re-read the page when triage changes it between slices.
    size = None
    for _ in range(READ_ATTEMPTS):
        meta, out = None, []
        while meta is None or len(out) < len(meta["ids"]):
            start = len(out)
            stop = "" if size is None else start + size
            part = api(path, f"{{{head}ids: [{base}[] | {key}], rows: [{base}[{start}:{stop}][] | {fields}]}}", split=True)
            if part is None:
                if size == 1:
                    fail(f"GitHub row is too large to read: {path}")
                size = max(1, (size or PAGE_SIZE) // 2)
                continue
            if not isinstance(part, dict) or not isinstance(part.get("ids"), list) or not isinstance(part.get("rows"), list):
                fail(f"GitHub list was malformed: {path}")
            if meta is None:
                meta = part
            elif part["ids"] != meta["ids"]:
                break
            if len(part["rows"]) != len(meta["ids"][start:stop or None]):
                fail(f"GitHub list was malformed: {path}")
            out.extend(part["rows"])
        else:
            del meta["rows"]
            return meta, out
    fail(f"GitHub list kept changing while reading: {path}")


def shared_files(repo, number, files):
    # The selector returns only paths this branch also changes, so each page
    # of a PR's file list is one small gh-axi call.
    shared = []
    for page in range(1, MAX_FILE_PAGES + 1):
        part = api(f"repos/{repo}/pulls/{number}/files?per_page={PAGE_SIZE}&page={page}",
                   f"[.[].filename] as $all | {{count: ($all | length), shared: ($all - ($all - {json.dumps(files)}))}}")
        if not isinstance(part, dict) or not isinstance(part.get("count"), int) or not isinstance(part.get("shared"), list):
            fail(f"GitHub file list was malformed: pull {number}")
        shared.extend(part["shared"])
        if part["count"] < PAGE_SIZE:
            return sorted(set(shared))
    return sorted(set(shared))


def search(query):
    # Only the first, most relevant page is read; its total is recorded.
    result, items = rows(f"search/issues?q={quote(query)}&per_page={SEARCH_HITS}", ISSUE_FIELDS,
                         base=".items", head="total_count, incomplete_results, ")
    if result.get("incomplete_results") or not isinstance(result.get("total_count"), int):
        fail(f"GitHub search was incomplete: {query}")
    return result["total_count"], items


def atomic_json(path, value):
    path = Path(path)
    if path.is_symlink():
        fail(f"record is a symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        fail(f"record is missing or unsafe: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"record is unreadable: {error}")


def candidate_records(record):
    if not isinstance(record, dict):
        fail("prior-art record is malformed")
    candidates = record.get("candidates")
    if not isinstance(candidates, list) or any(
        not isinstance(candidate, dict)
        or any(not isinstance(candidate.get(key), str) or not candidate[key] for key in ("url", "author", "state", "title", "kind"))
        or not isinstance(candidate.get("reasons"), list)
        or any(not isinstance(reason, str) for reason in candidate["reasons"])
        for candidate in candidates
    ):
        fail("prior-art candidates are missing or malformed")
    return candidates


def context(args):
    if not REPO.fullmatch(args.repo):
        fail("repo must be OWNER/REPO")
    title = args.title.strip()
    summary = Path(args.summary_file).read_text(encoding="utf-8").strip()
    if not title or not summary:
        fail("title and summary must be nonempty")
    head = git("rev-parse", "HEAD")
    if not SHA.fullmatch(head):
        fail("Git HEAD is not a full commit SHA")
    base = args.base or ""
    if not base:
        fail("a PR scan needs --base to inspect its branch diff")
    diff = git("diff", "--no-ext-diff", "--find-renames", f"{base}...HEAD", "--")
    files = git("diff", "--no-ext-diff", "--name-only", f"{base}...HEAD", "--").splitlines()
    if not files:
        fail("the PR branch diff has no changed files")
    digest = hashlib.sha256(diff.encode()).hexdigest()
    return {"repo": args.repo, "kind": "pr", "title": title, "summary": summary,
            "head": head, "base": base, "diff_sha256": digest, "files": files}


def terms(ctx, diff):
    words = []
    for source in (ctx["title"], ctx["summary"]):
        words.extend(w.lower() for w in WORD.findall(source) if w.lower() not in STOP)
    # Added/deleted symbols provide queries when a title is too broad.
    symbols = []
    for line in diff.splitlines():
        if line.startswith(("+++", "---")) or not line.startswith(("+", "-")):
            continue
        symbols.extend(w for w in WORD.findall(line[1:]) if ("_" in w or any(c.isupper() for c in w[1:])) and w.lower() not in STOP)
    groups = []
    title_words = list(dict.fromkeys(w.lower() for w in WORD.findall(ctx["title"]) if w.lower() not in STOP))
    if title_words:
        groups.append(title_words[:3])
    summary_words = list(dict.fromkeys(w.lower() for w in WORD.findall(ctx["summary"]) if w.lower() not in STOP))
    if summary_words:
        groups.append(summary_words[:3])
    groups.extend([[symbol] for symbol in list(dict.fromkeys(symbols))[:4]])
    # A few single terms catch a related PR whose title differs substantially.
    groups.extend([[word] for word in list(dict.fromkeys(words))[:3]])
    return list(dict.fromkeys(" ".join(group) for group in groups if group))[:10]


def issue_numbers(text, repo):
    owner, name = repo.split("/", 1)
    urls = re.findall(rf"https://github\.com/{re.escape(owner)}/{re.escape(name)}/issues/(\d+)", text, re.I)
    return set(urls) | set(re.findall(r"(?<![A-Za-z0-9])#(\d+)\b", text))


def normalized(row, kind, repo):
    url = f"https://github.com/{repo}/{'pull' if kind == 'pr' else 'issues'}/{row.get('number')}"
    return {"url": url, "author": row.get("author") or "",
            "state": row.get("state", ""), "title": row.get("title") or "",
            "body": row.get("body") or "", "number": row.get("number"), "kind": kind,
            "reasons": []}


def scan(args):
    ctx = context(args)
    now = dt.datetime.now(dt.timezone.utc)
    since = (now - dt.timedelta(days=CLOSED_DAYS)).date().isoformat()
    repo = ctx["repo"]
    diff = git("diff", "--no-ext-diff", f"{ctx['base']}...HEAD", "--")
    linked = issue_numbers(ctx["title"] + "\n" + ctx["summary"] + "\n" + diff, repo)
    wanted = list(dict.fromkeys([f"#{n}" for n in sorted(linked, key=int)] + terms(ctx, diff)))
    queries, dropped = wanted[:MAX_QUERIES], wanted[MAX_QUERIES:]
    scopes = {"open": "is:open", "closed-unmerged": f"is:pr is:closed is:unmerged closed:>{since}"}
    found = {}
    covered = []
    open_prs = None
    stopped = ""

    def add(row):
        kind = "pr" if row.get("pull_request") else "issue"
        candidate = normalized(row, kind, repo)
        if not candidate["author"] or not isinstance(candidate["number"], int) or candidate["number"] < 1:
            fail("GitHub returned an incomplete candidate")
        return found.setdefault(candidate["url"], candidate)

    BUDGET.update(requests=0, deadline=time.monotonic() + SCAN_SECONDS)
    try:
        open_prs, _ = search(f"repo:{repo} is:pr is:open")
        for query in queries:
            for scope, qualifier in scopes.items():
                total, hits = search(f"repo:{repo} {qualifier} {query}")
                covered.append({"query": query, "scope": scope, "total": total, "read": len(hits)})
                for row in hits:
                    candidate = add(row)
                    reason = f"search ({scope}): {query}"
                    if reason not in candidate["reasons"]:
                        candidate["reasons"].append(reason)

        own_words = set(w.lower() for w in WORD.findall(ctx["title"] + " " + ctx["summary"]) if w.lower() not in STOP)
        for candidate in found.values():
            overlap = sorted(linked & issue_numbers(candidate["title"] + "\n" + candidate["body"], repo), key=int)
            if overlap:
                candidate["reasons"].append("linked issues: " + ", ".join("#" + n for n in overlap))
            shared_words = sorted(own_words & {w.lower() for w in WORD.findall(candidate["title"] + " " + candidate["body"]) if w.lower() not in STOP})
            if len(shared_words) >= 2:
                candidate["reasons"].append("shared keywords: " + ", ".join(shared_words[:8]))
            # Path overlap is checked only on PRs the searches returned.
            if candidate["kind"] == "pr":
                try:
                    shared = shared_files(repo, candidate["number"], ctx["files"])
                except ValueError as error:
                    # GitHub refuses file lists for closed PRs whose diff is gone.
                    if "VALIDATION_ERROR" not in str(error):
                        raise
                    candidate["reasons"].append("changed files unavailable")
                    shared = []
                if shared:
                    candidate["reasons"].append("shared files: " + ", ".join(shared))
    except BudgetSpent as error:
        stopped = str(error)
    finally:
        requests = BUDGET["requests"]
        BUDGET.clear()
    selected = sorted(({key: candidate[key] for key in ("url", "author", "state", "title", "kind", "reasons")}
                       | {"verdict": "unreviewed", "reason": ""} for candidate in found.values()),
                      key=lambda row: row["url"])
    open_prs_matched = sum(1 for row in selected if row["kind"] == "pr" and row["state"] == "open")
    record = {"schema": SCHEMA, "captured_at": now.isoformat(), "closed_window_days": CLOSED_DAYS,
              "context": ctx, "queries": queries, "open_prs": {"listed": open_prs, "matched": open_prs_matched},
              "complete": not stopped,
              "coverage": {"searches": covered, "requests": requests, "stopped": stopped,
                           "dropped_queries": dropped, "truncated": truncation(covered, dropped)},
              "candidates": selected, "verdict": "incomplete" if stopped else "pending", "captain_decision": ""}
    atomic_json(args.record, record)
    if stopped:
        fail(f"prior-art scan incomplete ({stopped}); recorded what was covered, publication stays refused: {args.record}")
    print(f"prior-art scan recorded {len(selected)} candidates: {args.record}")


def truncation(searches, dropped):
    return bool(dropped) or any(search["total"] > search["read"] for search in searches)


def complete(record):
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        fail("unrecognized prior-art record schema")
    if record.get("complete") is not True:
        fail("prior-art scan was incomplete; rerun the scan")
    coverage = record.get("coverage")
    searches = coverage.get("searches") if isinstance(coverage, dict) else None
    dropped = coverage.get("dropped_queries") if isinstance(coverage, dict) else None
    if not isinstance(searches, list) or any(
        not isinstance(search, dict)
        or any(not isinstance(search.get(key), int) or isinstance(search[key], bool) for key in ("total", "read"))
        for search in searches
    ) or not isinstance(dropped, list) or any(not isinstance(query, str) for query in dropped) \
            or coverage.get("truncated") is not truncation(searches, dropped):
        fail("prior-art record does not disclose its search truncation; rerun the scan")


def decide(args):
    record = read_json(args.record)
    complete(record)
    decision = read_json(args.decisions_file)
    if not isinstance(decision, dict):
        fail("decisions file is malformed")
    verdict = decision.get("verdict")
    if verdict not in ("none-found", "distinct", "overlaps"):
        fail("verdict must be none-found, distinct, or overlaps")
    candidates = candidate_records(record)
    if verdict == "none-found" and candidates:
        fail("none-found is invalid when the scan found candidates")
    if verdict != "none-found" and not candidates:
        fail("a candidate verdict requires candidates")
    items = decision.get("items", [])
    if not isinstance(items, list) or any(
        not isinstance(item, dict) or not isinstance(item.get("url"), str) or not item["url"]
        for item in items
    ) or {item["url"] for item in items} != {item["url"] for item in candidates} or len(items) != len(candidates):
        fail("decisions must cover every candidate URL exactly once")
    by_url = {item["url"]: item for item in items}
    for candidate in candidates:
        item = by_url[candidate["url"]]
        reason = item.get("reason", "")
        if item.get("verdict") not in ("distinct", "overlaps") or not isinstance(reason, str) or not reason.strip() or "\n" in reason:
            fail("every candidate needs a distinct/overlaps verdict and one-line reason")
        candidate["verdict"] = item["verdict"]
        candidate["reason"] = reason.strip()
    overlaps = any(item["verdict"] == "overlaps" for item in candidates)
    if (verdict == "overlaps") != overlaps:
        fail("overall verdict must match candidate overlap verdicts")
    captain_decision = decision.get("captain_decision", "")
    if not isinstance(captain_decision, str) or "\n" in captain_decision:
        fail("captain decision must be one line")
    record["verdict"] = verdict
    record["captain_decision"] = captain_decision
    atomic_json(args.record, record)
    print(f"prior-art verdict recorded: {verdict}")


def decided(record, fresh):
    try:
        captured = dt.datetime.fromisoformat(record["captured_at"])
    except (KeyError, ValueError, TypeError):
        fail("prior-art record has no valid capture time")
    if captured.tzinfo is None:
        fail("prior-art record capture time has no timezone")
    age = (dt.datetime.now(dt.timezone.utc) - captured).total_seconds()
    if fresh and (age < 0 or age > FRESH_SECONDS):
        fail("prior-art record is stale: scan is older than one hour")
    verdict = record.get("verdict")
    candidates = candidate_records(record)
    captain_decision = record.get("captain_decision")
    if not isinstance(captain_decision, str):
        fail("prior-art captain decision is malformed")
    if verdict not in ("none-found", "distinct", "overlaps"):
        fail("prior-art verdict is missing or malformed")
    if verdict == "none-found" and candidates:
        fail("none-found record has candidates")
    if verdict != "none-found":
        if not candidates or any(
            candidate.get("verdict") not in ("distinct", "overlaps")
            or not isinstance(candidate.get("reason"), str)
            or not candidate["reason"].strip()
            for candidate in candidates
        ):
            fail("prior-art candidate decisions are incomplete")
        if (verdict == "overlaps") != any(candidate["verdict"] == "overlaps" for candidate in candidates):
            fail("prior-art candidate verdicts conflict")
    if verdict == "overlaps" and not captain_decision.strip():
        fail("prior-art overlaps require a recorded captain decision")
    return record


def checked(args):
    record = read_json(args.record)
    complete(record)
    if record.get("context") != context(args):
        fail("prior-art record is stale: target, text, branch head, base, or diff changed")
    return decided(record, fresh=True)


def verify_receipt(args):
    record = read_json(args.record)
    complete(record)
    context = record.get("context")
    if not isinstance(context, dict) or context.get("kind") != "pr":
        fail("prior-art receipt has no PR context")
    if not isinstance(context.get("repo"), str) or context["repo"].lower() != args.repo.lower():
        fail("prior-art receipt targets a different repository")
    if not SHA.fullmatch(args.head):
        fail("published head is not a full commit SHA")
    if args.published:
        scanned = context.get("head")
        if not isinstance(scanned, str) or not SHA.fullmatch(scanned) or not REPO.fullmatch(args.repo):
            fail("prior-art receipt has no valid scanned head")
        if scanned != args.head and api(f"repos/{args.repo}/compare/{scanned}...{args.head}", ".status") != "ahead":
            fail("prior-art receipt is stale: published head does not descend from the scanned head")
    elif context.get("head") != args.head or git("rev-parse", "HEAD") != args.head:
        fail("prior-art receipt is stale: published head changed")
    base = context.get("base")
    if not isinstance(base, str) or not base:
        fail("prior-art receipt has no PR base")
    if not args.published:
        diff = git("diff", "--no-ext-diff", "--find-renames", f"{base}...HEAD", "--")
        if hashlib.sha256(diff.encode()).hexdigest() != context.get("diff_sha256"):
            fail("prior-art receipt is stale: branch diff changed")
    decided(record, fresh=not args.published)
    print("prior-art receipt ok")


def section(record):
    lines = ["## Prior art checked", "", f"Checked {record['captured_at']} in https://github.com/{record['context']['repo']}."]
    if not record["candidates"]:
        lines.append("No matching open pull requests or issues, or recent closed unmerged pull requests, were found by search.")
    for item in record["candidates"]:
        lines.append(f"- {item['url']} by @{item['author']} ({item['state']} {item['kind']}): {item['verdict']} - {item['reason']}")
    if record["coverage"]["truncated"]:
        lines.append("Search coverage was bounded: only the most relevant hits per query were read"
                     + (f"; skipped queries: {', '.join(record['coverage']['dropped_queries'])}." if record["coverage"]["dropped_queries"] else "."))
    if record["verdict"] == "overlaps":
        lines.append(f"Captain decision: {record['captain_decision']}")
    return "\n".join(lines) + "\n"


def publish(args):
    record = checked(args)
    owner, branch = args.head.split(":", 1) if args.head and ":" in args.head else ("", "")
    if not owner or not REPO.fullmatch(f"{owner}/{args.repo.split('/', 1)[1]}") or not branch:
        fail("PR publication needs --head OWNER:BRANCH")
    remote_head = api(
        f"repos/{owner}/{args.repo.split('/', 1)[1]}/git/ref/heads/{quote(branch, safe='/')}" ,
        selector=".object.sha",
    )
    if not isinstance(remote_head, str) or remote_head != record["context"]["head"]:
        fail("prior-art receipt is stale: remote branch head changed")
    body = Path(args.body_file).read_text(encoding="utf-8")
    if "## Prior art checked" in body:
        fail("body already contains a Prior art checked section")
    complete = body.rstrip() + "\n\n" + section(record)
    fd, body_path = tempfile.mkstemp(prefix="fm-prior-art-body-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(complete)
        command = ["gh-axi", "pr", "create", "-R", args.repo,
                   "--title", args.title, "--body-file", body_path]
        command += ["--base", args.base, "--head", args.head]
        print(run(command).strip())
    finally:
        os.unlink(body_path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("scan", "check", "publish"):
        sub = commands.add_parser(name)
        sub.add_argument("--repo", required=True)
        sub.add_argument("--title", required=True)
        sub.add_argument("--summary-file", required=True)
        sub.add_argument("--record", required=True)
        sub.add_argument("--base", required=True)
        if name == "publish":
            sub.add_argument("--body-file", required=True)
            sub.add_argument("--head")
    sub = commands.add_parser("decide")
    sub.add_argument("--record", required=True)
    sub.add_argument("--decisions-file", required=True)
    sub = commands.add_parser("verify")
    sub.add_argument("--record", required=True)
    sub.add_argument("--repo", required=True)
    sub.add_argument("--head", required=True)
    sub.add_argument("--published", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "scan":
            scan(args)
        elif args.command == "decide":
            decide(args)
        elif args.command == "check":
            checked(args)
            print("prior-art check ok")
        elif args.command == "verify":
            verify_receipt(args)
        else:
            publish(args)
    except (ValueError, OSError) as error:
        print(f"prior-art refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

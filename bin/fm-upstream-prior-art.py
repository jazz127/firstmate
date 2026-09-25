#!/usr/bin/env python3
"""Find prior upstream work and gate publication of a PR.

Usage: fm-upstream-prior-art.py scan --repo OWNER/REPO
         --title TEXT --summary-file FILE --record FILE --base REF
       fm-upstream-prior-art.py decide --record FILE --decisions-file FILE
       fm-upstream-prior-art.py check --record FILE --repo OWNER/REPO
         --title TEXT --summary-file FILE --base REF
       fm-upstream-prior-art.py publish [check options] --body-file FILE
         [--head OWNER:BRANCH]

The record is a local JSON receipt, not a forge write. The decisions file is
JSON with verdict (none-found, distinct, overlaps), items keyed by candidate
URL with verdict and one-line reason, and captain_decision when overlaps.
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
from pathlib import Path
from urllib.parse import quote

SCHEMA = "fm-upstream-prior-art.v1"
FRESH_SECONDS = 3600
CLOSED_DAYS = 30
MAX_PAGES = 100
PAGE_SIZE = 100
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SHA = re.compile(r"^[a-f0-9]{40,64}$")
WORD = re.compile(r"[A-Za-z][A-Za-z0-9_]{3,}")
STOP = {"about", "after", "again", "also", "before", "change", "changes", "could", "from", "have", "into", "issue", "more", "pull", "request", "should", "that", "their", "there", "these", "this", "when", "with", "would"}


def fail(message):
    raise ValueError(message)


def run(command, *, input_text=None):
    result = subprocess.run(command, input=input_text, text=True, capture_output=True, check=False)
    if result.returncode:
        fail(f"command failed ({' '.join(command[:2])}): {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def git(*args):
    return run(["git", *args]).strip()


def api(path, selector="."):
    # gh-axi's bounded envelope needs a selector to return unambiguous JSON.
    output = run(["gh-axi", "api", path, "--jq", f"({selector})|@base64"])
    match = re.search(r"^  body: ([A-Za-z0-9+/=]+)$", output, re.M)
    if not match or not re.search(r"^  truncated: false$", output, re.M):
        fail(f"unreadable or truncated GitHub response: {path}")
    try:
        return json.loads(base64.b64decode(match.group(1), validate=True))
    except (ValueError, json.JSONDecodeError) as error:
        fail(f"invalid GitHub JSON for {path}: {error}")


def pages(path, *, stop_at=None, selector="."):
    rows = []
    for page in range(1, MAX_PAGES + 1):
        sep = "&" if "?" in path else "?"
        part = api(f"{path}{sep}per_page={PAGE_SIZE}&page={page}", selector)
        if not isinstance(part, list):
            fail(f"GitHub list was not an array: {path}")
        rows.extend(part)
        if stop_at and any(stop_at(row) for row in part):
            return rows
        if len(part) < PAGE_SIZE:
            return rows
    fail(f"GitHub pagination cap reached: {path}")


def search_pages(search):
    rows = []
    for page in range(1, 11):
        result = api(f"search/issues?q={quote(search)}&per_page=100&page={page}")
        if not isinstance(result, dict) or not isinstance(result.get("items"), list):
            fail("GitHub search response was incomplete")
        if result.get("incomplete_results") or not isinstance(result.get("total_count"), int):
            fail(f"GitHub search was incomplete: {search}")
        rows.extend(result["items"])
        if len(rows) >= result["total_count"]:
            return rows
        if len(result["items"]) < 100:
            fail(f"GitHub search result count was inconsistent: {search}")
    fail(f"GitHub search exceeded the 1,000-result limit: {search}")


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


def normalized(row, kind):
    return {"url": row.get("html_url", ""), "author": (row.get("user") or {}).get("login", ""),
            "state": row.get("state", ""), "title": row.get("title", ""),
            "body": row.get("body") or "", "number": row.get("number"), "kind": kind,
            "reasons": [], "files": []}


def scan(args):
    ctx = context(args)
    now = dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(days=CLOSED_DAYS)
    repo = ctx["repo"]
    diff = git("diff", "--no-ext-diff", f"{ctx['base']}...HEAD", "--")
    queries = terms(ctx, diff)
    found = {}
    open_pr_urls = set()

    def add(row, kind):
        candidate = normalized(row, kind)
        if not candidate["url"].startswith(f"https://github.com/{repo}/"):
            fail("GitHub returned a candidate outside the requested repository")
        if not candidate["author"] or not candidate["number"]:
            fail("GitHub returned an incomplete candidate")
        found.setdefault(candidate["url"], candidate)

    for row in pages(f"repos/{repo}/pulls?state=open"):
        add(row, "pr")
        open_pr_urls.add(row["html_url"])
    closed = pages(f"repos/{repo}/pulls?state=closed&sort=updated&direction=desc",
                   stop_at=lambda row: (row.get("updated_at") or "") < cutoff.isoformat().replace("+00:00", "Z"))
    for row in closed:
        try:
            closed_at = dt.datetime.fromisoformat((row.get("closed_at") or "").replace("Z", "+00:00"))
        except ValueError:
            fail("closed PR has invalid closed_at")
        if row.get("merged_at") is None and closed_at >= cutoff:
            add(row, "pr")
    for row in pages(f"repos/{repo}/issues?state=open"):
        if "pull_request" not in row:
            add(row, "issue")

    for query in queries:
        for kind, qualifier in (("pr", "is:pr"), ("issue", "is:issue")):
            search = f"repo:{repo} {qualifier} is:open {query}"
            for row in search_pages(search):
                if row.get("state") != "open":
                    continue
                add(row, kind)
                reason = f"keyword search: {query}"
                candidate = found[row["html_url"]]
                if reason not in candidate["reasons"]:
                    candidate["reasons"].append(reason)

    linked = issue_numbers(ctx["title"] + "\n" + ctx["summary"] + "\n" + diff, repo)
    own_words = set(w.lower() for w in WORD.findall(ctx["title"] + " " + ctx["summary"]) if w.lower() not in STOP)
    selected = []
    for candidate in found.values():
        if candidate["kind"] == "pr":
            candidate["files"] = [item.get("filename", "") for item in pages(
                f"repos/{repo}/pulls/{candidate['number']}/files", selector="[.[]|{{filename:.filename}}]" )]
            shared = sorted(set(ctx["files"]) & set(candidate["files"]))
            if shared:
                candidate["reasons"].append("shared files: " + ", ".join(shared))
        overlap = sorted(linked & issue_numbers(candidate["title"] + "\n" + candidate["body"], repo))
        if overlap:
            candidate["reasons"].append("linked issues: " + ", ".join("#" + n for n in overlap))
        shared_words = sorted(own_words & {w.lower() for w in WORD.findall(candidate["title"] + " " + candidate["body"]) if w.lower() not in STOP})
        if len(shared_words) >= 2:
            candidate["reasons"].append("shared keywords: " + ", ".join(shared_words[:8]))
        if candidate["reasons"]:
            selected.append({key: candidate[key] for key in ("url", "author", "state", "title", "kind", "reasons")}
                       | {"verdict": "unreviewed", "reason": ""})
    selected.sort(key=lambda row: row["url"])
    open_prs_matched = sum(1 for row in selected if row["kind"] == "pr" and row["url"] in open_pr_urls)
    record = {"schema": SCHEMA, "captured_at": now.isoformat(), "closed_window_days": CLOSED_DAYS,
              "context": ctx, "queries": queries, "open_prs": {"listed": len(open_pr_urls), "matched": open_prs_matched},
              "candidates": selected, "verdict": "pending", "captain_decision": ""}
    atomic_json(args.record, record)
    print(f"prior-art scan recorded {len(selected)} candidates: {args.record}")


def decide(args):
    record = read_json(args.record)
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        fail("unrecognized prior-art record schema")
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


def checked(args):
    record = read_json(args.record)
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        fail("unrecognized prior-art record schema")
    if record.get("context") != context(args):
        fail("prior-art record is stale: target, text, branch head, base, or diff changed")
    try:
        captured = dt.datetime.fromisoformat(record["captured_at"])
    except (KeyError, ValueError, TypeError):
        fail("prior-art record has no valid capture time")
    age = (dt.datetime.now(dt.timezone.utc) - captured).total_seconds()
    if age < 0 or age > FRESH_SECONDS:
        fail("prior-art record is stale: scan is older than one hour")
    verdict = record.get("verdict")
    candidates = candidate_records(record)
    captain_decision = record.get("captain_decision")
    if not isinstance(captain_decision, str):
        fail("prior-art captain decision is malformed")
    if verdict == "none-found" and candidates:
        fail("none-found record has candidates")
    if verdict not in ("none-found", "distinct", "overlaps"):
        fail("prior-art verdict is missing")
    if verdict != "none-found":
        if not candidates or any(c.get("verdict") not in ("distinct", "overlaps") or not c.get("reason") for c in candidates):
            fail("prior-art candidate decisions are incomplete")
        if (verdict == "overlaps") != any(c["verdict"] == "overlaps" for c in candidates):
            fail("prior-art candidate verdicts conflict")
    if verdict == "overlaps" and not captain_decision.strip():
        fail("prior-art overlaps require a recorded captain decision")
    return record


def verify_receipt(args):
    record = read_json(args.record)
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        fail("unrecognized prior-art record schema")
    context = record.get("context")
    if not isinstance(context, dict) or context.get("kind") != "pr":
        fail("prior-art receipt has no PR context")
    if context.get("repo") != args.repo:
        fail("prior-art receipt targets a different repository")
    if not SHA.fullmatch(args.head):
        fail("published head is not a full commit SHA")
    if context.get("head") != args.head or (not args.published and git("rev-parse", "HEAD") != args.head):
        fail("prior-art receipt is stale: published head changed")
    base = context.get("base")
    if not isinstance(base, str) or not base:
        fail("prior-art receipt has no PR base")
    if not args.published:
        diff = git("diff", "--no-ext-diff", "--find-renames", f"{base}...HEAD", "--")
        if hashlib.sha256(diff.encode()).hexdigest() != context.get("diff_sha256"):
            fail("prior-art receipt is stale: branch diff changed")
    try:
        captured = dt.datetime.fromisoformat(record["captured_at"])
    except (KeyError, ValueError, TypeError):
        fail("prior-art record has no valid capture time")
    age = (dt.datetime.now(dt.timezone.utc) - captured).total_seconds()
    if age < 0 or age > FRESH_SECONDS:
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
            not isinstance(candidate, dict)
            or candidate.get("verdict") not in ("distinct", "overlaps")
            or not isinstance(candidate.get("reason"), str)
            or not candidate["reason"].strip()
            for candidate in candidates
        ):
            fail("prior-art candidate decisions are incomplete")
        if (verdict == "overlaps") != any(candidate["verdict"] == "overlaps" for candidate in candidates):
            fail("prior-art candidate verdicts conflict")
    if verdict == "overlaps" and not captain_decision.strip():
        fail("prior-art overlaps require a recorded captain decision")
    print("prior-art receipt ok")


def section(record):
    lines = ["## Prior art checked", "", f"Checked {record['captured_at']} in https://github.com/{record['context']['repo']}."]
    if not record["candidates"]:
        lines.append("No matching open pull requests or issues, or recent unmerged pull requests, were found.")
    for item in record["candidates"]:
        lines.append(f"- {item['url']} by @{item['author']} ({item['state']} {item['kind']}): {item['verdict']} - {item['reason']}")
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

#!/usr/bin/env python3
"""GitHub observation and pointer projection for fm-pr-feedback.sh (the owner)."""

import base64
import hashlib
import json
from pathlib import Path
import re
import signal
import subprocess
import sys


TOKEN = re.compile(r"[A-Za-z0-9_-]+\Z")
SHA = re.compile(r"[a-f0-9]{40}\Z")
STAMP = re.compile(r"[0-9]{4}-[0-9T:.+Z-]+\Z")
EVENT_PREFIXES = ("GitHub PR feedback event:", "GitHub PR CI event:",
                  "No-mistakes gate event:", "No-mistakes outcome event:")


def run(argv, *, timeout=12):
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise ValueError("command failed: " + Path(argv[0]).name)
    return result.stdout


def api(path, selector):
    # gh-axi's bounded envelope must be complete, never silently truncated.
    raw = run(["gh-axi", "api", path, "--jq", f"({selector})|tojson|@base64"])
    match = re.search(r"^  body: ([A-Za-z0-9+/=]+)$", raw, re.M)
    if not match or not re.search(r"^  truncated: false$", raw, re.M):
        raise ValueError("unreadable GitHub response")
    return json.loads(base64.b64decode(match[1], validate=True))


def pages(path, fields, collection="."):
    # Small server pages bound gh-axi's envelope even for long login names.
    result = []
    page = 1
    while True:
        sep = "&" if "?" in path else "?"
        rows = api(f"{path}{sep}per_page=10&page={page}",
                   f"[{collection}[] | {fields}]")
        if not isinstance(rows, list):
            raise ValueError("invalid GitHub page")
        result.extend(rows)
        if len(rows) < 10:
            return result
        page += 1


def meta_read(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("unsafe task metadata")
    raw = path.read_bytes()
    fields = {}
    for line in raw.decode().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value
    return fields, hashlib.sha256(raw).hexdigest()


def history(state, task):
    seen = set()
    inbox = state / f"{task}.inbox"
    for directory in (inbox, inbox / "handled"):
        if directory.is_symlink():
            raise ValueError("unsafe task inbox")
        for record in directory.glob("*.msg"):
            if record.is_symlink() or not record.is_file():
                raise ValueError("unsafe task inbox record")
            try:
                body = record.read_text().split("\n--\n", 1)[1]
            except FileNotFoundError:
                # Acknowledgement may rename between glob and open.
                moved = inbox / "handled" / record.name
                if moved.is_file() and not moved.is_symlink():
                    body = moved.read_text().split("\n--\n", 1)[1]
                else:
                    continue
            seen.update(line for line in body.splitlines() if line.startswith(EVENT_PREFIXES))
    return seen


def scalar(block, key):
    match = re.search(rf"^  {re.escape(key)}: (.*)$", block, re.M)
    if not match:
        return ""
    value = match[1].strip()
    return json.loads(value) if value.startswith('"') else value


def pipeline_events(text):
    run_id = scalar(text, "id")
    if not run_id or not TOKEN.fullmatch(run_id):
        return [], ""
    pr = scalar(text, "pr")
    # Only a structural gate, not elapsed/awaiting-agent text, wakes the worker.
    gate = re.search(r"^gate:\n((?:[ \t].*\n|\n)*)", text + "\n", re.M)
    events = []
    if gate:
        step = scalar(gate[1], "step")
        status = scalar(gate[1], "status")
        if TOKEN.fullmatch(step) and status in ("awaiting_approval", "fix_review"):
            digest = hashlib.sha256(gate[1].encode()).hexdigest()
            events.append(f"No-mistakes gate event: run={run_id} step={step} receipt={digest}")
    outcome = re.search(r"^outcome: ([A-Za-z_-]+)$", text, re.M)
    if outcome and outcome[1] in ("passed", "passed_with_skips", "failed", "cancelled"):
        events.append(f"No-mistakes outcome event: run={run_id} outcome={outcome[1]}")
    return events, pr


def feedback(url, login, bridge):
    path, number = run([bridge, "github", url]).splitlines()
    root = f"repos/{path}"
    pull = f"{root}/pulls/{number}"
    core = api(pull, '{state,head:.head.sha}')
    if core.get("state") != "open":
        return [], "", root
    head = core.get("head", "")
    if not isinstance(head, str) or not SHA.fullmatch(head):
        raise ValueError("invalid PR head")
    events = []
    for endpoint, kind, anchor in (
        (pull + "/reviews", "review", "pullrequestreview-"),
        (pull + "/comments", "inline-comment", "discussion_r"),
        (f"{root}/issues/{number}/comments", "conversation-comment", "issuecomment-"),
    ):
        fields = '{id,login:.user.login,at:(.updated_at // .submitted_at),state:(.state // "")}'
        for row in pages(endpoint, fields):
            author = row.get("login")
            if author is not None and not isinstance(author, str):
                raise ValueError("missing feedback author")
            if author is not None and author.casefold() == login.casefold():
                continue
            if kind == "review" and row.get("state") == "PENDING":
                continue
            item = row.get("id")
            at = row.get("at")
            if type(item) is not int or item < 1 or not isinstance(at, str) or not STAMP.fullmatch(at):
                raise ValueError("invalid feedback identity")
            digest = hashlib.sha256(json.dumps([kind, item, at, row.get("state")]).encode()).hexdigest()
            events.append(f"GitHub PR feedback event: {kind} {url}#{anchor}{item} receipt={digest}")

    return events, head, root


def ci_events(url, head, root):
    checks = pages(f"{root}/commits/{head}/check-runs?filter=latest",
                   '{id,status,conclusion}', ".check_runs")
    statuses = pages(f"{root}/commits/{head}/status", '{id,state}', ".statuses")
    for row in checks + statuses:
        if type(row.get("id")) is not int or row["id"] < 1:
            raise ValueError("invalid CI identity")
    conclusions = []
    for row in checks:
        conclusions.append(row.get("conclusion") if row.get("status") == "completed" else "pending")
    conclusions.extend(row.get("state") for row in statuses)
    if any(value in ("failure", "error", "cancelled", "timed_out", "action_required", "startup_failure")
           for value in conclusions):
        state = "red"
    elif conclusions and all(value in ("success", "neutral", "skipped") for value in conclusions):
        state = "green"
    else:
        return []
    # Starting a queued check is not a new result. Stable sorting also ignores
    # API enumeration order, while rerun IDs and changed conclusions survive.
    projection = sorted((str(row.get("id")), row.get("conclusion") if row.get("status") == "completed"
                         else "pending") for row in checks)
    projection += sorted((str(row.get("id")), row.get("state")) for row in statuses)
    digest = hashlib.sha256(json.dumps([head, projection]).encode()).hexdigest()
    return [f"GitHub PR CI event: {url} head={head} state={state} receipt={digest}"]


def poll(state, bridge):
    delivered, relaunch, errors = set(), set(), set()
    paths = sorted(state.glob("*.meta"))
    pending = {path.stem for path in paths
               if re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", path.stem)}

    def report(interrupted=False):
        if delivered or errors or interrupted:
            print("pr-feedback batch: tasks=" + (",".join(sorted(delivered)) or "none")
                  + " relaunch=" + (",".join(sorted(relaunch)) or "none")
                  + " errors=" + (",".join(sorted(errors)) or "none")
                  + (" interrupted=" + (",".join(sorted(pending)) or "none")
                     + "; inspect pending inboxes and increase FM_CHECK_TIMEOUT for this sweep"
                     if interrupted else ""), flush=True)

    def stop(_signum, _frame):
        # The existing watcher bounds the entire custom-check process group.
        # Flush unfinished work before its kill grace, rather than silently
        # starving the same later tasks on every over-budget sweep.
        report(interrupted=True)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    login = None
    for path in paths:
        task = path.stem
        if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", task):
            continue
        try:
            meta, digest = meta_read(path)
            if meta.get("kind") != "ship" or meta.get("remote_host"):
                continue
            events = []
            url = meta.get("pr", "")
            if meta.get("mode") == "no-mistakes":
                try:
                    text = run([bridge, "pipeline", task])
                    pipeline, run_pr = pipeline_events(text)
                    events.extend(pipeline)
                    if not url:
                        url = run_pr
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    # A daemon read failure cannot suppress forge feedback for
                    # an already registered PR. Firstmate sees it in the batch.
                    errors.add(task)
            if url.startswith("https://github.com/"):
                try:
                    if login is None:
                        login = api("user", ".login")
                        if not isinstance(login, str) or not login:
                            raise ValueError("GitHub login unavailable")
                    comments, head, root = feedback(url, login, bridge)
                    events.extend(comments)
                    if head:
                        events.extend(ci_events(url, head, root))
                except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
                    errors.add(task)
            seen = history(state, task)
            fresh = list(dict.fromkeys(event for event in events if event not in seen))
            if fresh:
                message = "Firstmate event batch:\n" + "\n".join(fresh) + (
                    "\nRead the linked feedback and reattach once to any existing no-mistakes run "
                    "for its current gate or CI-ready return. Follow your brief; ask-user findings "
                    "still go to firstmate. This notification does not authorize a merge. "
                    "Further events arrive through this inbox; do not poll on a timer.")
                result = run([bridge, "deliver", task, digest, message])
                delivered.add(task)
                if result.strip() == "relaunch":
                    relaunch.add(task)
        except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.TimeoutExpired):
            errors.add(task)
        finally:
            pending.discard(task)
    report()


if __name__ == "__main__":
    poll(Path(sys.argv[1]), sys.argv[2])

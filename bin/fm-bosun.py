#!/usr/bin/env python3
"""Bosun routing, scoped evidence, and maneuver contribution records.

Usage: fm-bosun.py route|configure-home|order|convention|conventions|extract|guard|published|review|merged ...
All state is private to FM_HOME. Extract fetches the named upstream Git remote;
no command calls a forge API or pushes.
The publishing worker must run guard immediately before its existing delivery
path; fm-pr-check.sh also refuses registration without a matching order.
"""

import argparse
import datetime as dt
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


class Refusal(Exception):
    pass


def fail(message):
    raise Refusal(message)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def home():
    return Path(os.environ.get("FM_HOME", Path(__file__).resolve().parent.parent))


def read_json(path, default=None):
    if path.is_symlink():
        fail(f"unsafe symlink: {path}")
    if not path.exists():
        if default is not None:
            return default
        fail(f"missing record: {path}")
    if not path.is_file() or path.stat().st_size > 1048576:
        fail(f"invalid record: {path}")
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        fail(f"invalid record: {path}: {exc}")


def write_json(path, value):
    if path.is_symlink() or path.parent.is_symlink():
        fail(f"unsafe destination: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def safe_name(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) or value in (".", ".."):
        fail(f"invalid name: {value}")
    return value


def target(forge, owner, repo):
    for value in (forge, owner, repo):
        safe_name(value)
    return {"forge": forge.lower(), "owner": owner.lower(), "repository": repo.lower()}


def routes():
    data = read_json(home() / "config/bosun-routes.json", {"schema": "fm-bosun-routes.v1", "routes": []})
    if data.get("schema") != "fm-bosun-routes.v1" or not isinstance(data.get("routes"), list):
        fail("invalid Bosun route schema")
    return data["routes"]


def resolve(want):
    matches = []
    for row in routes():
        if not isinstance(row, dict) or not isinstance(row.get("bosun"), str):
            fail("invalid Bosun route")
        bosun = safe_name(row["bosun"])
        fields = (row.get("forge"), row.get("owner"), row.get("repository"), row.get("repository_pattern"))
        if not any(fields):
            fail("unscoped Bosun route")
        if row.get("repository") and row.get("repository_pattern"):
            fail("route cannot combine repository and repository_pattern")
        if any(v is not None and (not isinstance(v, str) or not v) for v in fields):
            fail("invalid Bosun route field")
        if row.get("forge") and row["forge"].lower() != want["forge"]:
            continue
        if row.get("owner") and row["owner"].lower() != want["owner"]:
            continue
        if row.get("repository") and row["repository"].lower() != want["repository"]:
            continue
        if row.get("repository_pattern") and not fnmatch.fnmatchcase(want["repository"], row["repository_pattern"].lower()):
            continue
        # Exact repository beats pattern, which beats owner, which beats forge.
        # A constrained forge refines every other level. Equal scores refuse.
        score = (3 if row.get("repository") else 2 if row.get("repository_pattern") else 1 if row.get("owner") else 0,
                 bool(row.get("owner")), bool(row.get("forge")))
        matches.append((score, bosun))
    if not matches:
        fail("no Bosun matches; ask whether to create one")
    best = max(score for score, _ in matches)
    winners = [bosun for score, bosun in matches if score == best]
    if len(winners) != 1:
        fail("ambiguous Bosun route; needs-decision")
    return winners[0]


def registered(bosun):
    registry = home() / "data/secondmates.md"
    if registry.is_symlink() or not registry.is_file():
        fail("secondmate registry unavailable")
    parser = Path(__file__).resolve().parent / "fm-secondmate-registry-lib.sh"
    result = subprocess.run(["bash", "-c", '. "$1"; secondmate_registry_field "$2" "$3" home',
                             "_", str(parser), str(registry), bosun],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode or not result.stdout.strip():
        fail(f"Bosun {bosun} is not one registered secondmate")


def role(bosun):
    marker = home() / ".fm-secondmate-home"
    if marker.exists() and marker.is_file() and not marker.is_symlink():
        if marker.read_text().strip() != bosun:
            fail("Bosun identity differs from this secondmate home")
        path = home() / "data/bosun-role.json"
    else:
        registered(bosun)
        path = home() / "data/bosuns" / f"{bosun}.json"
    record = read_json(path)
    if record != {"schema": "fm-bosun-role.v1", "id": bosun, "kind": "bosun"}:
        fail(f"Bosun role record missing or invalid for {bosun}")


def contribution_path(task):
    return home() / "data" / safe_name(task) / "bosun-contribution.json"


def contribution(task):
    record = read_json(contribution_path(task))
    if record.get("schema") != "fm-bosun-contribution.v1" or record.get("task") != task:
        fail("invalid Bosun contribution record")
    return record


def cmd_route(args):
    want = target(args.forge, args.owner, args.repository)
    bosun = resolve(want)
    role(bosun)
    print(bosun)


def cmd_configure_home(args):
    marker = home() / ".fm-secondmate-home"
    if marker.exists() and marker.is_file() and not marker.is_symlink():
        if marker.read_text().strip() != args.bosun:
            fail("Bosun identity differs from this secondmate home")
        path = home() / "data/bosun-role.json"
    else:
        registered(args.bosun)
        path = home() / "data/bosuns" / f"{args.bosun}.json"
    write_json(path,
               {"schema": "fm-bosun-role.v1", "id": args.bosun, "kind": "bosun"})


def cmd_order(args):
    want = target(args.forge, args.owner, args.repository)
    if resolve(want) != args.bosun:
        fail("target routes to a different Bosun")
    role(args.bosun)
    if not args.captain_words.strip() or not args.path or not args.commit:
        fail("explicit captain words, scoped paths, and source commits are required")
    if args.source != f"housefeature/{safe_name(args.maneuver)}":
        fail("source must be the named durable housefeature branch")
    for path in args.path:
        if path.startswith("/") or path.startswith("../") or "/../" in path or path.startswith("."):
            fail(f"unsafe or private path: {path}")
    path = contribution_path(args.task)
    if path.exists() or path.is_symlink():
        fail("contribution order already exists")
    write_json(path, {"schema": "fm-bosun-contribution.v1", "task": args.task,
                      "maneuver": args.maneuver, "bosun": args.bosun, "target": want,
                      "captain_order": {"words": args.captain_words, "recorded_at": now()},
                      "source_branch": args.source, "source_commits": args.commit,
                      "allowed_paths": args.path, "contribution_branch": args.branch,
                      "validation_evidence": None, "upstream_pr": None,
                      "state": "ordered", "review_events": []})
    print(path)


def memory_path(bosun, scope, want):
    role(bosun)
    root = home() / "data/bosun-memory" / bosun
    if scope == "shared":
        return root / "profile.json"
    return root / "repos" / want["forge"] / want["owner"] / f"{want['repository']}.json"


def cmd_convention(args):
    want = target(args.forge, args.owner, args.repository)
    path = memory_path(args.bosun, args.scope, want)
    record = read_json(path, {"schema": "fm-bosun-memory.v1", "conventions": []})
    if record.get("schema") != "fm-bosun-memory.v1" or not isinstance(record.get("conventions"), list):
        fail("invalid Bosun memory")
    if args.confirmed and (not args.evidence or not args.showed or not args.read_at):
        fail("confirmed convention requires evidence source, finding, and read time")
    record["conventions"].append({"key": args.key, "value": args.value,
                                  "confirmed": args.confirmed, "source": args.evidence,
                                  "showed": args.showed, "read_at": args.read_at})
    write_json(path, record)


def cmd_conventions(args):
    want = target(args.forge, args.owner, args.repository)
    result = {}
    for scope in ("shared", "repository"):
        path = memory_path(args.bosun, scope, want)
        data = read_json(path, {"schema": "fm-bosun-memory.v1", "conventions": []})
        if data.get("schema") != "fm-bosun-memory.v1":
            fail("invalid Bosun memory")
        for item in data.get("conventions", []):
            if item.get("confirmed") and all(item.get(key) for key in ("source", "showed", "read_at")):
                result[item["key"]] = {"value": item["value"], "source": scope, "evidence": item}
    policy = read_json(Path(args.policy))
    if not isinstance(policy, dict):
        fail("policy fixture must be a key/value JSON object")
    for key, value in policy.items():
        result[key] = {"value": value, "source": "current_repository_policy"}
    decisions = read_json(Path(args.decisions), {}) if args.decisions else {}
    for key, value in decisions.items():
        if key in policy and policy[key] != value:
            fail(f"needs-decision: captain decision conflicts with current policy for {key}")
        result[key] = {"value": value, "source": "captain_decision"}
    print(json.dumps(result, sort_keys=True))


def git(repo, *arguments, input_bytes=None):
    result = subprocess.run(["git", "-C", str(repo), *arguments], input=input_bytes,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        fail(f"git {' '.join(arguments)}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def cmd_extract(args):
    record = contribution(args.task)
    repo = Path(args.repo).resolve()
    dest = Path(args.worktree).resolve()
    if record["state"] != "ordered":
        fail("extraction requires an ordered maneuver")
    existing = dest.exists()
    if existing:
        top = Path(git(dest, "rev-parse", "--show-toplevel").decode().strip()).resolve()
        primary = Path(git(dest, "worktree", "list", "--porcelain").decode().splitlines()[0][9:]).resolve()
        if top != dest or dest == primary or git(dest, "status", "--porcelain").strip():
            fail("existing destination must be a clean isolated worktree")
    if args.upstream_remote == "origin":
        fail("upstream remote must be explicit and distinct from the fork origin")
    git(repo, "fetch", args.upstream_remote, args.default_branch)
    upstream = f"{args.upstream_remote}/{args.default_branch}"
    base = git(repo, "rev-parse", upstream).decode().strip()
    git(repo, "show-ref", "--verify", f"refs/heads/{record['source_branch']}")
    commits = record["source_commits"]
    for commit in commits:
        resolved = git(repo, "rev-parse", f"{commit}^{{commit}}").decode().strip()
        if resolved != commit:
            fail("source commits must use exact full object IDs")
        git(repo, "merge-base", "--is-ancestor", commit, record["source_branch"])
        if len(git(repo, "rev-list", "--parents", "-n", "1", commit).split()) != 2:
            fail("merge commits cannot be extracted")
    if existing:
        git(dest, "switch", "--detach", base)
    else:
        git(repo, "worktree", "add", "--detach", str(dest), base)
    git(dest, "switch", "-c", record["contribution_branch"])
    for commit in commits:
        patch = git(repo, "diff", "--binary", f"{commit}^", commit, "--", *record["allowed_paths"])
        if not patch:
            fail(f"selected commit has no scoped change: {commit}")
        git(dest, "apply", "--index", "-", input_bytes=patch)
        author = git(repo, "show", "-s", "--format=%an <%ae>", commit).decode().strip()
        message = git(repo, "show", "-s", "--format=%B", commit).decode()
        git(dest, "-c", "user.name=Bosun", "-c", "user.email=bosun@localhost",
            "commit", "--author", author, "-m", message)
    record["upstream_base"] = base
    record["state"] = "extracted"
    write_json(contribution_path(args.task), record)
    print(dest)


def cmd_guard(args):
    record = contribution(args.task)
    want = target(args.forge or record["target"]["forge"],
                  args.owner or record["target"]["owner"],
                  args.repository or record["target"]["repository"])
    if record["target"] != want or record["bosun"] != resolve(want):
        fail("publication target differs from captain order or route")
    role(record["bosun"])
    if record["state"] not in ("extracted", "published"):
        fail("maneuver has not been cleanly extracted")
    repo = Path(args.repo).resolve()
    branch = git(repo, "branch", "--show-current").decode().strip()
    if branch != record["contribution_branch"]:
        fail("contribution branch differs from captain order")
    if git(repo, "status", "--porcelain").strip():
        fail("contribution worktree is dirty")
    base = record["upstream_base"]
    git(repo, "merge-base", "--is-ancestor", base, "HEAD")
    paths = git(repo, "diff", "--name-only", base, "HEAD").decode().splitlines()
    if not paths or any(path not in record["allowed_paths"] for path in paths):
        fail("contribution contains files outside the ordered maneuver")
    for path in paths:
        if any(part.startswith(".") or part in ("config", "data", "state", "projects", "secrets")
               for part in Path(path).parts):
            fail(f"house-only or private path in contribution: {path}")
    print("authorized: " + record["maneuver"])


def cmd_published(args):
    record = contribution(args.task)
    if record["state"] != "extracted" or not args.validation.strip():
        fail("extracted maneuver and validation evidence required")
    cmd_guard(args)
    want = record["target"]
    if want["forge"] == "github":
        expected = f"https://github.com/{want['owner']}/{want['repository']}/pull/"
    elif want["forge"] == "gitlab":
        expected = f"https://gitlab.com/{want['owner']}/{want['repository']}/-/merge_requests/"
    else:
        fail("this forge has no Bosun PR URL verifier")
    if not args.url.startswith(expected) or not args.url[len(expected):].isdigit():
        fail("upstream PR URL differs from captain order")
    record["validation_evidence"] = args.validation
    record["upstream_pr"] = args.url
    record["state"] = "published"
    write_json(contribution_path(args.task), record)


def cmd_review(args):
    record = contribution(args.task)
    if record["state"] != "published" or not args.source or not args.summary:
        fail("published contribution and review evidence required")
    if args.kind in ("scope-change", "ambiguous", "policy-conflict", "consequential"):
        fail(f"needs-decision: {args.kind}; route through the secondmate parent channel")
    record["review_events"].append({"source": args.source, "summary": args.summary,
                                    "at": now(), "kind": "routine"})
    write_json(contribution_path(args.task), record)


def cmd_merged(args):
    path = contribution_path(args.task)
    if not path.exists():
        return
    record = contribution(args.task)
    if record["upstream_pr"] != args.url or record["state"] not in ("published", "admirals-maneuver"):
        fail("merge URL does not match published maneuver")
    if record["state"] == "admirals-maneuver":
        return
    record["state"] = "admirals-maneuver"
    record["admirals_maneuver_at"] = now()
    write_json(path, record)


def cmd_registration_check(args):
    marker = home() / ".fm-secondmate-home"
    if not marker.exists():
        return
    bosun = marker.read_text().strip()
    role_file = home() / "data/bosun-role.json"
    if not role_file.exists():
        return
    role(bosun)
    record = contribution(args.task)
    if record["bosun"] != bosun or record["state"] != "published" or record["upstream_pr"] != args.url:
        fail("Bosun PR registration requires a matching published captain order")
    if not record["validation_evidence"]:
        fail("Bosun PR registration requires validation evidence")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    target_options = (("--forge", True), ("--owner", True), ("--repository", True))
    def add_target(p, required=True):
        for option, _ in target_options:
            p.add_argument(option, required=required)
    p = sub.add_parser("route"); add_target(p); p.set_defaults(func=cmd_route)
    p = sub.add_parser("configure-home"); p.add_argument("--bosun", required=True); p.set_defaults(func=cmd_configure_home)
    p = sub.add_parser("order"); add_target(p)
    for name in ("task", "bosun", "maneuver", "source", "branch", "captain-words"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--path", action="append", default=[])
    p.add_argument("--commit", action="append", default=[])
    p.set_defaults(func=cmd_order)
    p = sub.add_parser("convention"); add_target(p)
    for name in ("bosun", "scope", "key", "value"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--evidence"); p.add_argument("--showed"); p.add_argument("--read-at")
    p.add_argument("--confirmed", action="store_true"); p.set_defaults(func=cmd_convention)
    p = sub.add_parser("conventions"); add_target(p)
    p.add_argument("--bosun", required=True); p.add_argument("--policy", required=True)
    p.add_argument("--decisions"); p.set_defaults(func=cmd_conventions)
    p = sub.add_parser("extract")
    for name in ("task", "repo", "worktree", "upstream-remote", "default-branch"):
        p.add_argument("--" + name, required=True)
    p.set_defaults(func=cmd_extract)
    for command, func in (("guard", cmd_guard), ("published", cmd_published)):
        p = sub.add_parser(command); add_target(p, required=False)
        p.add_argument("--task", required=True); p.add_argument("--repo", required=True)
        if command == "published":
            p.add_argument("--url", required=True); p.add_argument("--validation", required=True)
        p.set_defaults(func=func)
    p = sub.add_parser("review"); p.add_argument("--task", required=True)
    p.add_argument("--kind", choices=("routine", "scope-change", "ambiguous", "policy-conflict", "consequential"), required=True)
    p.add_argument("--source", required=True); p.add_argument("--summary", required=True)
    p.set_defaults(func=cmd_review)
    p = sub.add_parser("merged"); p.add_argument("--task", required=True); p.add_argument("--url", required=True)
    p.set_defaults(func=cmd_merged)
    p = sub.add_parser("registration-check"); p.add_argument("--task", required=True)
    p.add_argument("--url", required=True); p.set_defaults(func=cmd_registration_check)
    args = parser.parse_args()
    try:
        args.func(args)
    except Refusal as exc:
        print(f"fm-bosun: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

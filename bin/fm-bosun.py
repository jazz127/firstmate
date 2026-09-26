#!/usr/bin/env python3
"""Bosun routing, scoped memory, and contribution authorization records."""

import argparse
import datetime as dt
import fcntl
import fnmatch
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

SUPPORTED_FORGES = {"github"}


class Refusal(Exception):
    pass


def fail(message):
    raise Refusal(message)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def home():
    return Path(os.environ.get("FM_HOME", Path(__file__).resolve().parent.parent))


def safe_path(path):
    path = Path(path).absolute()
    root = home().absolute()
    try:
        relative = path.relative_to(root)
    except ValueError:
        return path
    current = root
    if current.is_symlink():
        fail(f"unsafe symlink: {current}")
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            fail(f"unsafe symlink: {current}")
    return path


def read_json(path, default=None):
    path = safe_path(path)
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
    path = safe_path(path)
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


def write_text(path, value):
    path = safe_path(path)
    if path.is_symlink() or path.parent.is_symlink():
        fail(f"unsafe destination: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(value)
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def safe_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) or value in (".", ".."):
        fail(f"invalid name: {value}")
    return value


def safe_relative_path(value):
    if (not isinstance(value, str) or not value or value.startswith("/") or value in (".", "..")
            or value.startswith("../") or "/../" in value or value.endswith("/..")):
        fail(f"unsafe or private path: {value}")
    return value


def parse_deviations(values):
    result = []
    for value in values:
        path, separator, reason = value.partition("=")
        if not separator or not reason.strip():
            fail(f"invalid extraction deviation: {value}")
        safe_relative_path(path)
        if "\n" in reason or "\r" in reason:
            fail(f"invalid extraction deviation: {value}")
        result.append({"path": path, "reason": reason})
    if len({item["path"] for item in result}) != len(result):
        fail("duplicate extraction deviation path")
    return result


def git_output(project_dir, *args):
    result = subprocess.run(["git", "-C", str(project_dir), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        return None
    return result.stdout.strip()


def forge_pr_identity(url):
    result = subprocess.run(
        ["gh", "pr", "view", url, "--json",
         "headRepositoryOwner,headRepository,baseRepository,baseRefName,headRefName,headRefOid"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        fail("upstream PR forge response was unreadable during final registration")
    try:
        data = json.loads(result.stdout)
        identity = {
            "head": f"{data['headRepositoryOwner']['login']}/{data['headRepository']['name']}",
            "base": data["baseRepository"]["nameWithOwner"],
            "branch": data["baseRefName"],
            "head_branch": data["headRefName"],
            "pr_head": data["headRefOid"],
        }
    except (KeyError, TypeError, ValueError):
        fail("upstream PR forge response was incomplete during final registration")
    if (not all(isinstance(value, str) and value for value in identity.values())
            or not re.fullmatch(r"[0-9a-fA-F]{40}", identity["pr_head"])):
        fail("upstream PR forge response was incomplete during final registration")
    return identity


def forge_pr_changed_paths(url):
    result = subprocess.run(["gh", "pr", "diff", url, "--name-only"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        fail("upstream PR changed paths were unreadable during final registration")
    return [path for path in result.stdout.splitlines() if path]


def git_success(project_dir, *args):
    return subprocess.run(["git", "-C", str(project_dir), *args],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def remote_identity(url):
    if url.startswith("git@"):
        host, _separator, path = url[4:].partition(":")
    else:
        parsed = urlparse(url)
        host, path = parsed.hostname, parsed.path
    if not host or host.lower() != "github.com":
        return None
    parts = path.rstrip("/").removesuffix(".git").strip("/").split("/")
    if len(parts) != 2:
        return None
    return tuple(item.lower() for item in parts)


def fork_source_ref(project_dir, fork_owner, fork_repository, source_branch):
    expected = (fork_owner.lower(), fork_repository.lower())
    remotes = git_output(project_dir, "remote")
    if not remotes:
        fail(f"configured fork remote is unavailable: {fork_owner}/{fork_repository}")
    for remote in remotes.splitlines():
        urls = git_output(project_dir, "config", "--get-all", f"remote.{remote}.url") or ""
        if not any(remote_identity(url) == expected for url in urls.splitlines()):
            continue
        result = subprocess.run(
            ["git", "-C", str(project_dir), "fetch", "--no-tags", remote,
             f"+refs/heads/{source_branch}:refs/remotes/{remote}/{source_branch}"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode:
            fail(f"could not fetch configured fork branch: {fork_owner}/{fork_repository}/{source_branch}")
        ref = f"refs/remotes/{remote}/{source_branch}"
        if git_output(project_dir, "rev-parse", "--verify", ref):
            return ref
        fail(f"configured fork branch is unavailable: {fork_owner}/{fork_repository}/{source_branch}")
    fail(f"configured fork remote is unavailable: {fork_owner}/{fork_repository}")


def upstream_remote(project_dir, owner, repository):
    expected = (owner.lower(), repository.lower())
    remotes = git_output(project_dir, "remote")
    for remote in (remotes or "").splitlines():
        urls = git_output(project_dir, "config", "--get-all", f"remote.{remote}.url") or ""
        if any(remote_identity(url) == expected for url in urls.splitlines()):
            return remote
    fail(f"upstream project clone targets another repository: {owner}/{repository}")


def fetched_upstream_ref(project_dir, owner, repository, branch):
    remote = upstream_remote(project_dir, owner, repository)
    result = subprocess.run(
        ["git", "-C", str(project_dir), "fetch", "--no-tags", remote,
         f"+refs/heads/{branch}:refs/remotes/{remote}/{branch}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        fail(f"could not fetch upstream branch: {owner}/{repository}/{branch}")
    ref = f"refs/remotes/{remote}/{branch}"
    if not git_output(project_dir, "rev-parse", "--verify", ref):
        fail(f"upstream branch is unavailable: {owner}/{repository}/{branch}")
    return ref


def target(forge, owner, repo):
    for value in (forge, owner, repo):
        safe_name(value)
    forge = forge.lower()
    if forge not in SUPPORTED_FORGES:
        fail(f"unsupported Bosun forge '{forge}'; supported: {', '.join(sorted(SUPPORTED_FORGES))}")
    return {"forge": forge, "owner": owner.lower(), "repository": repo.lower()}


def routes():
    data = read_json(home() / "config/bosun-routes.json", {"schema": "fm-bosun-routes.v1", "routes": []})
    if data.get("schema") != "fm-bosun-routes.v1" or not isinstance(data.get("routes"), list):
        fail("invalid Bosun route schema")
    for row in data["routes"]:
        forge = row.get("forge") if isinstance(row, dict) else None
        if forge and (not isinstance(forge, str) or forge.lower() not in SUPPORTED_FORGES):
            fail(f"unsupported Bosun forge '{forge}'; supported: {', '.join(sorted(SUPPORTED_FORGES))}")
    return data["routes"]


def resolve_route(want):
    matches = []
    for row in routes():
        if not isinstance(row, dict) or not isinstance(row.get("bosun"), str):
            fail("invalid Bosun route")
        bosun = safe_name(row["bosun"])
        match_fields = (row.get("forge"), row.get("owner"), row.get("repository"), row.get("repository_pattern"))
        metadata = (row.get("fork_owner"), row.get("fork_repository"), row.get("upstream_default_branch"))
        if not any(match_fields):
            fail("unscoped Bosun route")
        if row.get("repository") and row.get("repository_pattern"):
            fail("route cannot combine repository and repository_pattern")
        if any(v is not None and (not isinstance(v, str) or not v) for v in match_fields + metadata):
            fail("invalid Bosun route field")
        if row.get("forge") and row["forge"].lower() != want["forge"]:
            continue
        if row.get("owner") and row["owner"].lower() != want["owner"]:
            continue
        if row.get("repository") and row["repository"].lower() != want["repository"]:
            continue
        if row.get("repository_pattern") and not fnmatch.fnmatchcase(want["repository"], row["repository_pattern"].lower()):
            continue
        score = (3 if row.get("repository") else 2 if row.get("repository_pattern") else 1 if row.get("owner") else 0,
                 bool(row.get("owner")), bool(row.get("forge")))
        matches.append((score, row))
    if not matches:
        fail("no Bosun matches; ask whether to create one")
    best = max(score for score, _ in matches)
    winners = [row for score, row in matches if score == best]
    if len(winners) != 1:
        fail("ambiguous Bosun route; needs-decision")
    return winners[0]


def resolve(want):
    return resolve_route(want)["bosun"]


def registered(bosun):
    registry = safe_path(home() / "data/secondmates.md")
    if registry.is_symlink() or not registry.is_file():
        fail("secondmate registry unavailable")
    parser = Path(__file__).resolve().parent / "fm-secondmate-registry-lib.sh"
    result = subprocess.run(["bash", "-c", '. "$1"; secondmate_registry_field "$2" "$3" home',
                             "_", str(parser), str(registry), bosun],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode or not result.stdout.strip():
        fail(f"Bosun {bosun} is not one registered secondmate")


def role(bosun):
    marker = safe_path(home() / ".fm-secondmate-home")
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


def path_allowed(path, allowed):
    return any(path == item or item.endswith("/") and path.startswith(item) for item in allowed)


def unauthorized_tree_paths(project_dir, base, head, rewrite_paths):
    changed = git_output(project_dir, "diff", "--name-only", base, head)
    if changed is None:
        return None
    return [path for path in changed.splitlines() if path and not path_allowed(path, rewrite_paths)]


def validate_extraction(worktree, source_commits, actual_commits, merges, deviations, published_head=None):
    deviation_paths = [item["path"] for item in deviations]
    published = actual_commits
    if published_head:
        if published_head not in actual_commits:
            fail(f"published contribution history was rewritten: {published_head} is no longer in the PR")
        published = actual_commits[:actual_commits.index(published_head) + 1]
    linear = [commit for commit in published if commit not in merges]
    if len(linear) not in (1, len(source_commits)):
        fail(f"upstream PR has unrelated commit history: {', '.join(actual_commits)}")
    scratch = Path(tempfile.mkdtemp(prefix="fm-bosun-extraction-"))
    try:
        clone = subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout",
                                str(worktree), str(scratch / "repo")],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if clone.returncode:
            fail("could not create extraction worktree")
        scratch_repo = scratch / "repo"
        checkout = subprocess.run(["git", "-C", str(scratch_repo), "checkout", "--quiet", "--detach",
                                   f"{actual_commits[0]}^"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if checkout.returncode:
            fail("upstream extraction base is unavailable")
        identity = ["-c", "user.name=Bosun", "-c", "user.email=bosun@localhost"]
        pending = list(source_commits)
        for commit in actual_commits:
            if commit in merges:
                merge = subprocess.run(
                    ["git", "-C", str(scratch_repo), *identity, "merge", "--quiet", "--no-ff",
                     "--no-edit", *merges[commit]],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if merge.returncode:
                    subprocess.run(["git", "-C", str(scratch_repo), "merge", "--abort"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    fail(f"upstream PR merge {commit} conflicts with ordered extraction")
            elif commit not in published:
                follow_up = subprocess.run(
                    ["git", "-C", str(scratch_repo), "checkout", "--quiet", "--detach", commit],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if follow_up.returncode:
                    fail(f"upstream PR follow-up commit {commit} is unavailable")
                continue
            else:
                picks = pending if len(linear) == 1 else pending[:1]
                pending = pending[len(picks):]
                for source in picks:
                    cherry_pick = subprocess.run(
                        ["git", "-C", str(scratch_repo), *identity, "cherry-pick", source],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    if cherry_pick.returncode:
                        subprocess.run(["git", "-C", str(scratch_repo), "cherry-pick", "--abort"],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        fail("ordered source commits conflict with upstream; extraction needs a declared rewrite")
            offending = unauthorized_tree_paths(scratch_repo, "HEAD", commit, deviation_paths)
            if offending is None:
                fail(f"upstream PR commit {commit} cannot be compared with ordered progression")
            if offending:
                fail(f"upstream PR commit {commit} is not derived from ordered progression: "
                     f"{', '.join(offending)}")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def cmd_route(args):
    bosun = resolve(target(args.forge, args.owner, args.repository))
    role(bosun)
    print(bosun)


def cmd_configure_home(args):
    safe_name(args.bosun)
    marker = safe_path(home() / ".fm-secondmate-home")
    if marker.exists() and marker.is_file() and not marker.is_symlink():
        if marker.read_text().strip() != args.bosun:
            fail("Bosun identity differs from this secondmate home")
        path = home() / "data/bosun-role.json"
    else:
        registered(args.bosun)
        path = home() / "data/bosuns" / f"{args.bosun}.json"
    write_json(path, {"schema": "fm-bosun-role.v1", "id": args.bosun, "kind": "bosun"})


def cmd_order(args):
    want = target(args.forge, args.owner, args.repository)
    route = resolve_route(want)
    if route["bosun"] != args.bosun:
        fail("target routes to a different Bosun")
    role(args.bosun)
    if not args.captain_words.strip() or not args.path or not args.commit:
        fail("explicit captain words, scoped paths, and source commits are required")
    if args.source != f"housefeature/{safe_name(args.maneuver)}":
        fail("source must be the named durable housefeature branch")
    configured_owner = route.get("fork_owner")
    configured_repository = route.get("fork_repository") or args.fork_repository or want["repository"]
    if configured_owner and args.fork_owner and args.fork_owner.lower() != configured_owner.lower():
        fail(f"fork owner differs from route: expected {configured_owner}, got {args.fork_owner}")
    if configured_repository and args.fork_repository and args.fork_repository.lower() != configured_repository.lower():
        fail(f"fork repository differs from route: expected {configured_repository}, got {args.fork_repository}")
    fork_owner = configured_owner or args.fork_owner
    fork_repository = configured_repository
    default_branch = args.default_branch or route.get("upstream_default_branch")
    if not fork_owner or not fork_repository or not default_branch:
        fail("explicit fork identity and upstream default branch are required")
    safe_name(fork_owner)
    safe_name(fork_repository)
    safe_name(default_branch)
    project_dir = safe_path(home() / "projects" / want["repository"])
    if not project_dir.is_dir() or project_dir.is_symlink():
        fail(f"upstream project clone is unavailable: {project_dir}")
    upstream_remote(project_dir, want["owner"], want["repository"])
    source_ref = fork_source_ref(project_dir, fork_owner, fork_repository, args.source)
    if len(set(args.commit)) != len(args.commit):
        fail("source commit selection contains duplicates")
    previous = None
    for commit in args.commit:
        if not re.fullmatch(r"[0-9a-fA-F]{40}", commit):
            fail(f"invalid source commit: {commit}")
        if not git_success(project_dir, "merge-base", "--is-ancestor", commit, source_ref):
            fail(f"source commit is not reachable from configured fork branch {args.source}: {commit}")
        if previous and not git_success(project_dir, "merge-base", "--is-ancestor", previous, commit):
            fail("source commits must be ordered oldest-to-newest")
        previous = commit
    for path in args.path:
        safe_relative_path(path)
    path = contribution_path(args.task)
    with contribution_lock(args.task):
        if path.exists() or path.is_symlink():
            fail("contribution order already exists")
        write_json(path, {"schema": "fm-bosun-contribution.v1", "task": args.task,
                          "maneuver": args.maneuver, "bosun": args.bosun, "target": want,
                          "fork": {"owner": fork_owner.lower(), "repository": fork_repository.lower()},
                          "upstream_default_branch": default_branch,
                          "captain_order": {"words": args.captain_words, "recorded_at": now()},
                          "source_branch": args.source, "source_commits": args.commit,
                          "allowed_paths": args.path, "deviations": parse_deviations(args.deviation),
                          "contribution_branch": args.branch,
                          "validation_evidence": None, "upstream_pr": None,
                          "state": "ordered", "review_events": []})
    print(path)


def project_mode(project):
    root = Path(os.environ.get("FM_ROOT_OVERRIDE", Path(__file__).resolve().parent.parent))
    result = subprocess.run([str(root / "bin/fm-project-mode.sh"), "--raw", project],
                            cwd=home(), env=os.environ.copy(), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        fail(result.stderr.strip() or f"could not resolve delivery posture for {project}")
    fields = result.stdout.strip().split()
    if len(fields) != 2:
        fail(f"invalid delivery posture for {project}")
    mode, yolo = fields
    if mode == "no-mistakes-prod-only":
        mode = "no-mistakes"
    if mode not in ("no-mistakes", "direct-PR") or yolo not in ("on", "off"):
        fail(f"Bosun contribution requires a PR-capable delivery posture for {project}")
    return mode, yolo


def existing_task(task, project_dir, assignment_id, target_info):
    path = safe_path(home() / "state" / f"{safe_name(task)}.meta")
    if path.is_symlink() or not path.is_file():
        return None
    fields = {}
    try:
        for line in path.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator:
                fields[key] = value
    except OSError as exc:
        fail(f"could not read existing task record: {exc}")
    if not fields.get("worktree"):
        fail("existing task record has no worktree")
    if fields.get("endpoint_task_id") != task or fields.get("kind") != "ship":
        fail("existing task record does not match the Bosun ship")
    if fields.get("project") != str(project_dir):
        fail("existing task record targets another project")
    brief = safe_path(home() / "data" / task / "brief.md")
    if brief.is_symlink() or not brief.is_file():
        fail("existing task record has no Bosun brief")
    if f"Bosun assignment `{assignment_id}`" not in brief.read_text():
        fail("existing task record is not this Bosun assignment")
    worktree = Path(fields["worktree"])
    if worktree.is_symlink() or not worktree.is_dir():
        fail("existing Bosun worktree is unavailable")
    root = git_output(worktree, "rev-parse", "--show-toplevel")
    if not root or Path(root).resolve() == Path(project_dir).resolve():
        fail("existing Bosun worktree is not isolated")
    upstream_remote(worktree, target_info["owner"], target_info["repository"])
    return fields


@contextmanager
def contribution_lock(task):
    path = contribution_path(task)
    lock_path = safe_path(path.with_name(path.name + ".lock"))
    if lock_path.is_symlink() or lock_path.parent.is_symlink():
        fail(f"unsafe contribution lock: {lock_path}")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield
    except OSError as exc:
        fail(f"could not lock contribution record: {exc}")


def cmd_intake(args):
    with contribution_lock(args.task):
        return cmd_intake_locked(args)


def cmd_intake_locked(args):
    record = contribution(args.task)
    if record.get("state") != "ordered":
        fail("captain order has already been assigned or published")
    if not record.get("assignment_id"):
        record["assignment_id"] = secrets.token_hex(16)
        write_json(contribution_path(args.task), record)
    project = safe_name(record["target"]["repository"])
    project_dir = safe_path(home() / "projects" / project)
    if not project_dir.is_dir() or project_dir.is_symlink():
        fail(f"upstream project clone is unavailable: {project_dir}")
    upstream_remote(project_dir, record["target"]["owner"], record["target"]["repository"])
    adopted = existing_task(args.task, project_dir, record["assignment_id"], record["target"])
    if adopted:
        record["task_brief"] = str(safe_path(home() / "data" / args.task / "brief.md"))
        record["task_worktree"] = adopted["worktree"]
        record["task_mode"] = adopted.get("mode", record.get("task_mode", "no-mistakes"))
        record["task_yolo"] = adopted.get("yolo", record.get("task_yolo", "off"))
        record["assigned_at"] = record.get("assigned_at", now())
        record["state"] = "assigned"
        write_json(contribution_path(args.task), record)
        print(f"adopted {args.task} worktree={adopted['worktree']}")
        return
    mode, yolo = project_mode(project)
    root = Path(os.environ.get("FM_ROOT_OVERRIDE", Path(__file__).resolve().parent.parent))
    brief_cmd = [str(root / "bin/fm-brief.sh"), args.task, project, "--mode", mode]
    environment = os.environ.copy()
    environment["FM_HOME"] = str(home())
    result = subprocess.run(brief_cmd, cwd=home(), env=environment, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        fail(result.stderr.strip() or "could not scaffold Bosun contribution brief")
    brief = safe_path(home() / "data" / args.task / "brief.md")
    try:
        body = brief.read_text()
    except OSError as exc:
        fail(f"could not read contribution brief: {exc}")
    paths = "\n".join(f"- `{item}`" for item in record["allowed_paths"])
    commits = "\n".join(f"- `{item}`" for item in record["source_commits"])
    deviations = "\n".join(f"- `{item['path']}`: {item['reason']}" for item in record.get("deviations", []))
    deviation_note = f"\nDeclared extraction deviations:\n{deviations}\n" if deviations else ""
    task = (f"Contribute the named Captain's Maneuver `{record['maneuver']}` to "
            f"`{record['target']['owner']}/{record['target']['repository']}`.\n\n"
            "Read the target repository's current instructions and contribution policy, "
            "then inspect accepted pull requests and review history when conventions are unclear.\n"
            "Fetch the latest upstream default branch into this isolated worktree and cut the "
            "smallest coherent contribution from the ordered housefeature branch. Apply only "
            "these recorded source commits, in order; the order never authorizes the rest of "
            f"the branch:\n{commits}\n"
            f"Use only these ordered paths:\n{paths}\n"
            f"{deviation_note}"
            "Remove house-only configuration, private context, secrets, unrelated history, and "
            "fork-specific assumptions. Preserve attribution and make a clean commit series, "
            "title, and description. Run the target repository's expected validation, using "
            "no-mistakes where configured.\n"
            "Before upstream publication, complete the prior-art scan and decision in "
            "bin/fm-upstream-prior-art.py and use its guarded publish operation; an automatic "
            "PR creation path must not bypass that receipt.\n"
            "Open the PR only from the configured Captain fork to the ordered upstream target. "
            "Shepherd checks and review through the existing contribution observer; escalate "
            "scope changes, ambiguous maintainer requests, policy conflicts, and consequential "
            "decisions with needs-decision through the parent channel.\n\n"
            f"Captain's exact order: {record['captain_order']['words']}")
    spec = (f"Bosun assignment `{record['assignment_id']}`.\n"
            f"This task is authorized only for Bosun `{record['bosun']}`, source branch "
            f"`{record['source_branch']}`, contribution branch `{record['contribution_branch']}`, "
            f"Captain fork `{record['fork']['owner']}/{record['fork']['repository']}`, and "
            f"upstream default branch `{record['upstream_default_branch']}`. Do not select other "
            "work, widen the scope, or contact unrelated projects.")
    if "{TASK}" not in body or "{FIRSTMATE_SPEC}" not in body:
        fail("contribution brief placeholders are unavailable")
    write_text(brief, body.replace("{TASK}", task).replace("{FIRSTMATE_SPEC}", spec))
    spawn = subprocess.run([str(root / "bin/fm-spawn.sh"), args.task, str(project_dir),
                            "--mode", mode, "--yolo", yolo], cwd=home(), env=environment,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if spawn.returncode:
        fail(spawn.stderr.strip() or "could not spawn Bosun contribution task")
    match = re.search(r"(?:^| )worktree=(\S+)", spawn.stdout)
    if not match:
        fail("Bosun contribution task did not report an isolated worktree")
    record["task_brief"] = str(brief)
    record["task_worktree"] = match.group(1)
    record["task_mode"] = mode
    record["task_yolo"] = yolo
    record["assigned_at"] = now()
    record["state"] = "assigned"
    write_json(contribution_path(args.task), record)
    print(spawn.stdout.strip())


def memory_path(bosun, scope, want):
    role(bosun)
    root = home() / "data/bosun-memory" / bosun
    return root / ("profile.json" if scope == "shared" else f"repos/{want['forge']}/{want['owner']}/{want['repository']}.json")


def cmd_convention(args):
    want = target(args.forge, args.owner, args.repository)
    if args.scope not in ("shared", "repository"):
        fail(f"invalid Bosun convention scope: {args.scope}")
    path = memory_path(args.bosun, args.scope, want)
    record = read_json(path, {"schema": "fm-bosun-memory.v1", "conventions": []})
    if record.get("schema") != "fm-bosun-memory.v1" or not isinstance(record.get("conventions"), list):
        fail("invalid Bosun memory")
    if args.confirmed and (not args.evidence or not args.showed or not args.read_at):
        fail("confirmed convention requires evidence source, finding, and read time")
    record["conventions"].append({"key": args.key, "value": args.value, "confirmed": args.confirmed,
                                  "source": args.evidence, "showed": args.showed, "read_at": args.read_at})
    write_json(path, record)


def cmd_conventions(args):
    want = target(args.forge, args.owner, args.repository)
    result = {}
    for scope in ("shared", "repository"):
        data = read_json(memory_path(args.bosun, scope, want), {"schema": "fm-bosun-memory.v1", "conventions": []})
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


def cmd_registration_check(args):
    with contribution_lock(args.task):
        return cmd_registration_check_locked(args)


def cmd_registration_check_locked(args):
    marker = safe_path(home() / ".fm-secondmate-home")
    if marker.is_symlink() or not marker.is_file():
        fail("Bosun secondmate identity marker is missing or unsafe")
    bosun = marker.read_text().strip()
    role_file = safe_path(home() / "data/bosun-role.json")
    if role_file.is_symlink() or not role_file.is_file():
        fail("Bosun role record is missing or unsafe")
    role(bosun)
    record = contribution(args.task)
    if record["bosun"] != bosun or record["target"]["forge"] != args.forge:
        fail("Bosun PR registration requires a matching captain order")
    if record.get("state") == "published":
        if record.get("upstream_pr") != args.url:
            fail("captain order already has a registered upstream PR")
    elif record.get("state") not in ("ordered", "assigned") or record.get("upstream_pr"):
        fail("captain order already has a registered upstream PR")
    url_match = re.fullmatch(
        r"https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)", args.url, re.IGNORECASE)
    if (not url_match
            or url_match.group(1).lower() != record["target"]["owner"].lower()
            or url_match.group(2).lower() != record["target"]["repository"].lower()):
        fail("upstream PR URL differs from captain order")
    expected_head = f"{record['fork']['owner']}/{record['fork']['repository']}"
    expected_base = f"{record['target']['owner']}/{record['target']['repository']}"
    if args.head.lower() != expected_head:
        fail(f"upstream PR head differs: expected {expected_head}, got {args.head}")
    if args.base.lower() != expected_base:
        fail(f"upstream PR base differs: expected {expected_base}, got {args.base}")
    if args.branch != record["upstream_default_branch"]:
        fail(f"upstream PR base branch differs: expected {record['upstream_default_branch']}, got {args.branch}")
    if args.head_branch != record.get("contribution_branch"):
        fail(f"upstream PR head branch differs: expected {record.get('contribution_branch')}, got {args.head_branch}")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.pr_head):
        fail("upstream PR head commit is missing or invalid")
    if args.validation_head.lower() != args.pr_head.lower():
        fail(f"validation evidence is stale: expected {args.pr_head}, got {args.validation_head}")
    if not args.validation_mode:
        fail("no-mistakes validation evidence is missing")
    allowed = record.get("allowed_paths")
    deviations = record.get("deviations", [])
    if not isinstance(allowed, list) or not allowed:
        fail("captain order has no allowed paths")
    if (not isinstance(deviations, list)
            or any(not isinstance(item, dict) or set(item) != {"path", "reason"}
                   or not isinstance(item["path"], str) or not isinstance(item["reason"], str)
                   for item in deviations)):
        fail("captain order has invalid extraction deviations")
    deviation_paths = [item["path"] for item in deviations]
    extraction_paths = allowed + deviation_paths
    upstream_base = args.upstream_base
    if args.worktree:
        worktree = safe_path(args.worktree)
        if worktree.is_symlink() or not worktree.is_dir():
            fail("Bosun contribution worktree is unavailable")
        if (git_output(worktree, "rev-parse", "HEAD") or "").lower() != args.pr_head.lower():
            fail("upstream PR head differs from the contribution worktree")
        upstream_base = git_output(worktree, "rev-parse", "--verify", f"{args.upstream_base}^{{commit}}")
        if not upstream_base:
            fail("upstream extraction base is unavailable")
        if record.get("state") == "published":
            upstream_base = git_output(worktree, "merge-base", upstream_base, "HEAD")
            if not upstream_base:
                fail("upstream extraction base is unavailable")
        elif not git_success(worktree, "merge-base", "--is-ancestor", upstream_base, "HEAD"):
            fail("contribution does not start from the latest upstream default branch")
        actual = git_output(worktree, "rev-list", "--first-parent", "--reverse", f"{upstream_base}..HEAD")
        source_commits = record.get("source_commits")
        if actual is None or not isinstance(source_commits, list) or not source_commits:
            fail("upstream PR commits differ from the ordered source commits")
        actual_commits = actual.splitlines()
        if not actual_commits:
            fail("upstream PR patches differ from the ordered source commits")
        for commit in source_commits:
            paths = git_output(worktree, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit)
            offending = ([] if paths is None else
                         [path for path in paths.splitlines() if path and not path_allowed(path, extraction_paths)])
            if paths is None or offending:
                fail(f"ordered source commit changes unauthorized paths: {', '.join(offending) or '<unreadable>'}")
        merges = {}
        for commit in actual_commits:
            parents = git_output(worktree, "rev-list", "--parents", "-n", "1", commit)
            parents = [] if parents is None else parents.split()[1:]
            if len(parents) > 1:
                if not all(git_success(worktree, "merge-base", "--is-ancestor", parent, upstream_base)
                           for parent in parents[1:]):
                    fail(f"upstream PR commit {commit} is a merge commit; unrelated history is not allowed")
                merges[commit] = parents[1:]
                continue
            if len(parents) != 1:
                fail(f"upstream PR commit {commit} is a root commit; unrelated history is not allowed")
            paths = git_output(worktree, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit)
            offending = ([] if paths is None else
                         [path for path in paths.splitlines() if path and not path_allowed(path, extraction_paths)])
            if paths is None or offending:
                fail(f"upstream PR commit {commit} changes unauthorized paths: "
                     f"{', '.join(offending) or '<unreadable>'}")
        published_head = (record["validation_evidence"]["pr_head"]
                          if record.get("state") == "published" else None)
        validate_extraction(worktree, source_commits, actual_commits, merges, deviations, published_head)
    changed = args.changed_path
    if not changed:
        fail("upstream change has no validated changed paths")
    offending = []
    for path in changed:
        if not path or path.startswith("/") or path in (".", "..") or path.startswith("../") or "/../" in path or path.endswith("/.."):
            offending.append(path or "<empty>")
            continue
        if not path_allowed(path, extraction_paths):
            offending.append(path)
    if offending:
        fail(f"out-of-scope upstream paths: {', '.join(offending)}")
    if args.forge_verify:
        if not args.worktree:
            fail("final forge verification requires a contribution worktree")
        fresh = forge_pr_identity(args.url)
        if (fresh["head"].lower() != args.head.lower()
                or fresh["base"].lower() != args.base.lower()
                or fresh["branch"] != args.branch
                or fresh["head_branch"] != args.head_branch
                or fresh["pr_head"].lower() != args.pr_head.lower()):
            fail("upstream PR changed during validation; refusing registration")
        fresh_paths = forge_pr_changed_paths(args.url)
        if sorted(fresh_paths) != sorted(changed):
            fail("upstream PR changed paths differ during validation; refusing registration")
    record["upstream_pr"] = args.url
    record["validation_evidence"] = {"pr_head": (fresh["pr_head"].lower() if args.forge_verify
                                                   else args.validation_head.lower()),
                                      "mode": args.validation_mode,
                                      "validated_at": now()}
    record["upstream_changed_paths"] = changed
    record["upstream_base"] = upstream_base
    if not args.check_only:
        record["state"] = "published"
        write_json(contribution_path(args.task), record)


def cmd_merged(args):
    if not contribution_path(args.task).exists():
        return
    with contribution_lock(args.task):
        return cmd_merged_locked(args)


def cmd_merged_locked(args):
    path = contribution_path(args.task)
    record = contribution(args.task)
    if record.get("upstream_pr") != args.url or record.get("state") not in ("published", "admirals-maneuver"):
        fail("merge URL does not match authorized maneuver")
    if record["state"] == "admirals-maneuver":
        return
    record["state"] = "admirals-maneuver"
    record["admirals_maneuver_at"] = now()
    write_json(path, record)


REVIEW_ESCALATIONS = ("scope-change", "ambiguous-request", "policy-conflict")


def cmd_escalate(args):
    if args.reason not in REVIEW_ESCALATIONS:
        fail(f"invalid review escalation: {args.reason}")
    if not args.feedback.strip() or not args.note.strip():
        fail("review escalation requires the feedback reference and a note")
    with contribution_lock(args.task):
        record = contribution(args.task)
        if record.get("state") != "published" or not record.get("upstream_pr"):
            fail("review escalation requires a published upstream PR")
        events = record.setdefault("review_events", [])
        index = next((i for i, item in enumerate(events) if item.get("feedback") == args.feedback), None)
        if index is None:
            events.append({"feedback": args.feedback, "reason": args.reason, "note": args.note,
                           "status": "needs-decision", "recorded_at": now()})
            index = len(events) - 1
            write_json(contribution_path(args.task), record)
        event = events[index]
    line = (f"needs-decision [key=bosun-review-{args.task}-{index + 1}]: Bosun {record['bosun']} "
            f"{record['upstream_pr']} review feedback {event['feedback']} is a {event['reason']}: "
            f"{event['note']}")
    lib = Path(__file__).resolve().parent / "fm-parent-channel-lib.sh"
    report = subprocess.run(
        ["bash", "-c", '. "$1"; fm_parent_channel_report "$2" "$3" "$(fm_parent_channel_clean_note "$4")"',
         "_", str(lib), str(home()), str(home() / "state"), line],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if report.returncode:
        fail(f"review escalation is recorded but did not reach the parent channel (rc={report.returncode})")
    print(f"needs-decision: awaiting captain on {event['feedback']}")


def cmd_upstream_ref(args):
    project_dir = safe_path(args.worktree)
    if not project_dir.is_dir() or project_dir.is_symlink():
        fail(f"upstream project clone is unavailable: {project_dir}")
    print(fetched_upstream_ref(project_dir, args.owner, args.repository, args.branch))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    def add_target(p, required=True):
        for option in ("--forge", "--owner", "--repository"):
            p.add_argument(option, required=required)
    p = sub.add_parser("route"); add_target(p); p.set_defaults(func=cmd_route)
    p = sub.add_parser("configure-home"); p.add_argument("--bosun", required=True); p.set_defaults(func=cmd_configure_home)
    p = sub.add_parser("order"); add_target(p)
    for name in ("task", "bosun", "maneuver", "source", "branch", "captain-words"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--path", action="append", default=[]); p.add_argument("--commit", action="append", default=[])
    p.add_argument("--deviation", action="append", default=[])
    p.add_argument("--fork-owner"); p.add_argument("--fork-repository"); p.add_argument("--default-branch"); p.set_defaults(func=cmd_order)
    p = sub.add_parser("intake"); p.add_argument("--task", required=True); p.set_defaults(func=cmd_intake)
    p = sub.add_parser("convention"); add_target(p)
    for name in ("bosun", "scope", "key", "value"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--evidence"); p.add_argument("--showed"); p.add_argument("--read-at"); p.add_argument("--confirmed", action="store_true"); p.set_defaults(func=cmd_convention)
    p = sub.add_parser("conventions"); add_target(p); p.add_argument("--bosun", required=True); p.add_argument("--policy", required=True); p.add_argument("--decisions"); p.set_defaults(func=cmd_conventions)
    p = sub.add_parser("registration-check"); p.add_argument("--task", required=True); p.add_argument("--url", required=True); p.add_argument("--forge", required=True); p.add_argument("--head", required=True); p.add_argument("--base", required=True); p.add_argument("--branch", required=True); p.add_argument("--head-branch", required=True); p.add_argument("--pr-head", required=True); p.add_argument("--validation-head", required=True); p.add_argument("--validation-mode", required=True); p.add_argument("--upstream-base", required=True); p.add_argument("--worktree"); p.add_argument("--changed-path", action="append", default=[]); p.add_argument("--check-only", action="store_true"); p.add_argument("--forge-verify", action="store_true"); p.set_defaults(func=cmd_registration_check)
    p = sub.add_parser("escalate"); p.add_argument("--task", required=True); p.add_argument("--feedback", required=True); p.add_argument("--reason", required=True); p.add_argument("--note", required=True); p.set_defaults(func=cmd_escalate)
    p = sub.add_parser("merged"); p.add_argument("--task", required=True); p.add_argument("--url", required=True); p.set_defaults(func=cmd_merged)
    p = sub.add_parser("upstream-ref"); p.add_argument("--worktree", required=True); p.add_argument("--owner", required=True); p.add_argument("--repository", required=True); p.add_argument("--branch", required=True); p.set_defaults(func=cmd_upstream_ref)
    args = parser.parse_args()
    try:
        args.func(args)
    except Refusal as exc:
        print(f"fm-bosun: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

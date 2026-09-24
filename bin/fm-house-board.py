#!/usr/bin/env python3
"""Compose the house board from its private register and live, read-only gh-axi API calls."""

import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

SCHEMA = "fm-house-board.v1"
LABELS = {"house-only", "upstream-candidate", "upstream-offered", "contributed-house-feature", "historical"}
BRANCH = re.compile(r"housefeature/([A-Za-z0-9._-]+)")
SHA = re.compile(r"(?<![A-Za-z0-9])[0-9a-f]{7,40}(?![A-Za-z0-9])")
PR = re.compile(r"\bPR\s+(\d+)\b")


def api(path, selector="."):
    """gh-axi presents a bounded YAML envelope; base64 keeps selected JSON unambiguous."""
    run = subprocess.run(
        ["gh-axi", "api", path, "--jq", f"({selector})|@base64"],
        text=True, capture_output=True, check=False,
    )
    if run.returncode:
        raise RuntimeError(f"GitHub read failed for {path}: {run.stderr.strip() or run.stdout.strip()}")
    match = re.search(r"^  body: ([A-Za-z0-9+/=]+)$", run.stdout, re.M)
    if not match or not re.search(r"^  truncated: false$", run.stdout, re.M):
        raise RuntimeError(f"GitHub response was unreadable or truncated for {path}")
    try:
        return json.loads(base64.b64decode(match.group(1), validate=True))
    except (ValueError, json.JSONDecodeError) as error:
        raise RuntimeError(f"GitHub response was not JSON for {path}") from error


def pages(path, selector):
    rows = []
    page_size = 8
    for page in range(1, 101):
        separator = "&" if "?" in path else "?"
        part = api(f"{path}{separator}per_page={page_size}&page={page}", selector)
        if not isinstance(part, list):
            raise RuntimeError(f"GitHub list was not an array for {path}")
        rows.extend(part)
        if len(part) < page_size:
            return rows
    raise RuntimeError(f"GitHub pagination did not finish for {path}")


def register(path):
    text = path.read_text(encoding="utf-8")
    projects = {}
    project = None
    offered = False
    for line in text.splitlines():
        heading = re.match(r"^## (.+)$", line)
        if heading:
            project = projects.get(heading.group(1))
            offered = False
            continue
        fork_match = re.search(r"\bFork `([^`]+/[^`]+)`.*?upstream `([^`]+/[^`]+)`", line, re.I)
        if fork_match:
            name = fork_match.group(1).split("/", 1)[1]
            project = projects.setdefault(name, {"name": name, "fork": fork_match.group(1), "upstream": fork_match.group(2), "features": {}})
            continue
        if project is None:
            continue
        if line.startswith("- Offered upstream"):
            offered = True
        if line.startswith("- Provenance") or line.startswith("- Visibility"):
            offered = False
        if not line.lstrip().startswith("-"):
            continue
        slugs = list(dict.fromkeys(BRANCH.findall(line)))
        if not slugs or "<slug>" in line:
            continue
        bold = re.match(r"^\s*-\s*\*\*(.+?)\*\*", line)
        plain = re.match(r"^\s*-\s*([^(`]+?)\s*\(", line)
        description = line.split(" — ", 1)[-1].strip().rstrip(".") if " — " in line else ""
        prs = [int(number) for number in PR.findall(line)]
        commits = list(dict.fromkeys(SHA.findall(line)))
        explicit = next((match.group(1) for match in re.finditer(r"`([a-z-]+)`", line)
                         if match.group(1) in LABELS and not line[max(0, match.start() - 4):match.start()].lower().endswith("not ")), None)
        for index, slug in enumerate(slugs):
            feature = project["features"].setdefault(slug, {
                "slug": slug, "name": slug.replace("-", " ").capitalize(),
                "description": "", "commits": [], "fork_pr": None, "upstream_pr": None,
                "register_label": None,
            })
            if bold and index == 0:
                feature["name"] = bold.group(1)
            elif plain and index == 0:
                feature["name"] = plain.group(1).strip()
            if description and not feature["description"]:
                feature["description"] = description
            # Keep each branch's own commit, not an unrelated SHA in the same
            # narrative sentence (the register sometimes mentions mirror tips).
            own_commits = commits[index:index + 1] if len(slugs) > 1 and len(commits) >= len(slugs) else (
                [commit for commit in commits if line.find(commit) < line.find(f"housefeature/{slug}")]
                if len(slugs) == 1 else [])
            if own_commits:
                for commit in own_commits:
                    if commit not in feature["commits"]:
                        feature["commits"].append(commit)
            number = prs[index] if len(prs) == len(slugs) else (
                (prs[-1] if offered else prs[0]) if len(slugs) == 1 and prs
                else prs[0] if offered and index == 0 and prs else None)
            if number:
                key = "upstream_pr" if offered else "fork_pr"
                feature[key] = number
            if explicit:
                feature["register_label"] = explicit
    if not projects:
        raise RuntimeError("house register names no forks")
    # The register gives these project defaults in prose; row labels remain
    # explicit when present, and live PR labels take priority later.
    for project in projects.values():
        section = text.split(f"## {project['name']}\n", 1)[-1].split("\n## ", 1)[0]
        project["default_label"] = "upstream-candidate" if "each is an upstream candidate unless labelled" in section else "house-only"
    return projects


def repo_snapshot(project):
    fork, upstream = project["fork"], project["upstream"]
    fork_main = api(f"repos/{fork}/branches/main", "{sha:.commit.sha}")["sha"]
    upstream_main = api(f"repos/{upstream}/branches/main", "{sha:.commit.sha}")["sha"]
    house = api(f"repos/{fork}/branches/house", "{sha:.commit.sha}")["sha"]
    comparison = api(f"repos/{fork}/compare/{upstream_main}...{house}",
                     "{status,ahead_by,behind_by,commits:[.commits[].sha]}")
    branches = pages(f"repos/{fork}/branches", "[.[]|{name,sha:.commit.sha}]")
    pulls = pages(f"repos/{fork}/pulls?state=all", "[.[]|{number,title,state,merged_at,merge_commit_sha,created_at,head:.head.ref,labels:[.labels[].name],html_url}]")
    return {
        "fork": fork, "upstream": upstream, "house_tip": house,
        "upstream_tip": upstream_main, "fork_main_tip": fork_main,
        "mirror_equal": fork_main == upstream_main,
        "ahead": comparison["ahead_by"], "behind": comparison["behind_by"],
        "house_commits": comparison["commits"],
        "branches": {row["name"].split("/", 1)[1]: row["sha"] for row in branches if row["name"].startswith("housefeature/")},
        "pulls": {row["number"]: row for row in pulls},
    }


def days_old(iso, now):
    if not iso:
        return None
    try:
        then = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return max(0, (now - then).days)
    except ValueError:
        return None


def distinct_commits(commits):
    unique = []
    for commit in commits:
        match = next((index for index, existing in enumerate(unique)
                      if existing.startswith(commit) or commit.startswith(existing)), None)
        if match is None:
            unique.append(commit)
        elif len(commit) > len(unique[match]):
            unique[match] = commit
    return unique


def compose(projects):
    now = dt.datetime.now(dt.timezone.utc)
    result = {"schema": SCHEMA, "generated": now.isoformat(timespec="seconds").replace("+00:00", "Z"), "projects": [], "features": []}
    for project in projects.values():
        live = repo_snapshot(project)
        project_row = {key: live[key] for key in ("fork", "upstream", "house_tip", "upstream_tip", "fork_main_tip", "mirror_equal", "ahead", "behind")}
        project_row["name"] = project["name"]
        result["projects"].append(project_row)
        house_commits = set(live["house_commits"])
        for slug in sorted(set(project["features"]) | set(live["branches"])):
            entry = project["features"].get(slug)
            branch_sha = live["branches"].get(slug)
            fork_pr = live["pulls"].get(entry["fork_pr"]) if entry and entry["fork_pr"] else None
            if fork_pr is None:
                fork_pr = next((p for p in live["pulls"].values() if p["head"] == f"housefeature/{slug}"), None)
            commits = entry["commits"] if entry else []
            known_on_house = [sha for sha in commits if any(full.startswith(sha) for full in house_commits)]
            # The branch tip is checked against today's house tip. A registered
            # commit in today's upstream-relative house delta also proves it.
            branch_landed = False
            if branch_sha:
                ancestry = api(f"repos/{project['fork']}/compare/{branch_sha}...{live['house_tip']}", "{behind_by}")
                branch_landed = ancestry["behind_by"] == 0
            merge_sha = (fork_pr or {}).get("merge_commit_sha") if (fork_pr or {}).get("merged_at") else None
            merge_landed = False
            if merge_sha:
                if merge_sha in house_commits:
                    merge_landed = True
                elif not branch_landed and not known_on_house:
                    ancestry = api(f"repos/{project['fork']}/compare/{merge_sha}...{live['house_tip']}", "{behind_by}")
                    merge_landed = ancestry["behind_by"] == 0
            landed = branch_landed or merge_landed or bool(known_on_house)
            commit_date = None
            if branch_sha:
                commit_date = api(f"repos/{project['fork']}/commits/{branch_sha}", "{date:.commit.committer.date}")["date"]
            elif known_on_house:
                commit_date = api(f"repos/{project['fork']}/commits/{known_on_house[0]}", "{date:.commit.committer.date}")["date"]
            upstream_pr = None
            if entry and entry["upstream_pr"]:
                upstream_pr = api(f"repos/{project['upstream']}/pulls/{entry['upstream_pr']}",
                                  "{number,state,merged_at,created_at,html_url,head:.head.ref}")
            if upstream_pr is None:
                matches = api(f"repos/{project['upstream']}/pulls?state=all&head={quote(project['fork'].split('/')[0] + ':' + 'housefeature/' + slug)}&per_page=20",
                              "[.[]|{number,state,merged_at,created_at,html_url,head:.head.ref}]")
                upstream_pr = matches[0] if matches else None
            labels = [name for name in (fork_pr or {}).get("labels", []) if name in LABELS]
            label = labels[0] if labels else (entry or {}).get("register_label") or project["default_label"]
            label_source = "fork PR" if labels else "register"
            if upstream_pr and upstream_pr["merged_at"]:
                label = "contributed-house-feature"
                label_source = "live upstream PR"
            elif upstream_pr and upstream_pr["state"] == "open" and label != "historical":
                label = "upstream-offered"
                label_source = "live upstream PR"
            presence = "both" if entry and branch_sha else "register only" if entry else "fork only"
            age_since = (fork_pr or {}).get("created_at") or (upstream_pr or {}).get("created_at") or commit_date
            result["features"].append({
                "project": project["name"], "name": entry["name"] if entry else slug.replace("-", " ").capitalize(),
                "description": entry["description"] if entry else "Branch exists on the fork but is absent from the house register.",
                "branch": f"housefeature/{slug}", "branch_tip": branch_sha,
                "branch_url": f"https://github.com/{project['fork']}/tree/housefeature/{slug}" if branch_sha else None,
                "commits": distinct_commits(commits + ([branch_sha] if branch_sha else []) + ([merge_sha] if merge_landed else [])),
                "landed": landed, "presence": presence, "label": label,
                "label_source": label_source,
                "state": "historical" if label == "historical" else "contributed" if label == "contributed-house-feature" else "offered" if label == "upstream-offered" else "landed" if landed else "unlanded",
                "fork_pr": {key: fork_pr[key] for key in ("html_url", "state", "merged_at") } if fork_pr else None,
                "upstream_pr": {key: upstream_pr[key] for key in ("html_url", "state", "merged_at") } if upstream_pr else None,
                "age_days": days_old(age_since, now), "age_since": age_since,
            })
    return result


def write_atomic(path, content):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".house-board-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def serve(page):
    def run(*args):
        process = subprocess.run(["lavish-axi", *map(str, args)], text=True, capture_output=True, check=False)
        if process.returncode:
            raise RuntimeError(f"Lavish could not serve the board: {process.stderr.strip() or process.stdout.strip()}")
        return process.stdout

    page = page.resolve()
    output = run(page)
    listing = run()
    if not any(line.strip().startswith(str(page) + ",open,") for line in listing.splitlines()):
        output = run(page, "--reopen")
        listing = run()
        if not any(line.strip().startswith(str(page) + ",open,") for line in listing.splitlines()):
            raise RuntimeError("Lavish did not list the house board as open after reopening")
    print(output, end="")


def main():
    if sys.argv[1:] != ["build"]:
        raise RuntimeError("usage: fm-house-board.py build")
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get("FM_HOME", str(root)))
    register_path = home / "data/house-line.md"
    template_path = Path(os.environ.get("FM_HOUSE_BOARD_TEMPLATE", str(root / ".agents/skills/bearings/assets/house-board-template.html")))
    if not register_path.is_file() or not template_path.is_file():
        raise RuntimeError("house register or board template is missing")
    payload = compose(register(register_path))
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    template = template_path.read_text(encoding="utf-8")
    if template.count("__FM_HOUSE_BOARD_DATA__") != 1:
        raise RuntimeError("house board template needs exactly one data slot")
    html = template.replace("__FM_HOUSE_BOARD_DATA__", encoded)
    page = home / ".lavish/house-board.html"
    write_atomic(home / ".lavish/house-board.json", json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    write_atomic(page, html)
    print(f"board: {page}")
    print(f"payload: {home / '.lavish/house-board.json'}")
    if os.environ.get("FM_HOUSE_BOARD_NO_SERVE") != "1":
        serve(page)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, KeyError, TypeError) as error:
        print(f"fm-house-board: {error}", file=sys.stderr)
        sys.exit(1)

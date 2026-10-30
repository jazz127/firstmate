#!/usr/bin/env python3
"""Scoped commit attribution.

Usage: fm-git-attribution.py mode <config> <project>
       fm-git-attribution.py stamp <config> <runtime> <model> <message>

An empty legacy config means keep; nonempty configs list host/owner[/repo]
(one per line, # comments). Invalid entries refuse the launch/commit.
Stamp runs in Git's hook cwd and rechecks origin, so another repository cannot
inherit an attribution opt-in. Only UUID session IDs and Claude's public session
URL shape are publishable; arbitrary environment values are never copied.
"""
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

SCOPE = re.compile(r"[a-z0-9.-]+/[a-z0-9_.-]+(?:/[a-z0-9_.-]+)?", re.I)
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)


def remote(project):
    result = subprocess.run(["git", "-C", project, "config", "--get", "remote.origin.url"],
                            capture_output=True, text=True, check=False)
    url = result.stdout.strip()
    if "://" in url:
        parsed = urlsplit(url)
        if parsed.scheme not in ("ssh", "https", "http", "git"):
            return ""
        host, path = parsed.hostname or "", parsed.path.lstrip("/")
    else:
        match = re.fullmatch(r"(?:[^/@:]+@)?([^/:]+):([^\s]+)", url)
        if not match:
            return ""
        host, path = match.groups()
    value = f"{host}/{path.removesuffix('.git')}".lower()
    return value if SCOPE.fullmatch(value) and value.count("/") == 2 else ""


def mode(config, project):
    path = Path(config)
    if not path.exists():
        return "strip"
    content = path.read_text()
    if not content.strip():
        return "keep"
    scopes = []
    for line in content.splitlines():
        line = line.split("#", 1)[0].strip().lower().removesuffix("/")
        if not line:
            continue
        if not SCOPE.fullmatch(line) or any(p in (".", "..") for p in line.split("/")):
            raise ValueError("invalid keep-ai-trailers scope (expected host/owner[/repo])")
        scopes.append(line.removesuffix(".git"))
    target = remote(project)
    return "add" if any(target == s or target.startswith(s + "/") for s in scopes) else "strip"


def session(runtime, lines):
    # This variable is supplied to shell tools by Codex, not a parent endpoint ID.
    if runtime == "codex":
        value = os.environ.get("CODEX_THREAD_ID", "")
        return value if UUID.fullmatch(value) else ""
    if runtime.startswith("claude"):
        for line in lines:
            if line.lower().startswith("claude-session:"):
                value = line.split(":", 1)[1].strip()
                if UUID.fullmatch(value) or re.fullmatch(
                        r"https://claude\.ai/code/session_[a-zA-Z0-9]+", value):
                    return value
    return ""


def stamp(config, runtime, model, message):
    current = mode(config, ".")
    if current != "add":
        if current == "strip":
            subprocess.run([str(Path(__file__).with_name("fm-git-strip-ai-trailers.sh")), message], check=True)
        return
    # Runtime/model are launch metadata, never free-form trailer contents.
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", runtime) or not re.fullmatch(
            r"[a-zA-Z0-9][a-zA-Z0-9_.:/+-]*", model) or "://" in model:
        raise ValueError("unsafe runtime/model for Agent-Platform")
    path = Path(message)
    lines = path.read_text().splitlines()
    sid = session(runtime, lines)
    # Replace our fields on amend/retry; retain existing co-authors.
    lines = [line for line in lines if not re.match(
        r"(?i)^(agent-system|agent-platform|agent-session):", line)]
    coauthors = [line for line in lines if re.match(
        rf"(?i)^co-authored-by:\s*{re.escape(runtime)}(?:\s|<|$)", line)]
    if not coauthors:
        # A stable system identity covers runtimes that emit no co-author.
        lines += ["", f"Co-authored-by: {runtime} <noreply@firstmate.invalid>"]
    # Claude Code omits model IDs from commit attribution. A default model is
    # unresolved launch metadata, so it must not be presented as a model ID.
    platform = runtime
    if not runtime.startswith("claude") and model not in ("default", "auto"):
        platform += f"/{model}"
    args = ["git", "interpret-trailers", "--in-place", "--if-exists", "replace",
            "--trailer", "Agent-System: fac:firstmate",
            "--trailer", f"Agent-Platform: {platform}"]
    native_session = any(
        re.fullmatch(r"[a-z0-9-]+-session", line.split(":", 1)[0], re.I)
        and line.split(":", 1)[1].strip() == sid
        for line in lines if ":" in line
    )
    if sid and not native_session:
        args += ["--trailer", f"Agent-Session: {sid}"]
    path.write_text("\n".join(lines).rstrip() + "\n")
    subprocess.run(args + [message], check=True)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[1] == "mode":
            print(mode(*sys.argv[2:]))
        elif len(sys.argv) == 6 and sys.argv[1] == "stamp":
            stamp(*sys.argv[2:])
        else:
            raise ValueError(__doc__)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f"fm-git-attribution: {exc}")

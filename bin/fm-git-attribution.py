#!/usr/bin/env python3
"""Scoped commit attribution.

Usage: fm-git-attribution.py mode <config> <project>
       fm-git-attribution.py stamp <task-meta> <runtime> <model> <message>
       fm-git-attribution.py apply <outside> <task-meta> <runtime> <model> <message>
       fm-git-attribution.py strip-fields <message>

docs/configuration.md "Commit attribution" owns commit-repository selection.
Stamp runs in Git's hook cwd and rechecks origin. Session references come from
runtime context or existing task metadata, never a new persistent record.
"""
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)
SHARED_FIELDS = {"agent-system", "agent-platform", "agent-session"}


def is_ai_coauthor(value):
    # Match known product names and observed bot addresses, never vendor domains
    # or name substrings, so human co-authors employed by vendors remain.
    name = value.strip().lower()
    email = ""
    if "<" in name and ">" in name.split("<", 1)[1]:
        name, email = name.split("<", 1)
        name = name.strip()
        email = email.split(">", 1)[0].strip()
    return (email.startswith("cursoragent@") or email in {
        "noreply@firstmate.invalid", "noreply@anthropic.com", "noreply@openai.com",
        "copilot@github.com", "noreply@commandcode.ai", "noreply@snowflake.com",
    } or name in {
        "cursor", "cursor agent", "claude", "claude code", "github copilot", "copilot",
        "codex", "chatgpt", "gemini", "google gemini", "grok", "openai", "commandcodebot",
        "snowflake coco", "cortex code",
    })


def remove_trailers(content, keys, strip_ai=False):
    args = ["git", "interpret-trailers", "--only-input"]
    block = subprocess.run(args + ["--only-trailers"], input=content,
                           capture_output=True, text=True, check=True).stdout
    if not block:
        return content
    formatted = subprocess.run(args, input=content, capture_output=True,
                               text=True, check=True).stdout
    divider = re.search(r"(?m)^---(?:[ \t]|\r?$)", formatted)
    cursor = divider.start() if divider else len(formatted)
    entries = re.findall(r"(?m)^[^\s][^\n]*(?:\n[ \t][^\n]*)*\n?", block)
    for entry in reversed(entries):
        start = formatted.rfind(entry, 0, cursor)
        if start < 0:
            raise ValueError("cannot locate Git-parsed trailer in message")
        key, _, value = entry.partition(":")
        key = key.strip().lower()
        value = " ".join(line.strip() for line in value.splitlines())
        if (key in keys or strip_ai and key == "co-authored-by"
                and is_ai_coauthor(value)):
            formatted = formatted[:start] + formatted[start + len(entry):]
        cursor = start
    return formatted


def t27sol(project):
    result = subprocess.run(["git", "-C", project, "config", "--get", "remote.origin.url"],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        return False
    url = result.stdout.strip()
    if "://" in url:
        try:
            parsed = urlsplit(url)
        except ValueError:
            return False
        if parsed.scheme not in ("ssh", "https"):
            return False
        if not parsed.hostname:
            return False
        host, path = parsed.hostname or "", parsed.path.lstrip("/")
    else:
        match = re.fullmatch(r"(?:[^/@:]+@)?([^/:]+):([^\s]+)", url)
        if not match:
            return False
        host, path = match.groups()
    return host.lower() == "github.com" and bool(re.fullmatch(
        r"t27sol/[a-z0-9_.-]+", path.lower().rstrip("/").removesuffix(".git")))


def mode(config, project):
    if t27sol(project):
        return "add"
    return "keep" if Path(config).exists() else "strip"


def session(runtime, lines, task_meta):
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
    if runtime.startswith("opencode"):
        value = os.environ.get("OPENCODE_SESSION_ID", "")
        return value if re.fullmatch(r"ses_[a-zA-Z0-9]+", value) else ""
    if runtime == "polytoken" and task_meta and Path(task_meta).is_file():
        for line in Path(task_meta).read_text().splitlines():
            if line.startswith("polytoken_session="):
                value = line.split("=", 1)[1]
                return value if re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}", value) else ""
    return ""


def apply(outside, task_meta, runtime, model, message):
    selected = "add" if t27sol(".") else outside
    if selected == "add":
        stamp(task_meta, runtime, model, message)
    elif selected == "strip":
        subprocess.run([str(Path(__file__).with_name("fm-git-strip-ai-trailers.sh")), message], check=True)
    elif selected != "keep":
        raise ValueError("invalid attribution policy")


def stamp(task_meta, runtime, model, message):
    if not t27sol("."):
        subprocess.run([str(Path(__file__).with_name("fm-git-strip-ai-trailers.sh")), message], check=True)
        return
    # Runtime/model are launch metadata, never free-form trailer contents.
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", runtime):
        raise ValueError("unsafe runtime for Agent-Platform")
    path = Path(message)
    # Replace our fields on amend/retry; retain existing co-authors.
    content = remove_trailers(path.read_text(), SHARED_FIELDS)
    trailers = subprocess.run(["git", "interpret-trailers", "--parse"], input=content,
                              capture_output=True, text=True, check=True).stdout.splitlines()
    sid = session(runtime, trailers, task_meta)
    coauthors = [line for line in trailers if re.match(
        rf"(?i)^co-authored-by:\s*{re.escape(runtime)}(?:\s|<|$)", line)]
    # Claude Code omits model IDs from commit attribution. A default model is
    # unresolved launch metadata, so it must not be presented as a model ID.
    platform = runtime
    if not runtime.startswith("claude") and model not in ("default", "auto"):
        if (not model or any(c.isspace() or not c.isprintable() for c in model)
                or model.startswith(("/", ".", "~")) or "\\" in model
                or re.match(r"^[a-zA-Z]:/", model) or "://" in model
                or any(part in (".", "..") for part in model.split("/"))):
            raise ValueError("unsafe model for Agent-Platform")
        platform += f"/{model}"
    args = ["git", "interpret-trailers", "--in-place"]
    if not coauthors:
        args += ["--if-exists", "addIfDifferent", "--trailer",
                 f"Co-authored-by: {runtime} <noreply@firstmate.invalid>"]
    args += ["--if-exists", "replace", "--trailer", "Agent-System: fac:firstmate",
             "--trailer", f"Agent-Platform: {platform}"]
    native_session = any(
        re.fullmatch(r"[a-z0-9-]+-session", line.split(":", 1)[0], re.I)
        and line.split(":", 1)[1].strip() == sid
        for line in trailers if ":" in line
    )
    if sid and not native_session:
        args += ["--trailer", f"Agent-Session: {sid}"]
    path.write_text(content)
    subprocess.run(args + [message], check=True)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[1] == "mode":
            print(mode(*sys.argv[2:]))
        elif len(sys.argv) == 6 and sys.argv[1] == "stamp":
            stamp(*sys.argv[2:])
        elif len(sys.argv) == 7 and sys.argv[1] == "apply":
            apply(*sys.argv[2:])
        elif len(sys.argv) == 3 and sys.argv[1] == "strip-fields":
            message = Path(sys.argv[2])
            content = remove_trailers(
                message.read_text(), SHARED_FIELDS | {"claude-session"}, strip_ai=True)
            # Only the observed Cortex link forms count as generated attribution;
            # other "Generated with" prose belongs to the author.
            message.write_text("".join(line for line in content.splitlines(keepends=True)
                                       if not re.fullmatch(
                                           r"generated with \[(?:snowflake coco|cortex code)\]"
                                           r"\(https://docs\.snowflake\.com/.*\)", line.strip(), re.I)))
        else:
            raise ValueError(__doc__)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f"fm-git-attribution: {exc}")

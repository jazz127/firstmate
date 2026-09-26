#!/usr/bin/env python3
"""Show one fm-bearings-board.v1 Captain's Call card in a terminal.

Usage: fm-captain-pane.py [--queue PATH]
       fm-captain-pane.py --render [--width COLUMNS] [--height ROWS] [--queue PATH]

The queue is $FM_HOME/state/captains-call.json, atomically published by
fm-bearings-board.sh. Its array order is the presentation order. This program
never interprets card text as a command. A decision selection goes to the
fm-captain-hold.sh keyed-answer intake, then fm-inbox.sh saves a durable wake.
A merge or credential selection only saves that durable wake; firstmate
verifies and performs the merge or collects the credential.
"""

import argparse
import hashlib
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import tty
import unicodedata
from pathlib import Path


BIN = Path(__file__).resolve().parent
ROOT = BIN.parent
KEY = re.compile(r"[A-Za-z0-9._-]{1,128}\Z")


def clean(value):
    if value is None:
        return ""
    return " ".join("".join(ch for ch in str(value) if ch.isprintable()).split())


def width_of(value):
    return sum(0 if unicodedata.combining(ch) else
               2 if unicodedata.east_asian_width(ch) in "WF" else 1
               for ch in value)


def clip(value, width):
    result = ""
    for ch in value:
        if width_of(result + ch) > width:
            break
        result += ch
    return result


def wrap(value, width):
    """Wrap even unbroken URLs without relying on terminal horizontal scroll."""
    width = max(1, width)
    words = clean(value).split(" ")
    lines = []
    line = ""
    for word in words:
        if not word:
            continue
        if line and width_of(line + " " + word) <= width:
            line += " " + word
            continue
        if line:
            lines.append(line)
            line = ""
        while width_of(word) > width:
            part = ""
            for ch in word:
                if width_of(part + ch) > width:
                    break
                part += ch
            if not part:  # a double-width glyph in a one-column terminal
                part, word = "?", word[1:]
            else:
                word = word[len(part):]
            lines.append(part)
        line = word
    if line or not lines:
        lines.append(line)
    return lines


def load_queue(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != "fm-bearings-board.v1" or not isinstance(data.get("captains_call"), list):
        raise ValueError("queue is not an fm-bearings-board.v1 payload")
    seen = set()
    for card in data["captains_call"]:
        if not isinstance(card, dict) or not KEY.fullmatch(str(card.get("key", ""))):
            raise ValueError("queue contains an invalid card key")
        if card["key"] in seen or card.get("type") not in ("decision", "merge", "credential"):
            raise ValueError("queue contains a duplicate key or unknown card type")
        seen.add(card["key"])
        if card["type"] == "merge" and not card["key"].startswith("merge."):
            raise ValueError("merge card key must name merge.<task-id>")
        options = card.get("options")
        if not isinstance(options, list) or not options and not card.get("allow_freeform"):
            raise ValueError("queue contains a card without options")
        for option in options:
            if not isinstance(option, dict) or not KEY.fullmatch(str(option.get("value", ""))):
                raise ValueError("queue contains an invalid option")
        if card.get("close", "done") not in ("done", "release"):
            raise ValueError("queue contains an invalid close mode")
    return data


def card_lines(card, index, total, width):
    w = max(1, width)
    inner = max(1, w - 2)
    rows = []
    hits = {}

    def add(value="", action=None):
        for line in wrap(value, inner):
            rows.append(" " + line)
            if action is not None:
                hits[len(rows)] = action

    add("CAPTAIN'S CALL  %s/%s" % (index + 1, total))
    add("=" * inner)
    add(card.get("title", "Untitled call"))
    add("Project: " + (clean(card.get("repo")) or "Unassigned"))
    add()
    labels = {"about": "About", "decide": "Decide", "detail": "Detail",
              "risk": "Risk", "pr_url": "PR URL"}
    for name in labels:
        if card.get(name):
            add(labels[name] + ": " + clean(card[name]))
    add()
    for i, option in enumerate(card["options"]):
        rec = "  RECOMMENDED" if option["value"] == card.get("recommend_value") else ""
        add("[" + str(i + 1) + "] " + clean(option.get("label", option["value"])) + rec,
            ("answer", i))
        if option.get("hint"):
            add("    " + clean(option["hint"]), ("answer", i))
        else:
            add("    Tap or press " + str(i + 1), ("answer", i))
        add(" ", ("answer", i))
    if card.get("allow_freeform"):
        add("[0] Write an answer", ("freeform", 0))
        add()
    return rows, hits


def screen(card, index, total, width, height, scroll=0, message=""):
    rows, hits = card_lines(card, index, total, width) if card else ([" Nothing needs your answer now."], {})
    visible = max(1, height - 2)
    scroll = min(max(0, scroll), max(0, len(rows) - visible))
    shown = rows[scroll:scroll + visible]
    mouse = {y: hits[scroll + y] for y in range(1, len(shown) + 1) if scroll + y in hits}
    footer = "[P] Prev  [N] Next  [S] Skip  [Q] Quit"
    nav = (("p", "prev"), ("n", "next"), ("s", "skip"), ("q", "quit"))
    for token, action in nav:
        pos = footer.lower().find("[" + token + "]")
        if pos >= 0 and pos < width:
            for x in range(pos + 1, min(pos + 4, width + 1)):
                mouse[(len(shown) + 1, x)] = (action, 0)
    # Map the whole navigation word to its action, including on narrow screens.
    for y in range(1, len(shown) + 1):
        if y in mouse:
            for x in range(1, width + 1):
                mouse[(y, x)] = mouse[y]
            del mouse[y]
    displayed = shown + [footer, clean(message)]
    return "\x1b[H\x1b[2J" + "\r\n".join(clip(line, width) for line in displayed), mouse, scroll, len(rows)


def event(fd):
    first = os.read(fd, 1)
    if not first:
        return ("quit", 0)
    if first != b"\x1b":
        return ("key", first.decode("utf-8", "ignore").lower())
    sequence = bytearray(first)
    while len(sequence) < 32 and select.select([fd], [], [], 0.03)[0]:
        sequence.extend(os.read(fd, 1))
        if sequence[-1:] in (b"M", b"m", b"~", b"A", b"B", b"C", b"D"):
            break
    match = re.fullmatch(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])", sequence)
    if match and match.group(4) == b"M":
        button, x, y = map(int, match.groups()[:3])
        if button in (64, 65):
            return ("scroll", -3 if button == 64 else 3)
        if button & 3 == 0:
            return ("click", (x, y))
    if sequence in (b"\x1b[A", b"\x1b[5~"):
        return ("scroll", -3)
    if sequence in (b"\x1b[B", b"\x1b[6~"):
        return ("scroll", 3)
    return ("noop", 0)


def run_command(name, *args, input_text=None):
    return subprocess.run([str(BIN / name), *args], input=input_text, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def answer(card, option, generated):
    key = card["key"]
    value = clean(option["value"])
    label = clean(option.get("label", value))
    selection = "freeform" if option.get("_freeform") else "option"
    if "\t" in value or "\t" in label or not value:
        return "Invalid answer text"
    if card["type"] == "decision":
        if value == "reconcile":
            bound = run_command("fm-captain-hold.sh", "bind", "captain-pane")
            if bound.returncode:
                return clean(bound.stderr or bound.stdout)
            result = run_command("fm-captain-hold.sh", "reconcile-requests", "--source-id",
                                 "captain-pane", "--source", "captain pane", input_text=key + "\n")
        else:
            mode = card.get("close", "done")
            row = "\t".join((key, value, label, mode)) + "\n"
            result = run_command("fm-captain-hold.sh", "answers", "--any-origin",
                                 "--source", "captain pane", input_text=row)
        if result.returncode:
            return clean(result.stderr or result.stdout or "Answer was refused")
    digest = hashlib.sha256((generated + "\0" + key + "\0" + selection + "\0" + value).encode()).hexdigest()[:24]
    request_id = "captain-pane-" + digest
    note = "Captain's Call pane selection: key=%s; selection=%s; value=%s; label=%s. Refresh the queue and act on the answer." % (key, selection, value, label)
    if card["type"] == "merge":
        note += " Resolve the PR from task metadata and apply the bearings merge-click ruling only for the selected merge option."
    result = run_command("fm-inbox.sh", "note", "--request-id", request_id, "--", note)
    if result.returncode:
        return clean(result.stderr or result.stdout or "Answer saved but wake failed; retry")
    return ""


def freeform(fd, saved):
    sys.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?25h\r\nYour answer: ")
    sys.stdout.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    try:
        value = input()[:512]
    except EOFError:
        value = ""
    tty.setraw(fd)
    sys.stdout.write("\x1b[?1000h\x1b[?1006h\x1b[?25l")
    sys.stdout.flush()
    return clean(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue", type=Path)
    parser.add_argument("--render", action="store_true", help="print the first card for inspection")
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    args = parser.parse_args()
    queue = args.queue or Path(os.environ.get("FM_HOME", ROOT)) / "state/captains-call.json"
    if not queue.is_file():
        parser.error("captain queue is absent; run /bearings to compose it: " + str(queue))
    data = load_queue(queue)
    cards = data["captains_call"]
    if args.render:
        size = shutil.get_terminal_size((80, 24))
        frame, _, _, _ = screen(cards[0] if cards else None, 0, len(cards),
                                args.width or size.columns, args.height or size.lines)
        print(frame.replace("\x1b[H\x1b[2J", ""))
        return
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("interactive mode needs a terminal; use --render to inspect the queue")
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    resize = False

    def on_resize(_signum, _frame):
        nonlocal resize
        resize = True

    signal.signal(signal.SIGWINCH, on_resize)
    index = scroll = 0
    answered = set()
    skipped = set()
    message = ""
    tty.setraw(fd)
    sys.stdout.write("\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?25l")
    sys.stdout.flush()
    try:
        while True:
            size = shutil.get_terminal_size((80, 24))
            current = [c for c in cards if c["key"] not in answered | skipped]
            index = min(index, max(0, len(current) - 1))
            card = current[index] if current else None
            frame, hits, scroll, count = screen(card, index, len(current), size.columns,
                                                size.lines, scroll, message)
            sys.stdout.write(frame)
            sys.stdout.flush()
            resize = False
            while not select.select([fd], [], [], 0.2)[0]:
                if resize:
                    break
            if resize:
                continue
            kind, value = event(fd)
            action = None
            if kind == "click":
                action = hits.get((value[1], value[0]))
            elif kind == "scroll":
                scroll = min(max(0, scroll + value), max(0, count - max(1, size.lines - 2)))
                continue
            elif kind == "quit" or kind == "key" and value == "q":
                break
            elif kind == "key":
                if value in ("p", "n", "s"):
                    action = {"p": ("prev", 0), "n": ("next", 0), "s": ("skip", 0)}[value]
                elif value.isdigit():
                    action = ("freeform", 0) if value == "0" else ("answer", int(value) - 1)
            if not action:
                continue
            name, number = action
            message = ""
            if name == "quit":
                break
            if name == "prev":
                index = max(0, index - 1)
                scroll = 0
            elif name == "next":
                index = min(max(0, len(current) - 1), index + 1)
                scroll = 0
            elif name == "skip" and card:
                skipped.add(card["key"])
                scroll = 0
                message = "Skipped for this visit"
            elif card and name in ("answer", "freeform"):
                try:
                    latest = load_queue(queue)
                except (OSError, ValueError, json.JSONDecodeError) as exc:
                    message = "Queue refresh failed: " + clean(exc)
                    continue
                matching = [item for item in latest["captains_call"] if item["key"] == card["key"]]
                if matching != [card]:
                    data, cards = latest, latest["captains_call"]
                    index = 0
                    scroll = 0
                    message = "Queue changed; review the current card"
                    continue
                if name == "freeform":
                    if not card.get("allow_freeform"):
                        continue
                    value = freeform(fd, saved)
                    if not value:
                        message = "No answer entered"
                        continue
                    option = {"value": value, "label": "Own words", "_freeform": True}
                else:
                    if number >= len(card["options"]):
                        continue
                    option = card["options"][number]
                message = answer(card, option, str(data.get("generated", "")))
                if not message:
                    answered.add(card["key"])
                    scroll = 0
                    # Read a replacement snapshot after each answer. Keep local
                    # answered keys excluded until the process exits.
                    try:
                        data = load_queue(queue)
                        cards = data["captains_call"]
                    except (OSError, ValueError, json.JSONDecodeError):
                        pass
                    message = "Answer recorded. Firstmate notified."
    finally:
        sys.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print("fm-captain-pane: " + str(exc), file=sys.stderr)
        sys.exit(1)

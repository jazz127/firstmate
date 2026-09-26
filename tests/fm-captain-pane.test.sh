#!/usr/bin/env bash
# Terminal rendering, keyboard/mouse input, and keyed-answer routing.
set -eu

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-pane)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import fcntl
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time

root, tmp = map(pathlib.Path, sys.argv[1:])
home = tmp / "home"
(home / "state").mkdir(parents=True)
fake = tmp / "bin"
fake.mkdir()
shutil.copy2(root / "bin/fm-captain-pane.py", fake / "fm-captain-pane.py")
for name in ("fm-captain-hold.sh", "fm-inbox.sh"):
    path = fake / name
    path.write_text("#!/bin/sh\nprintf '%%s\\n' \"$*\" >> \"$FM_TEST_LOG/%s.args\"\ncase \"$1\" in answers|reconcile-requests) cat >> \"$FM_TEST_LOG/%s.stdin\" ;; esac\n" % (name, name))
    path.chmod(0o755)

payload = {
    "schema": "fm-bearings-board.v1", "home": "test-home", "generated": "2026-09-26T00:00:00Z",
    "prs_live": False, "underway": [], "landed": [], "charted": [],
    "captains_call": [
        {"key": "held-task", "type": "decision", "repo": "sample/project",
         "title": "Choose the next deployment window for a lengthy project title",
         "about": "Several changes await an operator decision.",
         "decide": "Start the rollout this week?",
         "options": [{"value": "yes", "label": "Start this week", "hint": "Unblocks work"},
                     {"value": "no", "label": "Wait until next week"}],
         "recommend_value": "yes", "close": "release"},
        {"key": "merge.task-two", "type": "merge", "repo": "sample/project",
         "title": "Merge reviewed change", "detail": "Checks were green when composed.",
         "risk": "low", "pr_url": "https://github.com/sample/project/pull/42",
         "options": [{"value": "merge", "label": "Merge now"},
                     {"value": "hold", "label": "Keep waiting"}], "recommend_value": "merge"},
    ],
}
queue = home / "state/captains-call.json"
queue.write_text(json.dumps(payload))
env = dict(os.environ, FM_HOME=str(home), FM_TEST_LOG=str(tmp))
pane = str(fake / "fm-captain-pane.py")

def render(width):
    result = subprocess.run([pane, "--queue", str(queue), "--render", "--width", str(width),
                             "--height", "40"], env=env, capture_output=True, text=True, check=True)
    for line in result.stdout.splitlines():
        assert len(line) <= width, (width, line)
    return result.stdout

small, large = render(40), render(100)
assert "RECOMMENDED" in small and "Project: sample/project" in small
assert "Choose the next deployment window" in large
assert small.count("deployment") == 1

def drive(keys, width=40, resize=False, program=pane):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, width, 0, 0))
    proc = subprocess.Popen([program, "--queue", str(queue)], env=env, stdin=slave,
                            stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and b"[1]" not in output:
        if select.select([master], [], [], 0.1)[0]:
            output.extend(os.read(master, 65536))
    assert b"[1]" in output, output
    if resize:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 40, 0, 0))
        proc.send_signal(signal.SIGWINCH)
        time.sleep(0.15)
        if select.select([master], [], [], 0.1)[0]:
            resized = os.read(master, 65536)
            assert b"deployment window" in resized, resized
    os.write(master, keys)
    time.sleep(0.35)
    os.write(master, b"q")
    deadline = time.monotonic() + 4
    while proc.poll() is None and time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
    if proc.poll() is None:
        proc.kill()
        proc.wait()
        raise AssertionError(bytes(output)[-3000:])
    os.close(master)
    assert proc.returncode == 0, proc.returncode
    return bytes(output)

drive(b"1", width=100, resize=True)
hold = (tmp / "fm-captain-hold.sh.stdin").read_text()
assert "held-task\tyes\tStart this week\trelease" in hold, hold
notice = (tmp / "fm-inbox.sh.args").read_text()
assert "key=held-task; selection=option; value=yes" in notice, notice

payload["captains_call"] = [payload["captains_call"][1]]
queue.write_text(json.dumps(payload))
merge_render = render(40)
row = next(i for i, line in enumerate(merge_render.splitlines(), 1) if "[1] Merge now" in line)
drive(("\x1b[<0;3;%sM" % row).encode())
assert (tmp / "fm-captain-hold.sh.stdin").read_text() == hold
notice = (tmp / "fm-inbox.sh.args").read_text()
assert "key=merge.task-two; selection=option; value=merge" in notice, notice
assert "Resolve the PR from task metadata" in notice
drive(b"1", program=str(root / "bin/fm-captain-pane.py"))
wakes = (home / "state/.wake-queue").read_text()
assert "\tcheck\tinbox:" in wakes, wakes
skipped = drive(b"s")
assert b"Nothing needs your answer now" in skipped
assert (tmp / "fm-inbox.sh.args").read_text() == notice
source = tmp / "payload.json"
source.write_text(json.dumps(payload))
subprocess.run([str(root / "bin/fm-bearings-board.sh"), "queue", str(source)],
               env=env, capture_output=True, text=True, check=True)
published = json.loads(queue.read_text())
assert published["captains_call"] == payload["captains_call"]
assert subprocess.check_output([str(root / "bin/fm-bearings-board.sh"), "queue-path"],
                               env=env, text=True).strip() == str(queue)
payload["captains_call"] = [{"key": "held-task", "type": "decision", "repo": "sample/project",
                             "title": "Re-check this call", "options": [{"value": "reconcile", "label": "Reconcile"}]}]
queue.write_text(json.dumps(payload))
drive(b"1")
hold_args = (tmp / "fm-captain-hold.sh.args").read_text()
assert "bind captain-pane" in hold_args
assert "reconcile-requests --source-id captain-pane --source captain pane" in hold_args
assert (tmp / "fm-captain-hold.sh.stdin").read_text().endswith("held-task\n")
hold_args = (tmp / "fm-captain-hold.sh.args").read_text()
payload["captains_call"] = [{"key": "cred-api-token", "type": "credential", "repo": "sample/project",
                             "title": "Provide the API token", "options": [{"value": "provided", "label": "Token is in the vault"}]}]
queue.write_text(json.dumps(payload))
drive(b"1")
assert (tmp / "fm-captain-hold.sh.args").read_text() == hold_args
notice = (tmp / "fm-inbox.sh.args").read_text()
assert "key=cred-api-token; selection=option; value=provided" in notice, notice
print("ok - captain pane narrow/wide layout, resize, key and mouse routing")
PY

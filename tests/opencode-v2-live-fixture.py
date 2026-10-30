#!/usr/bin/env python3
"""Exercise the real V2 server and Firstmate hooks with a local protocol fixture."""

import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def run_worker_attribution(lab):
    """AGT-006: native shell commits carry their server-created session ID.

    The oracle is the session returned by the real HTTP API, compared with
    Git-parsed trailers. No model-turn event is supplied to mask a missing ID.
    """
    repo = Path(__file__).resolve().parent.parent
    project = lab / "worker"
    fmhome = lab / "fmhome"
    hooks = fmhome / "state/native-session.git-hooks"
    # Only the pane is simulated to obtain the actual generated worker plugin
    # and installed hooks; shell execution below uses the native server.
    subprocess.run(["bash", "-c", '''
set -eu
. "$1/tests/fixtures.sh"
fm_test_spawn_home "$2/fmhome" opencode
fm_test_spawn_brief "$2/fmhome" native-session
fm_git_worktree "$2/project" "$2/worker" native-session
git -C "$2/project" remote set-url origin git@github.com:t27sol/example.git
git -C "$2/project" config "url.file://$2/project.origin.git.insteadOf" git@github.com:t27sol/example.git
fakebin=$(fm_test_make_spawn_fakebin "$2/fake")
FM_FAKE_LAUNCH_LOG="$2/launch.log" fm_test_run_spawn "$2/fmhome" "$2/worker" "$fakebin" \
  native-session "$2/project" --mode no-mistakes --yolo off
''', "worker-attribution", str(repo), str(lab)], check=True)
    home = lab / "home"
    home.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("OPENCODE_", "FM_", "XDG_"))}
    env.update(HOME=str(home), TMPDIR=str(lab), OPENCODE_DB=str(lab / "native.db"), OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_DISABLE_AUTOUPDATE="1", OPENCODE_DISABLE_LSP_DOWNLOAD="1", GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="core.hooksPath", GIT_CONFIG_VALUE_0=str(hooks))
    for kind in ("CONFIG", "DATA", "CACHE", "STATE"):
        path = home / kind.lower()
        path.mkdir()
        env[f"XDG_{kind}_HOME"] = str(path)
    (project / "opencode.json").write_text(json.dumps({"snapshots": False, "permissions": [{"action": "*", "resource": "*", "effect": "allow"}]}))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    logpath = lab / "server.log"
    headers = {"Content-Type": "application/json"}

    def api(path, body=None):
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode() if body is not None else None, headers=headers)
        with urllib.request.urlopen(request, timeout=20) as response:
            data = response.read()
            return json.loads(data) if data else None

    def until(check, label):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(0.1)
        raise RuntimeError(f"Timed out: {label}\n{logpath.read_text()}")

    with logpath.open("w") as log:
        process = subprocess.Popen(["opencode", "serve", "--hostname", "127.0.0.1", "--port", str(port)], cwd=project, env=env, stdout=log, stderr=log)
        try:
            password = until(lambda: next((s.removeprefix("server password ") for s in logpath.read_text().splitlines() if s.startswith("server password ")), None), "server readiness")
            headers["Authorization"] = "Basic " + base64.b64encode(f"opencode:{password}".encode()).decode()
            version = api("/api/info")["version"]
            query = urllib.parse.urlencode({"location[directory]": str(project)})
            until(lambda: any(p["id"] == "fm.busy-state" and p["state"]["status"] == "active" for p in api("/api/plugin?" + query)["data"]), "generated worker plugin readiness")
            sid = api("/api/session", {"location": {"directory": str(project)}, "agent": "build"})["data"]["id"]
            for attempt in range(2):
                before = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project)
                api(f"/api/session/{sid}/shell", {"command": f'git -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m "fix: native shell attribution {attempt}"'})
                until(lambda: subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project) != before, "native shell commit")
                message = subprocess.check_output(["git", "log", "-1", "--format=%B"], cwd=project)
                trailers = subprocess.check_output(["git", "interpret-trailers", "--parse"], input=message).decode().splitlines()
                assert trailers.count(f"Agent-Session: {sid}") == 1, (sid, trailers)
                assert "Co-authored-by: opencode <noreply@firstmate.invalid>" in trailers, trailers
                assert "Agent-Platform: opencode" in trailers, trailers
            print(f"ok - OpenCode {version} native shell commits retain session {sid} without a model turn")
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def run(lab):
    repo = Path(__file__).resolve().parent.parent
    project = lab / "project"
    home = lab / "home"
    fmhome = lab / "fmhome"
    project.mkdir()
    home.mkdir()
    (fmhome / "state").mkdir(parents=True)
    (fmhome / "config").mkdir()
    shutil.copytree(repo / "bin", project / "bin")
    # Copy only the tracked primary plugins: a worker-generated busy-state plugin
    # in this checkout would report into the operator's own home.
    shutil.copytree(repo / ".opencode/plugins", project / ".opencode/plugins", ignore=shutil.ignore_patterns("fm-busy-state.js"))
    (project / "AGENTS.md").write_text("# Isolated native integration fixture\n")
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    slow_entered = threading.Event()
    slow_release = threading.Event()
    requests = []
    commands = {
        "CASE_CD": "cd ..; printf escaped > cd-escaped",
        "CASE_ARM": "bin/fm-watch-arm.sh --restart; printf bundled > arm-escaped",
    }

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(body)
            messages = body.get("messages", [])
            last_user = max((i for i, item in enumerate(messages) if item.get("role") == "user"), default=0)
            text = json.dumps(messages[last_user].get("content", ""))
            followup = any(item.get("role") == "tool" for item in messages[last_user + 1:])
            if "CASE_FAIL" in text and not followup:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"error":{"message":"isolated provider failure fixture","type":"invalid_request_error"}}')
                return
            if "CASE_INTERRUPT" in text and not followup:
                slow_entered.set()
                slow_release.wait(timeout=10)
            command = next((value for key, value in commands.items() if key in text), None) if not followup else None
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                return
            delta = {"role": "assistant", "content": "NATIVE_FIXTURE_ACK"}
            if command:
                delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "call_fixture", "type": "function", "function": {"name": "shell", "arguments": json.dumps({"command": command, "description": "Isolated behavioral guard regression"})}}]}
            chunk = {"id": "chatcmpl-fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture", "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
            try:
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                chunk["choices"][0] = {"index": 0, "delta": {}, "finish_reason": "tool_calls" if command else "stop"}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    config = {
        "model": "fixture/native",
        "agents": {"build": {"model": "fixture/native#proof"}},
        "snapshots": False,
        "permissions": [{"action": "*", "resource": "*", "effect": "allow"}],
        "providers": {"fixture": {"package": "@opencode/ai/providers/openai-compatible", "settings": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1", "apiKey": "isolated-test-not-a-secret"}, "models": {"native": {"capabilities": {"tools": True, "input": ["text"], "output": ["text"]}, "limit": {"context": 100000, "output": 1000}, "variants": [{"id": "proof", "body": {"fixture_variant": "proof"}}]}}}},
    }
    (project / "opencode.json").write_text(json.dumps(config))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(("OPENCODE_", "FM_", "XDG_")) or key in ("TMUX", "HERDR_ENV", "NO_MISTAKES_GATE"):
            del env[key]
    env.update(HOME=str(home), TMPDIR=str(lab), FM_HOME=str(fmhome), FM_ROOT_OVERRIDE=str(project), FM_BACKEND="tmux", FM_POLL="1", FM_SIGNAL_GRACE="0", FM_HEARTBEAT="600", TMUX_TMPDIR=str(lab), OPENCODE_DB=str(lab / "native.db"), OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_DISABLE_AUTOUPDATE="1", OPENCODE_DISABLE_LSP_DOWNLOAD="1")
    for kind in ("CONFIG", "DATA", "CACHE", "STATE"):
        path = home / kind.lower()
        path.mkdir()
        env[f"XDG_{kind}_HOME"] = str(path)
    logpath = lab / "server.log"
    log = logpath.open("w")
    process = subprocess.Popen(["opencode", "serve", "--hostname", "127.0.0.1", "--port", str(port)], cwd=project, env=env, stdout=log, stderr=log)
    headers = {}

    def api(path, body=None, method=None):
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode() if body is not None else None, method=method, headers={**headers, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                data = response.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"API {path} returned {error.code}: {error.read().decode()}") from None

    def until(check, label):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(0.1)
        raise RuntimeError(f"Timed out: {label}")

    try:
        password = until(lambda: next((line.removeprefix("server password ") for line in logpath.read_text().splitlines() if line.startswith("server password ")), None), "server readiness")
        headers["Authorization"] = "Basic " + base64.b64encode(f"opencode:{password}".encode()).decode()
        version = api("/api/info")["version"]
        location_query = urllib.parse.urlencode({"location[directory]": str(project)})
        # Port readiness precedes asynchronous location/plugin initialization.
        # Wait through the public registry before creating a session, otherwise
        # its session.created event can precede the startup-nudge subscription.
        def plugins_ready():
            plugins = [p for p in api("/api/plugin?" + location_query)["data"] if p.get("id", "").startswith("fm.primary.")]
            return plugins if len(plugins) == 5 and all(p["state"]["status"] == "active" for p in plugins) else None

        until(plugins_ready, "native Firstmate plugin readiness")
        configured_model = until(lambda: next((a.get("model") for a in api("/api/agent?" + location_query)["data"] if a["id"] == "build"), None), "configured build-agent model")
        assert configured_model == {"providerID": "fixture", "id": "native", "variant": "proof"}, configured_model
        session = api("/api/session", {"location": {"directory": str(project)}, "agent": "build", "model": configured_model})["data"]
        sid = session["id"]
        api(f"/api/session/{sid}/prompt", {"text": "Native plugin smoke test."})
        until(lambda: api(f"/api/session/{sid}")["data"].get("outcome") == "succeeded", "native prompt completion")
        firstmate = [p for p in api("/api/plugin")["data"] if p.get("id", "").startswith("fm.primary.")]
        assert len(firstmate) == 5 and all(p["state"]["status"] == "active" for p in firstmate), firstmate
        print(f"ok - OpenCode {version} loaded all five V2 Firstmate plugins")
        context = lambda: api(f"/api/session/{sid}/context")["data"]
        until(lambda: sum(m["type"] == "user" and "session-start:" in m.get("text", "") for m in context()) == 1, "native startup nudge")
        assert any(r.get("fixture_variant") == "proof" for r in requests), "selected native agent model variant did not reach the provider"
        print("ok - V2 parses the build-agent model variant and applies it when selected")
        for case, reason in (("CASE_CD", "persistent-cd"), ("CASE_ARM", "watcher-redirection")):
            admitted = api(f"/api/session/{sid}/prompt", {"text": case})["data"]["id"]

            def completed_context():
                messages = context()
                index = next((i for i, m in enumerate(messages) if m["id"] == admitted), None)
                return messages if index is not None and any(m["type"] == "idle" for m in messages[index + 1:]) else None

            messages = until(completed_context, case + " completion")
            tools = [c for m in messages for c in m.get("content", []) if c.get("type") == "tool" and c.get("state", {}).get("input", {}).get("command") == commands[case]]
            assert tools and tools[-1]["state"]["status"] == "error", tools
            assert reason in tools[-1]["state"]["error"]["message"]
            assert not (lab / "cd-escaped").exists() and not (project / "arm-escaped").exists()
            print(f"ok - native shell execute.before rejects {reason} before execution")
        (fmhome / "state/task.meta").write_text("project=fixture\n")
        api(f"/api/session/{sid}/prompt", {"text": "CASE_GUARD"})
        until(lambda: any("TURN WOULD END BLIND" in m.get("text", "") for m in context()), "native turn-end guard follow-up")
        print("ok - native terminal event admits a turn-end guard follow-up")
        (fmhome / "state/.lock").write_text(str(process.pid) + "\n")
        api(f"/api/session/{sid}/prompt", {"text": "CASE_WATCH_ARM"})
        lock = fmhome / "state/.watch.lock/pid"
        until(lock.exists, "watcher arming")
        first_watcher = lock.read_text().strip()
        (fmhome / "state/task.status").write_text("done: native fixture notification\n")
        until(lambda: any("WATCHER FIRED" in m.get("text", "") for m in context()), "native watcher notification")
        until(lambda: lock.exists() and lock.read_text().strip() != first_watcher, "successor watcher")
        print("ok - native watcher prompt delivery preserves a live successor")
        api(f"/api/session/{sid}/prompt", {"text": "CASE_INTERRUPT"})
        until(slow_entered.is_set, "controlled active native model turn")
        assert api(f"/api/session/{sid}/interrupt?resume=false", method="POST")["interrupted"]
        slow_release.set()
        until(lambda: api(f"/api/session/{sid}")["data"].get("outcome") == "interrupted", "interrupted native turn")
        assert lock.exists()
        print("ok - native interrupted turn retains watcher supervision")
        api(f"/api/session/{sid}/prompt", {"text": "CASE_FAIL"})
        until(lambda: api(f"/api/session/{sid}")["data"].get("outcome") == "failed", "failed native turn")
        assert lock.exists()
        assert sum(m["type"] == "user" and "session-start:" in m.get("text", "") for m in context()) == 1
        print("ok - native failed turn retains supervision and startup remains exactly once")
    finally:
        slow_release.set()
        try:
            subprocess.run([str(project / "bin/fm-watch-arm.sh"), "--stop"], cwd=project, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            provider.shutdown()
            provider.server_close()
            log.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="fm-opencode-v2-live-") as directory:
        if sys.argv[1:] == ["--worker-attribution"]:
            run_worker_attribution(Path(directory).resolve())
        else:
            run(Path(directory).resolve())
    print("ok - private OpenCode server, provider, watcher, configuration and database cleaned")

import json
import os
from pathlib import Path
import re
import shlex
import subprocess as sp
import time

root = Path.cwd()
lab = root / '.c'
evidence = Path('~/.no-mistakes/evidence/01M5SM9R5JFPRS1AS5R994DY0S/round2')
env = os.environ.copy()
for name in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'CLAUDECODE', 'FM_CREW_STATE_BIN', 'FM_TASK_ID'):
    env.pop(name, None)
env.update(FM_HOME=str(lab), TMUX_TMPDIR=str(lab / 'tmux'), FM_BACKEND='tmux')
watch = None
control = bool(os.environ.get('LIVE_STUCK_CONTROL'))
log = (evidence / 'live-completion-clearing.txt').open('w')

def note(s):
    print(s, flush=True)
    log.write(s + '\n')
    log.flush()

def run(args, check=True, **kw):
    p = sp.run(args, cwd=root, env=env, text=True, stdout=sp.PIPE, stderr=sp.PIPE, **kw)
    if check and p.returncode:
        raise RuntimeError(f'{args}: exit={p.returncode}: {p.stderr} {p.stdout}')
    return p

def tm(*args, **kw):
    return run(['tmux', '-L', 'fm-lab', *args], **kw)

def pane():
    return tm('capture-pane', '-p', '-S', '-2000', '-t', 'primary').stdout

def response(token):
    msg = json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'Reply with only ' + token + '. Do not use tools.'}})
    tm('send-keys', '-l', '-t', 'primary', msg)
    tm('send-keys', '-t', 'primary', 'Enter')
    end = time.monotonic() + 55
    while time.monotonic() < end:
        text = pane()
        if 'Pane is dead' in text:
            (evidence / 'stream-setup-error.txt').write_text(text)
            raise RuntimeError('Claude stream process exited: ' + text)
        # A result event proves an actual upstream model turn completed.
        flat = text.replace('\n', '')
        if '"type":"result"' in flat and ('"result":"' + token + '"') in flat and '"is_error":false' in flat:
            (evidence / (token + '.txt')).write_text(text)
            note('Actual Claude upstream turn completed: ' + token)
            return
        if 'authentication_error' in flat or 'Not logged in' in flat:
            raise RuntimeError('Claude normal login unavailable: ' + text)
        time.sleep(1)
    (evidence / 'stream-timeout.txt').write_text(pane())
    raise RuntimeError('No completed Claude stream-json result within 55 seconds')

def meta(kind='ship', gen='lab-one'):
    (lab / 'state/worker.meta').write_text(f'window=primary:fm-worker\nbackend=tmux\nkind={kind}\nharness=claude\nspawn_gen={gen}\nworktree={lab}/projects/worker\n')

def status(line):
    f = lab / 'state/worker.status'
    f.write_text(line + '\n')
    run(['bash', '-c', '. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/worker.status"'])

def start_watch(label):
    global watch
    p = evidence / (label + '-watch.txt')
    out = p.open('w')
    e = env.copy()
    e.update(FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_STALE_ESCALATE_SECS='3', FM_PAUSE_RESURFACE_SECS='2', FM_SECONDMATE_LIVENESS_SECS='999999', FM_CREW_STATE_NO_FORGE='1')
    if os.environ.get('LIVE_STUCK_ONLY'):
        e.update(FM_BUSY_TURN_MAX_SECS='2', FM_STALE_ESCALATE_SECS='60')
    watch = sp.Popen(['bash', 'bin/fm-watch.sh'], cwd=root, env=e, stdout=out, stderr=sp.STDOUT)
    out.close()
    return p

def stop_watch():
    global watch
    if watch is not None:
        if watch.poll() is None:
            watch.terminate()
        rc = watch.wait(timeout=15)
        note(f'Watcher reaped: exit={rc}')
        watch = None

def acknowledge():
    run(['bash', '-c', r'''
      err="$FM_HOME/state/drain.err"
      bin/fm-wake-drain.sh > "$FM_HOME/state/drain.out" 2> "$err" || exit
      seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
      gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
      if [ -n "$seq" ] && [ -n "$gen" ]; then
        bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"
      fi
    '''])

def quiet(label, secs=9):
    p = start_watch(label)
    first = None
    beats = set()
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if watch.poll() is not None:
            raise RuntimeError(label + ' unexpectedly exited: ' + p.read_text())
        beat = lab / 'state/.last-watcher-beat'
        if beat.exists():
            beats.add(int(beat.stat().st_mtime))
        time.sleep(.5)
    queue = lab / 'state/.wake-queue'
    assert not queue.exists() or not queue.read_text().strip(), queue.read_text()
    assert len(beats) >= 3, ('insufficient completed polls', beats)
    note(f'{label}: no wake across {len(beats)} beacon timestamps; pause cadence=2s, endpoint interval=3s')
    stop_watch()
    acknowledge()

def event(label, expected):
    p = start_watch(label)
    rc = watch.wait(timeout=20)
    text = p.read_text()
    note(f'{label}: watcher exit={rc}: {text.strip()}')
    assert rc == 0 and expected in text, text
    queue = (lab / 'state/.wake-queue').read_text()
    note('Durable wake: ' + queue.strip())
    stop_watch()
    acknowledge()

def active_to_unreadable():
    status('working: awaiting actual Claude model response')
    parent = tm('display-message', '-p', '-t', 'primary', '#{pane_pid}').stdout.strip()
    children = run(['pgrep', '-P', parent]).stdout.split()
    agents = [pid for pid in children if 'claude' in run(['ps', '-p', pid, '-o', 'comm=']).stdout.lower()]
    assert len(agents) == 1, (parent, children, agents)
    pid = agents[0]
    record = lab / 'state/worker.busy-state'
    message = json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'Reply with only LAB_FROZEN_RESPONSE. Do not use tools.'}})
    tm('send-keys', '-l', '-t', 'primary', message)
    tm('send-keys', '-t', 'primary', 'Enter')
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and 'state=busy ' not in record.read_text():
        time.sleep(.02)
    assert 'state=busy ' in record.read_text(), record.read_text()
    tm('run-shell', 'kill -STOP ' + pid)
    try:
        note('Actual Claude process frozen during a genuine UserPromptSubmit turn; ' + record.read_text().strip())
        probe = run(['bash', '-c', '. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-worker']).stdout.strip()
        note('Frozen endpoint probe: ' + probe)
        assert probe == 'alive', probe
        verdict = run(['bash', 'bin/fm-crew-state.sh', 'worker']).stdout.strip()
        note('Execution proof: ' + verdict)
        assert verdict.startswith('state: working '), verdict
        out = start_watch('completion-clears-active-timer')
        timer = lab / 'state/.stale-since-primary_fm-worker'
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not timer.exists() and watch.poll() is None:
            time.sleep(.1)
        assert timer.exists(), out.read_text()
        original = timer.read_text()
        note('Watcher established its own stuck timer: ' + original.strip())
        tm('run-shell', 'kill -CONT ' + pid)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and 'state=idle ' not in record.read_text():
            time.sleep(.1)
        assert 'state=idle ' in record.read_text(), 'real Claude Stop hook did not complete'
        status('done: actual Claude response completed; no work remaining')
        verdict = run(['bash', 'bin/fm-crew-state.sh', 'worker']).stdout.strip()
        note('Genuine completion state: ' + verdict)
        assert verdict.startswith('state: done '), verdict
        beats = set()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert watch.poll() is None, out.read_text()
            beat = lab / 'state/.last-watcher-beat'
            if beat.exists():
                beats.add(int(beat.stat().st_mtime))
            time.sleep(.2)
        assert len(beats) >= 3, beats
        assert not timer.exists(), 'completed worker retained earlier execution timer'
        queue = lab / 'state/.wake-queue'
        assert not queue.exists() or not queue.read_text().strip(), queue.read_text()
        note('LIVE COMPLETION CLEARING PASSED: established timer removed, no wake across ' + str(len(beats)) + ' beacon timestamps')
        stop_watch()
    finally:
        tm('run-shell', 'kill -CONT ' + pid, check=False)

try:
    run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)])
    (lab / 'tmux').mkdir()
    run(['git', 'init', '-q', str(lab / 'projects/worker')])
    (lab / 'tmux.conf').write_text('set -g remain-on-exit on\nset -g history-limit 5000\n')
    gen = run(['bash', 'bin/fm-busy-event.sh', 'arm', str(lab / 'state'), 'worker', '--state', 'idle', '--source', 'claude-hook', '--event', 'lab-start']).stdout.strip()
    hooks = {}
    for event_name, state_name in [('UserPromptSubmit', 'busy'), ('Stop', 'idle')]:
        hook = shlex.join(['bash', str(root / 'bin/fm-busy-event.sh'), 'apply', str(lab / 'state'), 'worker', state_name, '--gen', gen, '--source', 'claude-hook', '--event', event_name])
        hooks[event_name] = [{'hooks': [{'type': 'command', 'command': hook}]}]
    settings = lab / 'claude-settings.json'
    settings.write_text(json.dumps({'hooks': hooks}))
    cli = ['claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--no-session-persistence', '--setting-sources', '', '--settings', str(settings), '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--system-prompt', 'You are a disposable watcher validation endpoint. Only repeat the requested token. No tools or file actions.', '--tools', '', '--disable-slash-commands']
    note('CLI: ' + shlex.join(cli))
    note('Version: ' + run(['claude', '--version']).stdout.strip())
    run(['tmux', '-f', str(lab / 'tmux.conf'), '-L', 'fm-lab', 'new-session', '-d', '-x', '120', '-y', '40', '-s', 'primary', '-n', 'fm-worker', '-c', str(root), '-e', 'FM_HOME=' + str(lab), 'cat | ' + shlex.join(cli)])
    env['TMUX'] = tm('display-message', '-p', '-t', 'primary', '#{socket_path},#{pid},0').stdout.strip()
    note('Private grid: ' + tm('display-message', '-p', '-t', 'primary', '#{pane_width}x#{pane_height}').stdout.strip())
    response('LAB_READY_ONE')
    meta()
    if os.environ.get('LIVE_STUCK_ONLY'):
        active_to_unreadable()
        raise SystemExit(0)
    probe = run(['bash', '-c', '. bin/fm-backend.sh; fm_backend_agent_state tmux primary:fm-worker']).stdout.strip()
    note('Real endpoint probe: ' + probe)
    assert probe == 'alive', probe
    status('paused [at=1000000000]: awaiting external review until 2000-01-01T00:00Z')
    verdict = run(['bash', 'bin/fm-crew-state.sh', 'worker']).stdout.strip()
    note('Real crew-state: ' + verdict)
    assert verdict.startswith('state: paused '), verdict
    # Deliberately listing an ordinary worker cannot bypass the ban.
    (lab / 'config/secondmate-idle-checkins').write_text('worker\n')
    quiet('paused-ship-even-if-listed')
    meta('scout')
    status('done: disposable scout report delivered')
    response('LAB_READY_TWO')
    quiet('done-scout-after-real-pane-change')
    response('LAB_CHURN_THREE')
    (lab / 'config/turnend-churn-absorb').touch()
    (lab / 'state/worker.turn-ended').touch()
    event('deferred-turnend-delivery', 'signal: ')
    triage = (lab / 'state/.watch-triage.log').read_text()
    assert 'absorbed benign signal:' in triage, triage
    (evidence / 'live-triage.txt').write_text(triage)
    quiet('deferred-turnend-does-not-repeat')
    (lab / 'config/turnend-churn-absorb').unlink()
    meta('secondmate')
    status('paused [at=1000000000]: awaiting external review')
    (lab / 'config/secondmate-idle-checkins').unlink()
    quiet('secondmate-default-off')
    (lab / 'config/secondmate-idle-checkins').write_text('worker-other\n')
    quiet('secondmate-exact-id-required')
    (lab / 'config/secondmate-idle-checkins').write_text('worker\n')
    event('secondmate-explicit-opt-in', 'stale: primary:fm-worker')
    meta('ship')
    (lab / 'state/worker.status').open('a').write('blocked: live validation event must wake firstmate\n')
    event('new-blocked-event', 'signal: ')
    status('paused: awaiting external review')
    # Remove the owned endpoint while a keeper preserves the private server.
    tm('new-window', '-d', '-t', 'primary', '-n', 'keeper', 'sleep 120')
    tm('kill-window', '-t', 'primary:fm-worker')
    event('paused-endpoint-loss', 'agent missing')
    # Same missing incarnation must not re-notify after acknowledgement.
    quiet('unchanged-missing-endpoint-once', secs=8)
    note('ALL LIVE CHECKS PASSED')
except Exception as ex:
    note('LIVE DRIVER BLOCKED OR FAILED: ' + repr(ex))
    try:
        (evidence / 'last-live-pane.txt').write_text(pane())
    except Exception:
        pass
    raise
finally:
    if os.environ.get('LIVE_STUCK_ONLY') and lab.exists():
        saved = {}
        for entry in (lab / 'state').iterdir():
            if entry.is_file() and entry.name.startswith(('.stale', '.count', '.hash', '.wedge', '.watch-triage', 'worker.busy', 'worker.meta')):
                saved[entry.name] = entry.read_text(errors='replace')
        (evidence / ('live-stuck-control-final-state.json' if control else 'live-completion-final-state.json')).write_text(json.dumps(saved, indent=2))
    stop_watch()
    tm('kill-server', check=False)
    import shutil
    if lab.exists():
        shutil.rmtree(lab)
    note('Private tmux server stopped and disposable lab removed')
    log.close()

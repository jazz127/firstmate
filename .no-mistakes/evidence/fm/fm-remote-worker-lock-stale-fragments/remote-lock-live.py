#!/usr/bin/env python3
"""Drive actual worker executables and queue API; no product/upstream mocks.
Oracle: incident's three orphan fragments must not block a queued command;
existing live ownership/recent-publication guards must protect their records;
cleanup must reject unexpected entries without deleting any lock contents.
"""
import hashlib, json, os, pathlib, shutil, signal, subprocess, tempfile, time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4C5NDNCBSM7FMDBWSHYSC01')
BASH = shutil.which('bash')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='.remote-lock-live-', dir=ROOT))
PROCESSES = []
RESULTS = []
FRAGMENTS = {'.pid.A1b2C3': b'99999999\n', '.start.D4e5F6': b'', '.command.G7h8I9': b''}
PAYLOAD = b'lock recovery delivered this real queued delta read\n'
EMPTY_HASH = hashlib.sha256(b'').hexdigest()
ENV = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(LAB))

def record(name, **facts):
    item = dict(name=name, **facts)
    RESULTS.append(item)
    print(json.dumps(item), flush=True)

def command(argv, env, timeout=20):
    p = subprocess.run(argv, env=env, cwd=ROOT, input=b'', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    return p

def case(name):
    d = LAB / name
    d.mkdir()
    account = d / 'account'; account.mkdir()
    home = d / 'home'
    p = command([BASH, str(ROOT/'bin/fm-lab-home.sh'), 'create', str(home)], ENV)
    assert p.returncode == 0, p.stderr
    (home/'state/proof.log').write_bytes(PAYLOAD)
    state = d/'queue'
    env = dict(ENV, HOME=str(account), FM_HOME=str(home), FM_REMOTE_JOB_STATE_ROOT=str(state),
               FM_REMOTE_JOB_QUEUE_TIMEOUT='20', FM_REMOTE_JOB_TIMEOUT='10', FM_REMOTE_JOB_WAIT_GRACE='0')
    return d, home, state, env

def seed(state, finals=()):
    lock = state/'worker.lock'; lock.mkdir(parents=True, mode=0o700)
    for name, data in FRAGMENTS.items(): (lock/name).write_bytes(data)
    for name in finals:
        (lock/name).write_bytes(b'99999999\n' if name == 'pid' else b'interrupted-owner\n')
    os.utime(lock, (946684800, 946684800))
    return lock

def start(d, env, script=None, supervise=False):
    logfile = d/('supervisor.log' if supervise else 'worker.log')
    f = logfile.open('ab')
    argv = [BASH, str(script or ROOT/'bin/fm-remote-job-worker.sh')]
    if not supervise: argv.append('--serve')
    p = subprocess.Popen(argv, cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
    f.close(); PROCESSES.append(p)
    return p

def wait_for(pred, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred(): return
        time.sleep(.05)
    raise AssertionError('timed out waiting for observable worker state')

def stop(p):
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
        try: p.wait(timeout=12)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL); p.wait(timeout=5)
            raise AssertionError('worker did not shut down after TERM')

def ready(state):
    try:
        lines = (state/'worker.ready').read_text().splitlines()
        return int(lines[0]) if len(lines) == 2 else None
    except (OSError, ValueError): return None

def stage(env, home):
    shell = '''set -eu
. "$1/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$HOME" "$1" "$2" fm-remote-delta-read.sh state/proof.log 0 "$3" 0 </dev/null >/dev/null || { printf '%s\\n' "$FM_REMOTE_JOB_ERROR" >&2; exit 1; }
printf '%s\\n' "$FM_REMOTE_JOB_ID"
'''
    p = command([BASH, '-c', shell, 'stage', str(ROOT), str(home), EMPTY_HASH], env)
    assert p.returncode == 0, p.stderr
    return p.stdout.decode().strip()

def consume(env, job):
    shell = '''set -eu
. "$1/bin/fm-remote-job-lib.sh"
fm_remote_job_wait "$HOME" "$2" || { printf '%s\\n' "$FM_REMOTE_JOB_ERROR" >&2; exit 1; }
printf 'job_exit=%s\\n' "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR" >&2
'''
    p = command([BASH, '-c', shell, 'wait', str(ROOT), job], env, timeout=35)
    assert p.returncode == 0, p.stderr
    text = p.stdout.decode()
    assert text.startswith('job_exit=0\n'), text
    headers, payload = text.split('\n\n', 1)
    fields = dict(line.split('=', 1) for line in headers.splitlines())
    assert fields['status'] == 'delta', text
    assert fields['payload_sha256'] == hashlib.sha256(PAYLOAD).hexdigest(), text
    assert int(fields['payload_bytes']) == len(PAYLOAD), text
    assert payload.encode() == PAYLOAD, text
    assert not p.stderr, p.stderr
    return text

def snapshot(lock):
    out = {}
    for p in lock.iterdir():
        if p.is_symlink(): out[p.name] = ['symlink', os.readlink(p)]
        elif p.is_file(): out[p.name] = ['file', p.read_bytes().hex()]
        elif p.is_dir(): out[p.name] = ['directory', sorted(q.name for q in p.iterdir())]
        else: out[p.name] = ['special', p.lstat().st_mode]
    return out

try:
    # Execute unchanged base worker, then current worker, with identical orphan state.
    d, home, state, env = case('base-counterfactual')
    old_bin = d/'base-bin'; old_bin.mkdir()
    old_script = old_bin/'fm-remote-job-worker.sh'
    p = command(['git', 'show', '9c781e44a88c30be2cda9c24738fee9fd4df110c:bin/fm-remote-job-worker.sh'], ENV)
    assert p.returncode == 0, p.stderr
    old_script.write_bytes(p.stdout); old_script.chmod(0o755)
    shutil.copyfile(ROOT/'bin/fm-remote-job-lib.sh', old_bin/'fm-remote-job-lib.sh')
    lock = seed(state)
    job = stage(env, home)
    before = snapshot(lock)
    baseline_env = dict(env, FM_ROOT_OVERRIDE=str(ROOT))
    worker = start(d, baseline_env, old_script)
    assert worker.wait(timeout=15) == 1
    assert not ready(state)
    assert (state/'jobs'/job/'state').read_text().strip() == 'queued'
    assert snapshot(lock) == before
    log = (d/'worker.log').read_text()
    assert 'cannot acquire or safely reclaim worker ownership' in log
    record('base reproduces reported outage', exit=worker.returncode, job_state='queued', lock_contents=before, stderr=log)
    worker = start(d, env)
    wait_for(lambda: ready(state))
    output = consume(env, job)
    assert all(not (lock/n).exists() for n in FRAGMENTS)
    stop(worker); assert not lock.exists()
    record('target recovers identical orphan lock and queued command', output=output, final_lock='removed after TERM')

    # Check every publication boundary: no finals, command only, command/start,
    # and dead fully published identity plus leftover fragments.
    for label, finals in [('fragments-only', ()), ('command-published', ('command',)),
                          ('start-published', ('command', 'start')), ('dead-final-owner', ('command', 'start', 'pid'))]:
        d, home, state, env = case(label)
        lock = seed(state, finals)
        job = stage(env, home)
        worker = start(d, env)
        wait_for(lambda: ready(state))
        owner = ready(state)
        output = consume(env, job)
        assert owner == worker.pid
        assert sorted(p.name for p in lock.iterdir()) == ['command', 'pid', 'start']
        stop(worker); assert not lock.exists()
        record(label, owner_pid=owner, output=output, final_lock='removed')

    d, home, state, env = case('recent-publication')
    lock = seed(state); os.utime(lock, None)
    before = snapshot(lock)
    worker = start(d, env)
    time.sleep(1)
    assert worker.poll() is None
    assert snapshot(lock) == before and not ready(state)
    started = time.monotonic()
    wait_for(lambda: ready(state), timeout=20)
    elapsed = time.monotonic() - started + 1
    assert elapsed >= 9, elapsed
    output = consume(env, stage(env, home))
    stop(worker); assert not lock.exists()
    record('recent publication protected until grace expires', fragments_unchanged_after_one_second=True,
           startup_seconds=round(elapsed, 2), output=output)

    d, home, state, env = case('live-owner')
    worker = start(d, env); wait_for(lambda: ready(state))
    lock = state/'worker.lock'
    for n, data in FRAGMENTS.items(): (lock/n).write_bytes(data)
    os.utime(lock, (946684800, 946684800))
    before = snapshot(lock)
    contender = command([BASH, str(ROOT/'bin/fm-remote-job-worker.sh'), '--serve'], env)
    assert contender.returncode == 0, contender.stderr
    assert snapshot(lock) == before and ready(state) == worker.pid and worker.poll() is None
    output = consume(env, stage(env, home))
    stop(worker)
    assert not lock.exists() and not (state/'worker.ready').exists()
    record('live owner protected and graceful exit removes fragments', contender_exit=contender.returncode,
           owner_pid=worker.pid, protected_contents=before, output=output, final_lock='removed')

    # Refusal must be non-destructive for both recognized and unexpected entries.
    bad_entries = [('unknown-file', 'unrecognized', 'file'), ('hidden-unknown', '.unrecognized', 'file'),
                   ('short-suffix', '.pid.A1b2C', 'file'), ('long-suffix', '.start.A1b2C3D', 'file'),
                   ('punctuation-suffix', '.command.A1b2_3', 'file'), ('temp-symlink', '.pid.J1k2L3', 'symlink'),
                   ('final-symlink', 'start', 'symlink'), ('temp-directory', '.start.J1k2L3', 'directory'),
                   ('temp-fifo', '.command.J1k2L3', 'fifo')]
    for label, name, kind in bad_entries:
        d, home, state, env = case(label)
        lock = seed(state, ('pid', 'start', 'command'))
        outside = d/'sentinel'; outside.write_bytes(b'preserve sentinel\n')
        entry = lock/name
        if entry.exists(): entry.unlink()
        if kind == 'file': entry.write_bytes(b'preserve unexpected entry\n')
        elif kind == 'symlink': entry.symlink_to(outside)
        elif kind == 'directory': entry.mkdir(); (entry/'child').write_bytes(b'preserve child\n')
        elif kind == 'fifo': os.mkfifo(entry)
        os.utime(lock, (946684800, 946684800))
        before = snapshot(lock)
        p = command([BASH, str(ROOT/'bin/fm-remote-job-worker.sh'), '--serve'], env)
        assert p.returncode == 1, (label, p.returncode, p.stderr)
        assert b'cannot acquire or safely reclaim worker ownership' in p.stderr
        assert snapshot(lock) == before and outside.read_bytes() == b'preserve sentinel\n'
        assert not ready(state)
        record(label, exit=p.returncode, stderr=p.stderr.decode(), lock_contents=before,
               all_entries_preserved=True, sentinel_preserved=True)

    # The executable's Linux supervisor entry is selected via its supported
    # platform setting; all processes, signals, ps/stat and jobs remain native.
    d, home, state, env = case('supervisor-restart')
    env.update(FM_REMOTE_JOB_PLATFORM_OVERRIDE='Linux', FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS='3',
               FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS='1')
    supervisor = start(d, env, supervise=True)
    wait_for(lambda: ready(state))
    child = ready(state); assert child != supervisor.pid
    lock = state/'worker.lock'
    for n, data in FRAGMENTS.items(): (lock/n).write_bytes(data)
    os.kill(child, signal.SIGKILL)
    wait_for(lambda: ready(state) and ready(state) != child, timeout=20)
    replacement = ready(state)
    assert all(not (lock/n).exists() for n in FRAGMENTS)
    output = consume(env, stage(env, home))
    stop(supervisor)
    assert not lock.exists() and not ready(state)
    record('supervisor reclaims killed child with fragments and serves next job',
           host=os.uname().sysname, platform_selector='Linux', killed_child=child, replacement_child=replacement,
           supervisor_pid=supervisor.pid, output=output, final_lock='removed')
    record('validation complete', result='pass', product='actual worker CLI, sourceable queue API and real delta-read script',
           upstream='native process table, filesystem, signals; no SSH/LLM/Herdr dependency or substitute')
except Exception as exc:
    record('validation failed', error=repr(exc))
    raise
finally:
    for p in reversed(PROCESSES):
        if p.poll() is None:
            try: stop(p)
            except Exception as exc: record('cleanup issue', pid=p.pid, error=repr(exc))
        # Only the dedicated process group created by this test can be killed.
        try: os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError: pass
    for logfile in LAB.glob('*/worker.log'):
        shutil.copyfile(logfile, EVIDENCE/(logfile.parent.name+'-worker.log'))
    for logfile in LAB.glob('*/supervisor.log'):
        shutil.copyfile(logfile, EVIDENCE/(logfile.parent.name+'-supervisor.log'))
    (EVIDENCE/'remote-lock-results.json').write_text(json.dumps(RESULTS, indent=2)+'\n')
    shutil.rmtree(LAB)
    print('Disposable workspace removed: '+str(LAB), flush=True)

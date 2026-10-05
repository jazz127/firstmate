import os, subprocess, tempfile, pathlib, time, json, shutil, signal
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4686PH2GP7CEXRMA82HD1G6')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='live-lab-', dir=ROOT/'.gate-lock-runtime'))
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('STATE', 'DATA', 'TMUX', 'NO_MISTAKES_GATE'):
        env.pop(key)
env.update(FM_HOME=str(LAB), TMPDIR=str(LAB), FM_PROCEVENT_CLAIM_ROOT=str(LAB/'claims'))
LIB = str(ROOT/'bin/fm-wake-lib.sh')
children=[]
log=[]
results=[]
def record(text):
    log.append(text); print(text, flush=True)
def run(argv, timeout=10, **kwargs):
    p=subprocess.run(argv, env=env, cwd=ROOT, text=True, capture_output=True, timeout=timeout, **kwargs)
    record('$ '+ ' '.join(map(str,argv))+'\nrc='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    return p

def shell(code, *args, **kwargs):
    return run(['bash','-c','. "$1"; shift; '+code, '_', LIB, *map(str,args)], **kwargs)
def start(code,*args):
    p=subprocess.Popen(['bash','-c','. "$1"; shift; '+code,'_',LIB,*map(str,args)],env=env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    children.append(p); return p

def ps_start(pid):
    return subprocess.check_output(['ps','-p',str(pid),'-o','lstart='],env=dict(env,LC_ALL='C'),text=True).strip()
def stop(p):
    if p.poll() is None:
        p.send_signal(signal.SIGCONT); p.terminate()
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:p.kill();p.wait()
def waitfile(path):
    deadline=time.monotonic()+5
    while not path.exists():
        assert time.monotonic()<deadline, 'no ready file: '+str(path)
        time.sleep(.01)
def case(name,fn):
    if os.environ.get('LIVE_LOCK_ONLY') and os.environ['LIVE_LOCK_ONLY'] not in name: return
    record('\nSCENARIO: '+name)
    try: fn(); results.append(dict(name=name,result='pass'));record('OBSERVED: scenario assertions satisfied')
    except Exception as e:
        results.append(dict(name=name,result='fail',reason=str(e)));record('FAIL: '+repr(e));raise

try:
    run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(LAB)])
    state=LAB/'state'
    def lifecycle():
        previous=subprocess.Popen(['sleep','30']);children.append(previous)
        old=ps_start(previous.pid);stop(previous);time.sleep(1.1)
        unrelated=subprocess.Popen(['sleep','30']);children.append(unrelated)
        current=ps_start(unrelated.pid);assert current!=old
        for suffix, pid, identity in [('reused',unrelated.pid,old),('dead',previous.pid,old)]:
            lock=state/('.remote-reply-lifecycle-'+suffix+'.lock');lock.mkdir()
            (lock/'pid').write_text(str(pid)+'\n');(lock/'lock-owner-start').write_text(identity+'\n')
            cursor=state/'remote-replies'/(suffix+'.cursor');cursor.parent.mkdir(exist_ok=True);cursor.write_text('disposable cursor to retire\n')
            record(f'BEFORE {suffix}: lock PID={pid}, recorded start={identity}, actual live process start={current}; cursor exists={cursor.exists()}')
            p=run([str(ROOT/'bin/fm-procevent-remote-reply.sh'),'retire',suffix],timeout=8)
            assert p.returncode==0 and not cursor.exists() and not lock.is_symlink() and not lock.exists()
            assert unrelated.poll() is None
            record(f'AFTER {suffix}: cursor removed, lifecycle lock released, unrelated PID {unrelated.pid} still alive')
        stop(unrelated)
    case('Remote reply lifecycle retirement recovers mismatched and dead owners',lifecycle)

    def protects():
        lock=state/'.live-exec.lock'
        owner=start('fm_lock_try_acquire "$1" || exit 7; printf "ready\\n"; exec sleep 30',lock)
        assert owner.stdout.readline().strip()=='ready'
        recorded=(lock/'lock-owner-start').read_text().strip()
        assert recorded==ps_start(owner.pid)
        record(f'Owner acquired through real library, then execed sleep: PID={owner.pid}, recorded start={recorded}, OS start={ps_start(owner.pid)}')
        p=shell('fm_lock_acquire_wait_bounded "$1" 1; rc=$?; printf "bounded_rc=%s held_pid=%s\\n" "$rc" "$FM_LOCK_HELD_PID"; [ "$rc" = 124 ] && [ "$FM_LOCK_HELD_PID" = "$2" ]',lock,owner.pid)
        assert p.returncode==0
        for label in ['empty','unreadable']:
            path=lock/'lock-owner-start'
            if label=='empty':path.write_text('')
            else:path.write_text(recorded+'\n');path.chmod(0)
            target=os.readlink(lock)
            p=shell('if fm_lock_try_acquire "$1"; then exit 9; fi; printf "preserved_owner=%s\\n" "$(cat "$1/pid")"',lock)
            assert p.returncode==0 and os.readlink(lock)==target and (lock/'pid').read_text().strip()==str(owner.pid)
            record(f'{label} stored identity: acquisition refused, original owner link preserved')
            path.chmod(0o600)
        (lock/'lock-owner-start').write_text(recorded+'\n')
        stop(owner)
        p=shell('fm_lock_acquire_wait "$1"; printf "recovered_pid=%s\\n" "$(cat "$1/pid")"; fm_lock_release "$1"',lock)
        assert p.returncode==0 and not lock.is_symlink()
    case('Live owner survives exec, bounded contention, and uncertain stored identity',protects)

    def legacy():
        owner=subprocess.Popen(['sleep','30']);children.append(owner)
        lock=state/'.legacy.lock';lock.mkdir();(lock/'pid').write_text(str(owner.pid)+'\n')
        p=shell('if fm_lock_try_acquire "$1"; then exit 9; fi; printf "legacy live PID remains=%s\\n" "$(cat "$1/pid")"',lock)
        assert p.returncode==0 and lock.is_dir() and not lock.is_symlink()
        stop(owner)
        p=shell('fm_lock_acquire_wait "$1"; printf "legacy dead PID recovered by=%s\\n" "$(cat "$1/pid")"; fm_lock_release "$1"',lock)
        assert p.returncode==0 and not lock.exists()
    case('Legacy PID-only locks protect live owners and recover after exit',legacy)

    def handoff():
        lock=state/'.handoff.lock'
        p=shell('''
fm_current_pid caller
sleep 1.1
( fm_lock_try_acquire "$1" || exit 7; touch "$2/ready"; while [ ! -e "$2/release" ]; do sleep 0.02; done; fm_lock_release "$1" ) &
holder=$!
while [ ! -e "$2/ready" ]; do sleep 0.02; done
( sleep 0.5; touch "$2/release" ) &
fm_lock_acquire_wait_bounded "$1" 5 || exit 9
wait "$holder" || exit 10
observed=$(cat "$1/lock-owner-start")
expected=$(LC_ALL=C ps -p "$caller" -o lstart= | sed 's/^[[:space:]]*//')
printf 'handoff caller=%s lock_pid=%s recorded_start=%s OS_start=%s\\n' "$caller" "$(cat "$1/pid")" "$observed" "$expected"
[ "$(cat "$1/pid")" = "$caller" ] && [ "$observed" = "$expected" ] || exit 11
if (fm_lock_try_acquire "$1"); then exit 12; fi
printf 'independent contender refused while caller lives\\n'
fm_lock_release "$1"
fm_lock_try_acquire "$1" || exit 13
printf 'next acquisition succeeds after release\\n'
fm_lock_release "$1"
[ ! -e "$1.steal" ] && [ ! -L "$1.steal" ]
''',lock,LAB,timeout=12)
        assert p.returncode==0
    case('Bounded wait transfers PID and start identity to the live caller',handoff)

    def reaper():
        lock=state/'.reaper.steal'
        owner=start('fm_lock_try_acquire "$1" || exit 7; printf "ready\\n"; exec sleep 30',lock)
        assert owner.stdout.readline().strip()=='ready'
        original=os.readlink(lock);old=(lock/'lock-owner-start').read_text().strip();stop(owner);time.sleep(1.1)
        ready=LAB/'reaper-ready'
        # DEBUG is scheduling instrumentation only. No OS command or product result is substituted.
        reaper=start('''
TARGET=$1; READY=$2
TARGET_OWNER=$(readlink "$TARGET")
fm_current_pid REAPER_PID
set -T
trap 'if [ "${BASHPID:-$$}" = "$REAPER_PID" ] && [ -d "$TARGET_OWNER.reaped.$REAPER_PID" ] && [ ! -e "$READY" ]; then touch "$READY"; kill -STOP "$REAPER_PID"; fi' DEBUG
fm_lock_try_acquire_steal_mutex "$TARGET" || exit 8
trap - DEBUG
printf 'reaper acquired PID=%s recorded_start=%s\\n' "$(cat "$TARGET/pid")" "$(cat "$TARGET/lock-owner-start")"
fm_lock_release "$TARGET"
''',lock,ready)
        waitfile(ready)
        tomb=pathlib.Path(original+'.reaped.'+str(reaper.pid))
        assert tomb.is_dir() and not pathlib.Path(original).exists()
        assert ps_start(reaper.pid)!=old
        record(f'Reaper paused by SIGSTOP before real unlink: PID={reaper.pid}, OS start={ps_start(reaper.pid)}, retained dead-owner start={old}, tombstone present={tomb.is_dir()}')
        p=shell('if fm_lock_try_acquire_steal_mutex "$1"; then exit 9; fi; printf "contender refused while reaper alive\\n"',lock)
        assert p.returncode==0 and os.readlink(lock)==original and tomb.exists()
        reaper.send_signal(signal.SIGCONT)
        out,err=reaper.communicate(timeout=8);record('RESUMED REAPER: rc='+str(reaper.returncode)+'\n'+out+err)
        assert reaper.returncode==0 and not lock.is_symlink() and not tomb.exists()
        assert shell('fm_lock_try_acquire_steal_mutex "$1" || exit 7; printf "successor acquired=%s\\n" "$(cat "$1/pid")"; fm_lock_release "$1"',lock).returncode==0
    case('A live paused reaper excludes contenders despite old tombstone identity',reaper)
finally:
    for p in children:stop(p)
    shutil.rmtree(LAB)
    record('TEARDOWN: all owned processes stopped; disposable lab home removed')
    (EVIDENCE/(os.environ.get('LIVE_LOCK_OUTPUT','live-lock')+'-transcript.log')).write_text('\n'.join(log)+'\n')
    (EVIDENCE/(os.environ.get('LIVE_LOCK_OUTPUT','live-lock')+'-results.json')).write_text(json.dumps(results,indent=2)+'\n')

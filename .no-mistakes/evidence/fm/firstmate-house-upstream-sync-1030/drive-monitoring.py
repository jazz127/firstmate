import json, os, pathlib, shutil, subprocess, tempfile, time, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64Z9JEQBNE8HSXVPR6KM05B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT/'.validation-tmp'))
children=[]
log=[]
def note(s):
    log.append(s); (E/'monitoring-transcript.txt').write_text('\n'.join(log)+'\n')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('HERDR_') or k.startswith('TASKS_AXI_') or k in ['TMUX','NO_MISTAKES_GATE','CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'])}
env.update(FM_HOME=str(lab), PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR=str(lab/'tmp'), FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999', FM_STALE='999999', FM_SKIP_SECONDMATE_INHERIT='1')
def run(args, expected=0, timeout=45, inp=None):
    note('$ '+' '.join(map(str,args)))
    p=subprocess.run(list(map(str,args)),env=env,cwd=ROOT,text=True,input=inp,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    note(p.stdout.rstrip()+f'\n[exit {p.returncode}]')
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
try:
    run(['bin/fm-lab-home.sh','create',lab])
    (lab/'tmp').mkdir(); (lab/'claims').mkdir(); (lab/'config/supervision-host-off').touch()
    note('SCENARIO: heartbeat recovers a decision hidden behind routine progress and resets idle backoff.')
    status=lab/'state/miss.status'
    status.write_text('working: setup\nneeds-decision: choose A or B\nworking: routine progress\n')
    sig=run(['/bin/bash','-c','. bin/fm-wake-lib.sh; fm_wake_signal_sig "$1"','_',status]).strip()
    run(['/bin/bash','-c','. bin/fm-classify-lib.sh; status_presentation_marker_report "$1" "$2"','_',lab/'state/.seen-miss_status',sig])
    (lab/'state/.heartbeat-streak').write_text('3\n')
    beat=lab/'state/.last-heartbeat';beat.touch();os.utime(beat,(time.time()-30,time.time()-30))
    env['FM_HEARTBEAT']='1'
    out=run(['bin/fm-watch.sh'],timeout=40)
    assert out.strip()=='heartbeat',out
    streak=(lab/'state/.heartbeat-streak').read_text().strip()
    note('Persisted idle heartbeat streak after actionable wake: '+streak)
    assert streak=='0'
    drain=run(['bin/fm-wake-drain.sh'])
    assert 'choose A or B' in drain
    note('SCENARIO: replacement monitoring reclaims a live process with an obsolete identity without signalling that process.')
    generation=re.search(r'--recovery-generation (\S+)',drain)
    ack=['bin/fm-wake-drain.sh','--ack-through','1']
    if generation: ack+=['--recovery-generation',generation.group(1)]
    run(ack)
    (lab/'state/miss.status').unlink()
    env['FM_HEARTBEAT']='999999'
    holder=subprocess.Popen(['/bin/sleep','90'],env=env);children.append(holder)
    lock=lab/'state/.watch.lock';lock.mkdir(exist_ok=True)
    (lock/'pid').write_text(str(holder.pid)+'\n')
    (lock/'pid-identity').write_text('obsolete identity no current process emits\n')
    (lock/'fm-home').write_text(str(lab)+'\n')
    (lock/'watcher-path').write_text(str(ROOT/'bin/fm-watch.sh')+'\n')
    out=run(['bin/fm-watch-checkpoint.sh','--seconds','8'],expected=0,timeout=35)
    assert 'check:' in out
    assert holder.poll() is None
    note('Original process remains alive after replacement; no stale watcher lock remains: '+str(not (lock/'pid').exists()))
    assert not (lock/'pid').exists()
    note('ALL MONITORING ASSERTIONS PASSED')
finally:
    for child in children:
        if child.poll() is None: child.terminate()
        child.wait(timeout=15)
    if (lab/'state').exists():
        for command in [['bin/fm-watch-arm.sh','--stop'],['bin/fm-procevent.sh','sweep-home']]:
            try: run(command,timeout=25)
            except Exception as ex: note('Cleanup diagnostic: '+str(ex))
    shutil.rmtree(lab)
    note('Disposable product home removed.')

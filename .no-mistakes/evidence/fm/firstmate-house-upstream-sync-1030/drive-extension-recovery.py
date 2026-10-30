import json, os, pathlib, shutil, subprocess, tempfile, time, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64Z9JEQBNE8HSXVPR6KM05B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT/'.validation-tmp'))
children=[]
log=[]
def note(s):
    log.append(s); (E/'extension-recovery-transcript.txt').write_text('\n'.join(log)+'\n')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('HERDR_') or k.startswith('TASKS_AXI_') or k in ['TMUX','NO_MISTAKES_GATE','CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'])}
env.update(FM_HOME=str(lab), PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR=str(lab/'tmp'), FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999', FM_STALE='999999', FM_SKIP_SECONDMATE_INHERIT='1')
def run(args, expected=0, timeout=45, inp=None):
    note('$ '+' '.join(map(str,args)))
    p=subprocess.run(list(map(str,args)),env=env,cwd=ROOT,text=True,input=inp,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    note(p.stdout.rstrip()+f'\n[exit {p.returncode}]')
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
try:
    run(['bin/fm-lab-home.sh','create',lab]);(lab/'tmp').mkdir()
    note('SCENARIO: interrupted extension launch publishes ownerless readiness; cleanup refuses a live group and reclaims its exact dead group.')
    root=lab/'state/extension-invocations';root.mkdir(mode=0o700)
    token='sha256:'+'a'*64
    ready=root/('a'*64+'.ready.json');owner=root/('a'*64+'.json');release=root/('a'*64+'.release.json')
    barrierlog=open(lab/'barrier.log','w+')
    args=['node',str(ROOT/'bin/fm-extension-launch-barrier.mjs'),token,str(owner),str(ready),str(release),str(os.getpid()),str(ROOT/'docs/examples/process-event-extension/file-signal.mjs'),str(lab),'invoke']
    barrier=subprocess.Popen(args,env=env,cwd=ROOT,stdout=barrierlog,stderr=subprocess.STDOUT,start_new_session=True);children.append(barrier)
    deadline=time.monotonic()+4
    while not ready.exists() and time.monotonic()<deadline:
        assert barrier.poll() is None
        time.sleep(.02)
    assert ready.exists() and not owner.exists()
    original=ready.read_bytes();note('Readiness emitted by real launch barrier:\n'+original.decode())
    out=run(['bin/fm-extension.sh','cleanup-invocations'],expected=1)
    assert barrier.poll() is None and ready.exists()
    rc=barrier.wait(timeout=12);barrierlog.seek(0);note('Real barrier, intentionally never released:\n'+barrierlog.read()+f'[exit {rc}]');barrierlog.close()
    assert rc==125
    ready.chmod(0o644)
    out=run(['bin/fm-extension.sh','cleanup-invocations'],expected=1);assert 'private' in out.lower() and ready.exists()
    ready.chmod(0o600)
    out=run(['bin/fm-extension.sh','cleanup-invocations']);assert 'cleaned-invocations: 1' in out and not ready.exists()
    note('Readiness for the dead exact-token group removed. The live group and unsafe-file cases were refused. No extension, group, or response substitute was used.')
finally:
    for child in children:
        if child.poll() is None:child.terminate()
        child.wait(timeout=15)
    shutil.rmtree(lab);note('Real barrier child awaited and disposable home removed.')

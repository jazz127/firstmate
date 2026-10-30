import json, os, pathlib, shutil, subprocess, tempfile, time, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64Z9JEQBNE8HSXVPR6KM05B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT/'.validation-tmp'))
children=[]
log=[]
def note(s):
    log.append(s); (E/'watcher-replacement-transcript.txt').write_text('\n'.join(log)+'\n')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('HERDR_') or k.startswith('TASKS_AXI_') or k in ['TMUX','NO_MISTAKES_GATE','CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'])}
env.update(FM_HOME=str(lab), PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR=str(lab/'tmp'), FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999', FM_STALE='999999', FM_SKIP_SECONDMATE_INHERIT='1')
def run(args, expected=0, timeout=45, inp=None):
    note('$ '+' '.join(map(str,args)))
    p=subprocess.run(list(map(str,args)),env=env,cwd=ROOT,text=True,input=inp,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    note(p.stdout.rstrip()+f'\n[exit {p.returncode}]')
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
import signal
try:
    run(['bin/fm-lab-home.sh','create',lab]);(lab/'tmp').mkdir();(lab/'claims').mkdir();(lab/'config/supervision-host-off').touch()
    for label,code_root in [('merged',ROOT),('pinned-upstream-b936f040',ROOT/'.validation-tmp/upstream')]:
        note('SCENARIO '+label+': a live monitor with a pre-upgrade identity is replaced, then must exit cleanly without receiving a signal.')
        home=lab/label;home.mkdir();run(['bin/fm-lab-home.sh','create',home]);(home/'config/supervision-host-off').touch()
        caseenv=env.copy();caseenv.update(FM_HOME=str(home),FM_POLL='15',FM_PROCEVENT_CLAIM_ROOT=str(home/'claims'))
        old_output=open(lab/(label+'-old.out'),'w+')
        old=subprocess.Popen([str(code_root/'bin/fm-watch.sh')],env=caseenv,cwd=ROOT,stdout=old_output,stderr=subprocess.STDOUT);children.append(old)
        lock=home/'state/.watch.lock'
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            if (lock/'pid').exists() and (home/'state/.last-watcher-beat').exists():break
            if old.poll() is not None:raise RuntimeError('old watcher exited during setup')
            time.sleep(.1)
        assert (lock/'pid').read_text().strip()==str(old.pid)
        time.sleep(1)
        assert old.poll() is None
        (lock/'pid-identity').write_text('pre-upgrade identity rendering\n')
        (lock/'lock-owner-start').unlink(missing_ok=True)
        caseenv['FM_POLL']='1'
        new_output=open(lab/(label+'-new.out'),'w+')
        new=subprocess.Popen([str(code_root/'bin/fm-watch.sh')],env=caseenv,cwd=ROOT,stdout=new_output,stderr=subprocess.STDOUT);children.append(new)
        newrc=new.wait(timeout=35);oldrc=old.wait(timeout=35)
        new_output.seek(0);old_output.seek(0)
        note('Replacement monitor stdout:\n'+new_output.read()+f'[exit {newrc}]')
        note('Original monitor stdout (never signalled):\n'+old_output.read()+f'[exit {oldrc}]')
        new_output.close();old_output.close()
        assert newrc==0
        note('Expected original exit 0 after handoff; observed '+str(oldrc)+'.')
        assert oldrc==1,'the previously observed failure changed; inspect this result'
    note('REPRODUCED: same real-product failure on merged head and pinned upstream. No backend, process, or response substitutes.')
finally:
    for child in children:
        if child.poll() is None:child.terminate()
        try:child.wait(timeout=15)
        except subprocess.TimeoutExpired:child.kill();child.wait()
    shutil.rmtree(lab);note('Both disposable homes and every monitor child removed.')

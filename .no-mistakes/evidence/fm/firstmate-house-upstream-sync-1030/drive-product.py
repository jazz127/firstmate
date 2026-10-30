import json, os, pathlib, shutil, subprocess, tempfile, time, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64Z9JEQBNE8HSXVPR6KM05B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT/'.validation-tmp'))
children=[]
log=[]
def note(s):
    log.append(s); (E/'product-transcript.txt').write_text('\n'.join(log)+'\n')
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
    note('SCENARIO: registry manual PR text preserves house branch and forge settings; invalid combinations refuse.')
    (lab/'data/projects.md').write_text('- valid [no-mistakes +yolo branch=house/ pr=manual] - disposable project\n- forge [no-mistakes forge=forgejo branch=fix/] - disposable forge project\n- invalid [local-only pr=manual] - invalid combination\n- invalid-forge [no-mistakes forge=gerrit pr=manual] - invalid combination\n')
    assert run(['bin/fm-project-mode.sh','valid']).strip()=='no-mistakes on'
    assert run(['bin/fm-project-mode.sh','--pr','valid']).strip()=='manual'
    assert run(['bin/fm-project-mode.sh','--branch-prefix','valid']).strip()=='house/'
    assert run(['bin/fm-project-mode.sh','--forge','forge']).strip()=='forgejo'
    run(['bin/fm-project-mode.sh','--pr','invalid'],expected=3)
    run(['bin/fm-project-mode.sh','invalid-forge'],expected=3)
    run(['bin/fm-brief.sh','manual-proof','valid','--mode','no-mistakes','--pr','manual','--base-branch','house'])
    brief=(lab/'data/manual-proof/brief.md').read_text()
    (E/'generated-manual-brief.md').write_text(brief)
    note('Generated public brief saved as generated-manual-brief.md.')
    assert 'pr=manual' in brief and 'Base branch: house' in brief
    assert '--skip pr' in brief or '--skip-pr' in brief or '--skip-step pr' in brief
    note('SCENARIO: real monitoring checkpoint times out cleanly using native Perl fallback (GNU timeout absent).')
    assert shutil.which('timeout',path=env['PATH']) is None and shutil.which('gtimeout',path=env['PATH']) is None
    run(['bin/fm-watch-checkpoint.sh','--seconds','2'],expected=124)
    assert not (lab/'state/.watch.lock/pid').exists()
    note('No watcher lock remains after bounded timeout.')
    note('SCENARIO: terminal condition fires once, retires its last source, retains its notification, and supports idempotent handling.')
    ready=lab/'ready'
    run(['bin/fm-procevent-when.sh','arm','terminal-proof','--interval','1','--stable','1','--deadline','30','--condition','/bin/test','-f',ready,'--action','/bin/echo','real terminal payload'])
    ready.write_text('ready\n')
    run(['bin/fm-watch-checkpoint.sh','--seconds','25'],timeout=40)
    for _ in range(100):
        if not (lab/'state/procevent/when-terminal-proof.source').exists(): break
        time.sleep(.1)
    assert not (lab/'state/procevent/when-terminal-proof.source').exists()
    results=list((lab/'state/procevent/when-terminal-proof').glob('*.out'))
    if not results: results=list((lab/'state/procevent').rglob('*.result'))
    note('Persisted source store: '+json.dumps([str(p.relative_to(lab)) for p in (lab/'state/procevent').rglob('*') if p.is_file()]))
    queue=(lab/'state/.wake-queue').read_text()
    note('Durable queue after retirement:\n'+queue)
    assert 'procevent when when-terminal-proof 1' in queue
    first=run(['bin/fm-wake-drain.sh'])
    second=run(['bin/fm-wake-drain.sh'])
    assert 'procevent when when-terminal-proof 1' in first and 'procevent when when-terminal-proof 1' in second
    run(['bin/fm-procevent.sh','handled','when-terminal-proof','1'])
    out=run(['bin/fm-procevent.sh','handled','when-terminal-proof','1'])
    assert 'already-handled: when-terminal-proof 1' in out
    note('SCENARIO complete: real when adapter, runner, watcher, drain, and acknowledgement; no upstream or product substitute.')
    run(['bin/fm-procevent-when.sh','retire','terminal-proof'])
    note('ALL LIVE DRIVER ASSERTIONS PASSED')
finally:
    for child in children:
        if child.poll() is None: child.terminate()
        child.wait(timeout=15)
    if (lab/'state').exists():
        for command in [['bin/fm-watch-arm.sh','--stop'],['bin/fm-procevent.sh','sweep-home']]:
            try: run(command, timeout=25)
            except Exception as ex: note('Cleanup diagnostic: '+str(ex))
    shutil.rmtree(lab)
    note('Disposable product home removed.')

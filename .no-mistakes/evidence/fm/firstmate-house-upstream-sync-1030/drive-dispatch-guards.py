import json, os, pathlib, shutil, subprocess, tempfile, time, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64Z9JEQBNE8HSXVPR6KM05B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT/'.validation-tmp'))
children=[]
log=[]
def note(s):
    log.append(s); (E/'dispatch-guards-transcript.txt').write_text('\n'.join(log)+'\n')
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
    brief=lab/'brief.md';brief.write_text("## Captain's intent\nFix a typo.\n## Firstmate spec\nChange the text.\n")
    note('SCENARIO: optional dispatch remains off without credentials and reports invalid provider settings before API use.')
    out=run(['bin/fm-dispatch-resolve.sh',brief]);assert 'off' in out
    env['FM_DISPATCH_PROVIDER']='openai'
    out=run(['bin/fm-dispatch-resolve.sh',brief],expected=2);assert 'model' in out.lower()
    env['FM_DISPATCH_PROVIDER']='systemone';env['FM_DISPATCH_MODEL']='validation-model';env['FM_DISPATCH_BASE_URL']='ftp://invalid.example'
    out=run(['bin/fm-dispatch-resolve.sh',brief],expected=2);assert 'base' in out.lower() or 'url' in out.lower()
    env['FM_DISPATCH_PROVIDER']='not-a-provider'
    out=run(['bin/fm-dispatch-resolve.sh',brief],expected=2);assert 'provider' in out.lower()
    note('ALL PROVIDER GUARD ASSERTIONS PASSED; no credentials or successful upstream answers were substituted.')
finally:
    shutil.rmtree(lab);note('Disposable home removed.')

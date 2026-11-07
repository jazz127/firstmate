import os, pathlib, signal, subprocess, time, json
root=pathlib.Path.cwd()
scratch=root/'.test-sync-validation'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_')) and k not in ('OPENAI_API_KEY','OPENROUTER_API_KEY','TYPESAFE_API_KEY','CLAUDE_CONFIG_DIR')}
env.update(TMPDIR=str(scratch/'tmp'),FM_HOME=str(scratch/'contract-home'))
home=pathlib.Path(env['FM_HOME'])
for d in ('config','state','data','projects'): (home/d).mkdir(parents=True,exist_ok=True)
results=[]
def record(name,rc,out):
    print(f'{name}: exit={rc}\n{out}',flush=True)
    results.append({'name':name,'exit':rc,'output':out})
def run(name,script,expected=0,input=None,extra=None):
    p=subprocess.run(['bash','-c',script,'live-contract',str(root),str(home)],env=env| (extra or {}),input=input,text=True,capture_output=True,timeout=40)
    record(name,p.returncode,p.stdout+p.stderr)
    assert p.returncode==expected,(name,p.returncode)
    return p.stdout
try:
    mechanism=run('Selected real timeout mechanism','. "$1/bin/fm-timeout-lib.sh"; fm_timeout_mechanism').strip()
    for mechanism_override in ('','bash'):
        label=mechanism_override or mechanism
        extra={'FM_TIMEOUT_MECHANISM_OVERRIDE':mechanism_override}
        output=run(f'{label}: redirected input reaches bounded command','. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 3 cat',input='line one\nline two\n',extra=extra)
        assert output=='line one\nline two\n'
        run(f'{label}: child exit 17 preserved','. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 3 bash -c "exit 17"',expected=17,extra=extra)
        run(f'{label}: deadline reports 124','. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 1 sleep 5',expected=124,extra=extra)
    command=scratch/"literal command;touch INJECTION"
    command.write_text('#!/bin/sh\nprintf "literal-ok:%s\\n" "$#"\n')
    command.chmod(0o700)
    out=run('Literal command filename with spaces and semicolon','. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 3 "$1/.test-sync-validation/literal command;touch INJECTION" argument')
    assert out=='literal-ok:1\n' and not (root/'INJECTION').exists()
    child_script=scratch/'interrupt-child.sh'
    child_script.write_text('#!/bin/bash\ntrap "" TERM\necho $$ > "$1/command.pid"\nsleep 60 &\necho $! > "$1/descendant.pid"\nwait\n')
    child_script.chmod(0o700)
    tracked=[]
    p=subprocess.Popen(['bash','-c','. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 30 "$1/.test-sync-validation/interrupt-child.sh" "$1/.test-sync-validation"','interrupt-test',str(root)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        deadline=time.monotonic()+8
        while not all((scratch/f).exists() for f in ('command.pid','descendant.pid')):
            assert time.monotonic()<deadline,'child startup timeout'
            time.sleep(.05)
        tracked=[int((scratch/f).read_text()) for f in ('command.pid','descendant.pid')]
        p.send_signal(signal.SIGTERM)
        out,err=p.communicate(timeout=8)
        assert p.returncode in (-15,143),(p.returncode,out,err)
        states=[]
        for pid in tracked:
            state=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
            states.append(state or 'absent')
            assert not state or state.startswith('Z'),(pid,state)
        record('Interrupt reaps TERM-ignoring command and descendant',p.returncode,json.dumps({'command_and_descendant_states':states})+'\n'+out+err)
    finally:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGKILL);p.communicate()
        for pid in tracked:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
    (home/'config/claude-accounts').write_text('ordinary\n')
    out=run('Declared Claude list refuses implicit account','. "$1/bin/fm-worker-account-lib.sh"; fm_worker_account_select claude "$2/config" "" claude',expected=1)
    out=run('Declared Claude list refuses undeclared entry','. "$1/bin/fm-worker-account-lib.sh"; fm_worker_account_select claude "$2/config" "" claude "" "" undeclared',expected=1)
    (home/'config/claude-account').write_text('ordinary\n')
    run('Conflicting Claude single pin and list refused','. "$1/bin/fm-worker-account-lib.sh"; fm_worker_account_select claude "$2/config" "" claude "" "" ordinary',expected=1)
    (home/'config/claude-account').unlink()
    run('Claude account selection cannot bleed into Codex','. "$1/bin/fm-worker-account-lib.sh"; fm_worker_account_select codex "$2/config" "" codex "" "" ordinary',expected=1)
    (home/'brief.md').write_text('Disposable dispatch validation brief.\n')
    for n,base in enumerate(('https://user:private@example.invalid','https://example.invalid?key=private','http://localhost:0','file:///local','https://example.invalid/path[bad]')):
        output=run(f'Malformed TypeSafe base {n+1} refused without disclosure','"$1/bin/fm-dispatch-resolve.sh" "$2/brief.md"',expected=2,extra={'FM_DISPATCH_PROVIDER':'typesafe','TYPESAFE_BASE':base})
        # The full stderr output is retained above; it must not echo the rejected value.
        assert base not in results[-1]['output']
    record('All direct contract scenarios completed',0,'No substituted product binaries or upstream responses were used.\n')
finally:
    (evidence/'live-contracts.json').write_text(json.dumps(results,indent=2)+'\n')

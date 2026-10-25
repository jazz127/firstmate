import os, pathlib, subprocess, json, shutil, time, shlex, hashlib
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M5S58Y2CVNE3BFDC2CQ72Z4J')
lab=ROOT/'.test-feedback-live'
log=[]
env=dict(os.environ)
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS'):
    env.pop(k,None)
env['FM_HOME']=str(lab)
cli=str(ROOT/'bin/fm-pr-feedback.sh')
def run(args, check=True, extra=None):
    p=subprocess.run(args,env=extra or env,text=True,capture_output=True,timeout=120)
    if check and p.returncode: raise RuntimeError(str(args)+' '+p.stderr+p.stdout)
    return p

def record(label,text):
    log.append(label+'\n'+text)
    (E/'live-feedback.log').write_text('\n\n'.join(log))
try:
    run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(lab)])
    # A relative Unix socket keeps every intentional write inside the worktree.
    sock='.test-feedback-live/socket'
    launch_env=dict(env,CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',DISABLE_AUTOUPDATER='1')
    launch_env.pop('NO_MISTAKES_GATE',None)
    launch='exec '+shlex.join(['claude','--safe-mode','--tools','','Reply READY and wait. Do not use tools or delegate.'])
    run(['tmux','-S',sock,'new-session','-d','-s','primary','-n','fm-alive','-x','120','-y','40','-c',str(ROOT),launch],extra=launch_env)
    env['TMUX']=run(['tmux','-S',sock,'display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    for _ in range(12):
        time.sleep(1)
        pane=run(['tmux','-S',sock,'capture-pane','-p','-t','primary']).stdout
        if 'READY' in pane or 'Quick safety check' in pane or 'trust' in pane or 'login' in pane: break
    (E/'claude-terminal-before.txt').write_text(pane)
    record('Real Claude TUI, 120 columns x 40 rows',pane)
    # Public data only. Both task records are disposable and no forge write is issued.
    state=lab/'state'
    url='https://github.com/cli/cli/pull/14783'
    for task,target in [('alive','primary:fm-alive'),('exited','primary:fm-absent')]:
        (state/(task+'.meta')).write_text('kind=ship\nmode=direct-PR\nharness=claude\nbackend=tmux\npr='+url+'\nwindow='+target+'\n')
    record('Arm shared feedback check',run([cli,'arm']).stdout)
    run([cli,'enabled'])
    poll=run([cli,'poll'])
    record('First real GitHub sweep',poll.stdout+poll.stderr)
    assert 'tasks=alive,exited' in poll.stdout and 'relaunch=exited' in poll.stdout, poll.stdout
    for task in ('alive','exited'):
        records=list((state/(task+'.inbox')).glob('*.msg'))
        assert len(records)==1,records
        body=records[0].read_text()
        (E/(task+'-inbox.msg')).write_text(body)
        assert 'pullrequestreview-5603453798' in body,body
        assert 'GitHub PR CI event:' in body and 'state=green' in body,body
        # API response bodies are never deposited, only stable pointers.
        assert 'No-mistakes' not in body
        record(task+' persisted inbox',body)
    time.sleep(2)
    after=run(['tmux','-S',sock,'capture-pane','-p','-t','primary']).stdout
    (E/'claude-terminal-after.txt').write_text(after)
    record('Real terminal after feedback doorbell',after)
    for task in ('alive','exited'):
        for message in (state/(task+'.inbox')).glob('*.msg'):
            message.rename(message.parent/'handled'/message.name)
    replay=run([cli,'poll'])
    assert replay.stdout=='',replay.stdout
    assert not list(state.glob('*.inbox/*.msg'))
    record('Second sweep after inbox acknowledgement','stdout='+repr(replay.stdout)+'; zero pending records; handled receipts retained')
    # Exercise enabled's trust binding adversarially.
    shim=state/'pr-feedback.check.sh'
    shim.write_text(shim.read_text()+'# tampered\n')
    refused=run([cli,'enabled'],check=False)
    blocked=run([cli,'poll'],check=False)
    assert refused.returncode != 0 and blocked.returncode != 0
    record('Tampered check refused',f'enabled exit={refused.returncode}; poll exit={blocked.returncode}\n'+blocked.stderr)
    run([cli,'arm'])
    record('Disarm',run([cli,'disarm']).stdout)
    assert run([cli,'enabled'],check=False).returncode != 0
    record('Completion','Real API feedback, CI green, missing-endpoint relaunch, handled replay and registration guards passed.')
finally:
    if lab.exists():
        stopped=run(['tmux','-S','.test-feedback-live/socket','kill-server'],check=False)
        record('Private tmux shutdown',f'exit={stopped.returncode} '+stopped.stderr)
        shutil.rmtree(lab)
    record('Cleanup','Disposable home removed; no forge writes; no default tmux server used.')

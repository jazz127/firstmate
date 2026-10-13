import pathlib,subprocess,os,time,json,shlex
r=pathlib.Path.cwd(); h=r/'.lab/h'; e=pathlib.Path('<operator-home>/.no-mistakes/evidence/01M4SDKM6WTX0CEK2C5DQ3RE1K'); env=os.environ.copy()
for k in list(env):
    if k=='FM_GATE_REFUSE_BYPASS' or k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k,None)
env.update(FM_HOME=str(h),FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',TMUX_TMPDIR='.lab/h/tmux',TMPDIR=str(r/'.test-tmp'),TREEHOUSE_ROOT=str(h/'projects/pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
socket=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env,text=True).strip(); env['TMUX']=socket+',501,0'
log=[]; results=[]; launcher=None
def run(args,timeout=60):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout); log.append('$ '+shlex.join(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n'); return p
try:
    run([str(r/'bin/fm-afk-return.sh'),'check'])
    for action in ['rename']:
        id='test-cancel-'+action+'-'+str(os.getpid())
        run([str(r/'bin/fm-brief.sh'),id,'demo','--scout'])
        b=h/'data'/id/'brief.md'; b.write_text(b.read_text().replace('{TASK}','Verify disposal of a pending launch.').replace('{FIRSTMATE_SPEC}','Only a raw shell waits; do not edit source.'))
        run(['tasks-axi','add',id,'Verify pending launch cancellation','--file',str(h/'data/backlog.md')])
        run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'])
        args=[str(r/'bin/fm-spawn.sh'),id,str(h/'projects/demo'),"bash -c 'read -t 40 -r line'",'--scout']
        launcher=subprocess.Popen(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        meta=h/'state'/f'{id}.meta'; saved=''
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            if launcher.poll() is not None: raise AssertionError('launch ended early: '+launcher.stdout.read())
            if meta.exists():
                saved=meta.read_text()
                # Inspect the staged source command in the real pane to prove Enter reached the launch.
                cap=run(['tmux','-L','fm-lab','capture-pane','-p','-t',f'primary:fm-{id}']).stdout
                command=run(['tmux','-L','fm-lab','display-message','-p','-t',f'primary:fm-{id}','#{pane_current_command}']).stdout.strip()
                if command=='bash':
                    log.append('Observed foreground bash replacing the Treehouse zsh shell, proving the raw builtin read command started after Enter.\n')
                    break
            time.sleep(.2)
        assert saved and command=='bash', 'raw bash command was not observed running after Enter'
        p=run([str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')]); assert p.stdout.strip()=='1',p.stdout
        if action=='rename': run(['tmux','-L','fm-lab','rename-window','-t',f'primary:fm-{id}',f'moved-{id}'])
        launcher.terminate(); out=launcher.communicate(timeout=20)[0]; rc=launcher.returncode; log.append('$ '+shlex.join(args)+'\n'+out+f'[terminated; exit {rc}]\n'); launcher=None
        assert rc!=0
        if action=='close':
            assert not meta.exists(), 'confirmed close retained metadata'
            p=run([str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')]); assert p.stdout.strip()=='0',p.stdout
        else:
            assert meta.exists() and 'cleanup_recovery=launch' in meta.read_text(), 'unconfirmed close discarded capacity'
            p=run([str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')]); assert p.stdout.strip()=='1',p.stdout
            p=run([str(r/'bin/fm-spawn.sh'),'next',str(h/'absent-project'),'--scout']); assert p.returncode==1 and 'caps concurrent workers' in p.stdout,p.stdout
            (h/'state'/f'{id}.status').write_text('working: pending startup cleanup\n')
            p=run([str(r/'bin/fm-afk-return.sh'),'check']); assert '1 task(s) live at return.' in p.stdout,p.stdout
            # Close the relocated endpoint positively, then remove only this disposable scout through its owner.
            run(['tmux','-L','fm-lab','kill-window','-t',f'primary:moved-{id}'])
            (h/'data'/id/'report.md').write_text('The renamed endpoint retained cleanup capacity until explicitly closed.\n')
            run([str(r/'bin/fm-captain-hold.sh'),'complete',id,'--none'])
            p=run([str(r/'bin/fm-teardown.sh'),id]); assert p.returncode==0,p.stdout
        results.append({'name':f'Pending raw-shell launch {action} cancellation preserves the correct capacity and ownership','result':'pass'})
finally:
    if launcher is not None:
        launcher.terminate(); launcher.communicate(timeout=20)
    (e/'live-cancellation-transcript.log').write_text(''.join(log)); (e/'live-cancellation-results.json').write_text(json.dumps(results,indent=2))

import pathlib,subprocess,os,time,json,shlex,shutil,uuid
ROOT=pathlib.Path.cwd();E=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M43B8VZWC2WBFGKQFC7M11CS');LAB=E/'l'
log=[]; results=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','PI_CODING_AGENT','NO_MISTAKES_GATE'):env.pop(k,None)
def run(args,ok=True):
    p=subprocess.run([str(x) for x in args],cwd=ROOT,env=env,text=True,capture_output=True,timeout=45)
    log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n')
    if ok and p.returncode:raise RuntimeError(log[-1])
    return p
try:
    run(['bin/fm-lab-home.sh','create',LAB]);env['FM_HOME']=str(LAB)
    (LAB/'tmux').mkdir();env['TMUX_TMPDIR']=str(LAB/'tmux')
    (LAB/'config/supervision-host').write_text('claude sonnet\n')
    (LAB/'config/backlog-backend').write_text('manual\n')
    state=LAB/'state';(state/'.lock').write_text(str(os.getpid())+'\n');(state/'.lock-session').write_text('disposable-engine-evaluation\n')
    (LAB/'prompt.txt').write_text(run(['bin/fm-branch-prompt.sh']).stdout)
    scenarios=[
      ('echo-write','working: checking the release window','The release window is now confirmed closed. Register its new deliberate pause by appending paused: waiting for the registered release window to $FM_HOME/state/echo-write.status, under the task lease. This pause was not previously registered. No other action is needed.',False,'routine'),
    ]
    for task,line,context,silent,verdict in scenarios:
        wt=LAB/'projects'/task;wt.mkdir()
        (state/(task+'.meta')).write_text(f'kind={"scout" if task=="finished" else "ship"}\nworktree={wt}\nwindow=fixture\nbackend=tmux\nharness=claude\nproject=lab\n')
        # Initial pause or hold was durably presented before this notification.
        previous='working: checking the release window'
        (state/(task+'.status')).write_text(previous+'\n')
        run(['bin/fm-branch-outcome.sh','append','--task',task,'--verdict','captain' if task=='hold' else 'routine','--summary','Worker started checking the release window; no pause is registered yet.'])
        if task=='finished':
            (LAB/'data'/task).mkdir();(LAB/'data'/task/'report.md').write_text('The requested dependency investigation is complete. No unresolved decisions were found.\n')
        if task in ('changed','failure','finished'):
            with (state/(task+'.status')).open('a') as f:f.write(line+'\n')
        run(['bin/fm-busy-event.sh','arm',state,task,'--state','busy' if task=='changed' else 'idle','--source','fm-recovery','--event','scenario-fixture'])
    run(['bin/fm-branch-outcome.sh','mark-read','--through','1'])
    for task,line,context,silent,verdict in scenarios:
        run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check "$1" "$2"','_',task,f'check: {task}: {context}'])
    queue=(state/'.wake-queue').read_text();rows=[int(x.split('\t')[1]) for x in queue.splitlines()]
    turn='live-'+uuid.uuid4().hex[:12]
    run(['bin/fm-wake-grant.sh','activate',str(os.getpid()),turn]);run(['bin/fm-wake-grant.sh','publish',turn,*map(str,rows)])
    (state/'.supervision-host-turn').write_text('turn='+turn+'\nrows='+' '.join(map(str,rows))+'\nrow_tasks='+' '.join(f'{row}={sc[0]}' for row,sc in zip(rows,scenarios))+'\nposture=attended\nwake=check: isolated live silence scenarios\n')
    env.update(FM_SUPERVISION_ACTOR='branch',FM_BRANCH_REPORT_TURN=turn,FM_LEASE_HOLDER_PID=str(os.getpid()),FM_SUPERVISION_PRIMARY_HARNESS='claude',FM_CREW_STATE_NO_FORGE='1')
    message='Fleet notifications have arrived. Use bin/fm-branch-report.sh as the report surface, with --row from the drained queue, and follow your normal supervision contract. These are isolated local records; do not sign in, merge, dispatch, install tools, or touch any other home. Private data and state paths are rooted at $FM_HOME (the disposable home), not the source working directory. The fixture window is a live terminal representing each recorded waiting worker; native idle/busy records and task logs are available through bin/fm-crew-state.sh. Handle the presented notifications without editing source. For this first turn, register the newly confirmed deliberate pause for echo-write: under its task lease append paused: waiting for the registered release window to $FM_HOME/state/echo-write.status. This is an instruction from the supervisor running the lab, beyond the check text; it authorizes exactly that local pause registration.\n'
    (LAB/'wake.txt').write_text(message)
    # Real installed Claude, normal login, production headless-engine argument construction.
    cli=['claude','-p',message,'--safe-mode','--system-prompt-file',str(LAB/'prompt.txt'),'--tools','Bash,Read','--permission-mode','dontAsk','--allowedTools','Bash','Read','--model','sonnet','--output-format','json','--session-id',str(uuid.uuid4()),'--add-dir',str(LAB)]
    command='exec '+shlex.join(cli)+' > '+shlex.quote(str(LAB/'result.json'))+' 2> '+shlex.quote(str(LAB/'errors.log'))
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(LAB),command])
    run(['tmux','-L','fm-lab','set-option','-t','primary','remain-on-exit','on'])
    run(['tmux','-L','fm-lab','new-window','-t','primary','-n','fixture','-c',ROOT,'sleep 1800'])
    socket=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},#{session_id}']).stdout.strip();env['TMUX']=socket.replace(',$',',')
    # The CLI automatically inherits its private TMUX identity from its pane.
    for task,*_ in scenarios:run(['bin/fm-crew-state.sh',task])
    deadline=time.time()+360
    while time.time()<deadline:
        try:
            result=json.loads((LAB/'result.json').read_text())
            break
        except (json.JSONDecodeError,FileNotFoundError):time.sleep(1)
    else:raise RuntimeError('The real Claude engine did not finish within 360 seconds.')
    (E/'live-written-pause-result.json').write_text(json.dumps(result,indent=2)+'\n')
    (E/'live-written-pause-errors.log').write_text((LAB/'errors.log').read_text())
    store=(state/'branch-outcomes.jsonl').read_text();(E/'live-written-pause-outcomes.jsonl').write_text(store)
    (E/'live-written-pause-input.txt').write_text(message+'\nInitial delivered outcome: sequence 1.\nActual queued notifications:\n'+queue+'\n')
    outcomes=[json.loads(x) for x in store.splitlines() if json.loads(x)['seq']>1]
    for task,line,context,silent,verdict in scenarios:
        matching=[r for r in outcomes if r['task']==task]
        passed=len(matching)==1 and matching[0]['silent']==silent and (verdict is None or matching[0]['verdict']==verdict)
        results.append(dict(task=task,result='pass' if passed else 'fail',expected_silent=silent,expected_verdict=verdict,outcomes=matching))
    assert 'paused:' in (state/'echo-write.status').read_text(), 'Engine did not register the new pause'
    (E/'live-written-pause-written-status.txt').write_text((state/'echo-write.status').read_text())
    (E/'live-written-pause-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    # Feed the exact status the real branch just wrote back into the same conversation.
    run(['bin/fm-wake-grant.sh','release',turn])
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check echo-write "check: echo-write: This notification only echoes the pause record you just wrote. The task state and terms have not changed, and no further action is needed."'])
    row=(state/'.wake-queue').read_text().split('\t')[1]
    turn2='live-'+uuid.uuid4().hex[:12]
    run(['bin/fm-wake-grant.sh','activate',str(os.getpid()),turn2]);run(['bin/fm-wake-grant.sh','publish',turn2,row])
    (state/'.supervision-host-turn').write_text(f'turn={turn2}\nrows={row}\nrow_tasks={row}=echo-write\nposture=attended\nwake=check: echo of branch-written pause\n')
    env['FM_BRANCH_REPORT_TURN']=turn2
    message2='A notification arrived for the pause record you registered in the previous turn. Handle it under the same supervision contract; use bin/fm-branch-report.sh and --row from the drain. Private paths remain rooted at $FM_HOME.'
    cli2=cli.copy();cli2[2]=message2
    pos=cli2.index('--session-id');cli2[pos:pos+2]=['--resume',result['session_id']]
    command2='exec '+shlex.join(cli2)+' > '+shlex.quote(str(LAB/'followup.json'))+' 2> '+shlex.quote(str(LAB/'followup-errors.log'))
    run(['tmux','-L','fm-lab','new-session','-d','-s','followup','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(LAB),'-e','FM_BRANCH_REPORT_TURN='+turn2,command2])
    run(['tmux','-L','fm-lab','set-option','-t','followup','remain-on-exit','on'])
    deadline=time.time()+180
    while time.time()<deadline:
        try:followup=json.loads((LAB/'followup.json').read_text());break
        except (json.JSONDecodeError,FileNotFoundError):time.sleep(1)
    else:raise RuntimeError('Resumed engine did not finish within 180 seconds')
    (E/'live-written-pause-followup.json').write_text(json.dumps(followup,indent=2)+'\n')
    latest=json.loads((state/'branch-outcomes.jsonl').read_text().splitlines()[-1])
    assert latest['seq']==3 and latest['silent'] is True and latest['verdict']=='routine', latest
    results.append({'task':'echo-of-branch-written-pause','result':'pass','outcomes':[latest]})
    (E/'live-written-pause-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps({'engine_subtype':result.get('subtype'),'engine_error':result.get('is_error'),'scenarios':[{k:r[k] for k in ('task','result')} for r in results],'queue_after':(state/'.wake-queue').read_text(),'result':result.get('result')},indent=2))
finally:
    if (LAB/'tmux').exists():
        try:run(['tmux','-L','fm-lab','kill-server'],ok=False)
        except Exception:pass
    if LAB.exists():
        for name in ('result.json','errors.log'):
            if (LAB/name).exists() and not (E/('live-written-pause-'+name)).exists():shutil.copyfile(LAB/name,E/('live-written-pause-'+name))
        if (LAB/'state/branch-outcomes.jsonl').exists():shutil.copyfile(LAB/'state/branch-outcomes.jsonl',E/'live-written-pause-outcomes.jsonl')
        shutil.rmtree(LAB)
    (E/'live-written-pause-cli.log').write_text('\n'.join(log))

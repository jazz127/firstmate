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
      ('echo','paused: waiting for the registered release window','Pause was recorded and the wait instruction was already delivered by the supervision branch. This notification only echoes that same branch-owned record; no additional action is needed.',True,'routine'),
      ('scheduled','paused: waiting until the registered release window','This is the scheduled recheck of the already-registered pause. The release window has not arrived and the task state has not changed.',True,'routine'),
      ('declared','paused: waiting for the registered upstream dependency','This is a re-confirmation of the declared pause, which still holds on exactly the same terms. Nothing changed.',True,'routine'),
      ('hold','needs-decision [key=api-choice]: choose REST or RPC','The captain has not answered the existing API choice. The open decision was already presented and remains on the same terms. This is a re-confirmation, not a new decision.',True,'routine'),
      ('changed','working: release window opened; worker resumed','The previously registered pause cleared and the task changed state: the worker resumed. This is a new transition.',False,'routine'),
      ('failure','failed: dependency check now fails','The pause still exists, but a new dependency-check failure has occurred. The failure needs captain attention and must be reported.',False,'captain'),
      ('finished','done: requested investigation finished; report saved','The captain-requested investigation has now finished and its report is saved at data/finished/report.md. This is the requested result, not a periodic healthy check.',False,'captain'),
      ('uncertain','paused: waiting for the registered release window','The records still name the release window, but this event cannot establish whether its terms changed. There is no evidence sufficient to assert nothing new happened; use judgment.',False,None),
    ]
    for task,line,context,silent,verdict in scenarios:
        wt=LAB/'projects'/task;wt.mkdir()
        (state/(task+'.meta')).write_text(f'kind={"scout" if task=="finished" else "ship"}\nworktree={wt}\nwindow=fixture\nbackend=tmux\nharness=claude\nproject=lab\n')
        # Initial pause or hold was durably presented before this notification.
        previous='needs-decision [key=api-choice]: choose REST or RPC' if task=='hold' else 'paused: waiting for the registered release window'
        (state/(task+'.status')).write_text(previous+'\n')
        run(['bin/fm-branch-outcome.sh','append','--task',task,'--verdict','captain' if task=='hold' else 'routine','--summary','Existing hold was presented.' if task=='hold' else 'Registered pause and its instruction were already recorded by the supervision branch.'])
        if task=='finished':
            (LAB/'data'/task).mkdir();(LAB/'data'/task/'report.md').write_text('The requested dependency investigation is complete. No unresolved decisions were found.\n')
        if task in ('changed','failure','finished'):
            with (state/(task+'.status')).open('a') as f:f.write(line+'\n')
        run(['bin/fm-busy-event.sh','arm',state,task,'--state','busy' if task=='changed' else 'idle','--source','fm-recovery','--event','scenario-fixture'])
    run(['bin/fm-branch-outcome.sh','mark-read','--through','8']);run(['bin/fm-branch-outcome.sh','mark-processed','--through','4'])
    for task,line,context,silent,verdict in scenarios:
        run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check "$1" "$2"','_',task,f'check: {task}: {context}'])
    queue=(state/'.wake-queue').read_text();rows=[int(x.split('\t')[1]) for x in queue.splitlines()]
    turn='live-'+uuid.uuid4().hex[:12]
    run(['bin/fm-wake-grant.sh','activate',str(os.getpid()),turn]);run(['bin/fm-wake-grant.sh','publish',turn,*map(str,rows)])
    (state/'.supervision-host-turn').write_text('turn='+turn+'\nrows='+' '.join(map(str,rows))+'\nrow_tasks='+' '.join(f'{row}={sc[0]}' for row,sc in zip(rows,scenarios))+'\nposture=attended\nwake=check: isolated live silence scenarios\n')
    env.update(FM_SUPERVISION_ACTOR='branch',FM_BRANCH_REPORT_TURN=turn,FM_LEASE_HOLDER_PID=str(os.getpid()),FM_SUPERVISION_PRIMARY_HARNESS='claude',FM_CREW_STATE_NO_FORGE='1')
    message='Fleet notifications have arrived. Use bin/fm-branch-report.sh as the report surface, with --row from the drained queue, and follow your normal supervision contract. These are isolated local records; do not sign in, merge, dispatch, install tools, or touch any other home. Private paths are rooted at $FM_HOME. Verify each task through bin/fm-crew-state.sh before reporting. The fixture window is a live terminal representing each recorded waiting worker; native idle/busy records and task logs are available through bin/fm-crew-state.sh. Handle the presented notifications without editing source.\n'
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
    (E/'live-engine-result.json').write_text(json.dumps(result,indent=2)+'\n')
    (E/'live-engine-errors.log').write_text((LAB/'errors.log').read_text())
    store=(state/'branch-outcomes.jsonl').read_text();(E/'live-engine-outcomes.jsonl').write_text(store)
    (E/'live-engine-input.txt').write_text(message+'\nInitial delivered outcomes: sequences 1-8.\nActual queued notifications:\n'+queue+'\n')
    outcomes=[json.loads(x) for x in store.splitlines() if json.loads(x)['seq']>8]
    for task,line,context,silent,verdict in scenarios:
        matching=[r for r in outcomes if r['task']==task]
        passed=len(matching)==1 and matching[0]['silent']==silent and (verdict is None or matching[0]['verdict']==verdict)
        results.append(dict(task=task,result='pass' if passed else 'fail',expected_silent=silent,expected_verdict=verdict,outcomes=matching))
    (E/'live-engine-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps({'engine_subtype':result.get('subtype'),'engine_error':result.get('is_error'),'scenarios':[{k:r[k] for k in ('task','result')} for r in results],'queue_after':(state/'.wake-queue').read_text(),'result':result.get('result')},indent=2))
finally:
    if (LAB/'tmux').exists():
        try:run(['tmux','-L','fm-lab','kill-server'],ok=False)
        except Exception:pass
    if LAB.exists():
        for name in ('result.json','errors.log'):
            if (LAB/name).exists() and not (E/('live-engine-'+name)).exists():shutil.copyfile(LAB/name,E/('live-engine-'+name))
        if (LAB/'state/branch-outcomes.jsonl').exists():shutil.copyfile(LAB/'state/branch-outcomes.jsonl',E/'live-engine-outcomes.jsonl')
        shutil.rmtree(LAB)
    (E/'live-engine-cli.log').write_text('\n'.join(log))

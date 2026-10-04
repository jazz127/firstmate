import os, json, pathlib, subprocess, shutil, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M43B8VZWC2WBFGKQFC7M11CS')
LAB=E/'l'
log=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','PI_CODING_AGENT'): env.pop(k,None)
def run(args, e=None, ok=True):
    p=subprocess.run([str(x) for x in args],cwd=ROOT,env=e or env,text=True,capture_output=True,timeout=40)
    log.append('$ '+ ' '.join(str(x) for x in args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n')
    if ok and p.returncode: raise RuntimeError(log[-1])
    return p
try:
    run(['bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir()
    env['TMUX_TMPDIR']=str(LAB/'tmux')
    run(['tmux','-L','fm-lab','new-session','-d','-s','fixture','-x','120','-y','40','-c',ROOT,'sleep 1800'])
    socket=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},#{session_id}']).stdout.strip()
    env['TMUX']=socket.replace(',$',',')
    results=[]
    for mode in ['current','legacy-drain','legacy-silent-append','legacy-visible-append','missing','invalid','symlink']:
        h=LAB/mode
        run(['bin/fm-lab-home.sh','create',h])
        (h/'config/supervision-host-off').touch()
        e=env|{'FM_HOME':str(h)}
        state=h/'state'; store=state/'branch-outcomes.jsonl'; ready=state/'.branch-outcome-index-ready'
        def status(task,line,append=False):
            with (state/(task+'.status')).open('a' if append else 'w') as f:f.write(line+'\n')
        def outcome(task,verdict,summary,silent=False,ok=True):
            return run(['bin/fm-branch-outcome.sh','append','--task',task,'--verdict',verdict,'--summary',summary,'--silent',str(silent).lower()],e,ok)
        status('visible','done: completion already delivered')
        outcome('visible','captain','Completion already delivered.')
        status('mixed','done: earlier completion delivered')
        outcome('mixed','captain','Earlier completion delivered.')
        visible_index=(state/'.mixed.branch-outcome-index').read_bytes()
        status('mixed','failed: later failure has no visible outcome',True)
        status('silent-done','done: completion has only a silent echo')
        status('silent-failed','failed: failure has only a silent echo')
        for task in ['mixed','silent-done','silent-failed']:outcome(task,'routine','Unchanged status echo.',True)
        assert (state/'.mixed.branch-outcome-index').read_bytes()==visible_index
        assert not (state/'.silent-done.branch-outcome-index').exists()
        assert not (state/'.silent-failed.branch-outcome-index').exists()
        history=store.read_bytes()
        run(['bin/fm-branch-outcome.sh','mark-read','--through','5'],e)
        if mode!='current':
            rows=[json.loads(x) for x in history.splitlines()]
            for task in ['visible','mixed','silent-done','silent-failed']:
                row=[r for r in rows if r['task']==task][-1]
                (state/('.'+task+'.branch-outcome-index')).write_text(f"fm-branch-outcome-index-v1\t{row['seq']}\t{row['statusEndpoint']}\t{row['statusIdent']}\n")
            ready.unlink()
            if mode.startswith('legacy'):ready.write_text('5\n')
            elif mode=='invalid':ready.write_text('visible-only-v1:9007199254740992\n')
            elif mode=='symlink':
                (state/'untrusted-ready').write_text('visible-only-v1:5\n');ready.symlink_to(state/'untrusted-ready')
        if mode=='legacy-silent-append':outcome('fleet','routine','Fleet unchanged.',True)
        if mode=='legacy-visible-append':outcome('fleet','routine','Unrelated real result.')
        first=run(['bin/fm-wake-drain.sh'],e).stdout
        for line in ['silent-done done: completion has only a silent echo','silent-failed failed: failure has only a silent echo','mixed failed: later failure has no visible outcome']:assert line in first,(mode,first)
        assert 'visible done:' not in first
        assert 'STATUS OUTCOME BACKSTOP SKIPPED' not in first
        second=run(['bin/fm-wake-drain.sh'],e).stdout
        assert 'STATUS OUTCOME BACKSTOP (' not in second,(mode,second)
        assert store.read_bytes().startswith(history)
        assert not (state/'.silent-done.branch-outcome-index').exists()
        assert (state/'.mixed.branch-outcome-index').read_bytes()==visible_index
        seq=6 if mode in ['legacy-silent-append','legacy-visible-append'] else 5
        assert ready.read_text().strip()==f'visible-only-v1:{seq}'
        results.append({'mode':mode,'first_drain':first,'second_drain':second,'ready':ready.read_text().strip(),'coverage_after_silent':'mixed retained visible seq 2; silent-only indexes absent','history_preserved':True})
    # Replay contract and adversarial refusal.
    h=LAB/'replay';run(['bin/fm-lab-home.sh','create',h]);e=env|{'FM_HOME':str(h)}
    state=h/'state';(state/'repeat.status').write_text('paused: waiting for a registered release window\n')
    def app(task,verdict,summary,silent):return run(['bin/fm-branch-outcome.sh','append','--task',task,'--verdict',verdict,'--summary',summary,'--silent',str(silent).lower()],e)
    app('repeat','routine','Registered pause still holds.',True)
    app('recovered','routine','Pause cleared; work resumed.',False)
    replay=run(['bin/fm-branch-outcome.sh','startup-replay'],e).stdout
    assert 'Registered pause still holds.' not in replay and 'Pause cleared; work resumed.' in replay
    app('requested','captain','Requested work finished.',False)
    before=(state/'branch-outcomes.jsonl').read_bytes()
    rejected=run(['bin/fm-branch-outcome.sh','append','--task','requested','--verdict','captain','--summary','Never hide a captain result.','--silent','true'],e,False)
    assert rejected.returncode!=0 and (state/'branch-outcomes.jsonl').read_bytes()==before
    barrier=run(['bin/fm-branch-outcome.sh','startup-replay'],e).stdout
    unread=run(['bin/fm-branch-outcome.sh','unread'],e).stdout
    assert not barrier.strip() and 'Requested work finished.' in unread
    results.append({'mode':'replay-and-captain-guard','startup_replay':replay,'captain_refusal':rejected.stderr,'pending_captain_row':unread,'cursor':(state/'.branch-outcomes-cursor').read_text().strip()})
    (E/'live-outcome-state.json').write_text(json.dumps(results,indent=2)+'\n')
    print('Direct product scenarios passed; recovery output and persisted-state evidence captured.')
finally:
    if (LAB/'tmux').exists():
        try:run(['tmux','-L','fm-lab','kill-server'],ok=False)
        except Exception:pass
    if LAB.exists():shutil.rmtree(LAB)
    (E/'live-outcome-cli.log').write_text('\n'.join(log))

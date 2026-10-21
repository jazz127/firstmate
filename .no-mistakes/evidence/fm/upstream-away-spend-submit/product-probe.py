import os, subprocess, pathlib, tempfile, shutil, json, time, shlex, sys
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path(sys.argv[1])
TEMP=ROOT/'.test-phase-tmp'
LAB=pathlib.Path(tempfile.mkdtemp(prefix='product-',dir=TEMP))
log=(EVIDENCE/'product-evidence.log').open('a')
def clean(s):
    return str(s).replace(str(ROOT),'<WORKTREE>').replace(str(LAB),'<LAB>').replace(str(pathlib.Path.home()),'<HOME>')
def note(s):
    log.write(clean(s)+'\n'); log.flush()
def run(args, env=None, expected=0, timeout=45, cwd=ROOT, show=True):
    note('$ '+shlex.join(map(str,args)))
    start=time.monotonic()
    p=subprocess.run(list(map(str,args)),env=env or BASE,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    if show: note(p.stdout.rstrip())
    note(f'exit={p.returncode} elapsed={time.monotonic()-start:.2f}s')
    if expected is not None: assert p.returncode==expected, p.stdout
    return p
BASE=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM']:
    BASE.pop(k,None)
BASE.update(TMPDIR=str(TEMP),FM_HOME=str(LAB/'absent'),FM_CREW_STATE_NO_FORGE='1',NM_HOME=str(LAB/'unused-nm-home'),DISABLE_AUTOUPDATER='1')
socket=None
try:
    note('Fresh attempt: private TMUX is propagated; held-declaration oracle requires it to be the latest event (fm-classify-lib.sh public wait contract). Earlier failed attempts were lab setup/oracle issues and cleaned up.')
    note('SCENARIO: missing-home readers preserve absent state')
    run(['bin/fm-pr-merge.sh','task-probe','https://github.com/example/unused/pull/1'],expected=1)
    assert not (LAB/'absent').exists()
    p=run(['bin/fm-fleet-snapshot.sh','--json'],show=False)
    snap=json.loads(p.stdout)
    note(json.dumps({'schema':snap['schema'],'roots':snap['roots'],'tasks':snap['tasks'],'backlog_present':snap['backlog']['present']}))
    assert not (LAB/'absent').exists()
    run(['bin/fm-afk-contract.sh','live-workers'])
    assert not (LAB/'absent').exists()
    note('PASS: merge refused missing state; snapshot and empty count left the home absent')
    note('SCENARIO: sourced event fold preserves a caller scalar and recognizes unresolved event')
    code='set -eu; lines=17; . "$1/bin/fm-afk-contract.sh"; verb=$(printf "needs-decision [key=a]: wait\\n  continuation\\nresolved [key=b]: answered\\n" | fm_afk_contract_latest_non_resolved_verb); test "$lines" = 17; test "$verb" = needs-decision; printf "caller lines=%s; latest verb=%s\\n" "$lines" "$verb"'
    run(['bash','-c',code,'_',ROOT])
    # Reproduce the state side effect before the last fix, using a disposable
    # executable copy with unchanged dependencies rather than editing source.
    before=LAB/'before'; (before/'bin').mkdir(parents=True)
    for source in (ROOT/'bin').iterdir(): (before/'bin'/source.name).symlink_to(source)
    old=before/'bin/fm-afk-contract.sh'; old.unlink()
    old.write_text(subprocess.check_output(['git','show','6312f25e:bin/fm-afk-contract.sh'],text=True)); old.chmod(0o755)
    env=BASE|{'FM_HOME':str(LAB/'before-home')}
    run([before/'bin/fm-afk-contract.sh','live-workers'],env=env)
    assert (LAB/'before-home/state').is_dir()
    note('BEFORE/AFTER: pre-fix live-workers created state; target returned 0 without creating the home')
    for entry,arguments in [('fm-pr-merge.sh',['task-probe','https://github.com/example/unused/pull/1']),('fm-fleet-snapshot.sh',['--json'])]:
        env_before=BASE|{'FM_HOME':str(LAB/('before-'+entry))}
        previous=run([before/'bin'/entry,*arguments],env=env_before,expected=None,show=entry!='fm-fleet-snapshot.sh')
        assert (pathlib.Path(env_before['FM_HOME'])/'state').is_dir()
        note('BEFORE/AFTER: '+entry+' created missing state with the pre-fix contract; target did not')
    home=LAB/'home'
    run(['bin/fm-lab-home.sh','create',home])
    socket=run(['bin/fm-lab-home.sh','tmux-dir',home]).stdout.strip()
    env=BASE|{'FM_HOME':str(home),'TMUX_TMPDIR':socket,'SHELL':'/bin/bash','TREEHOUSE_ROOT':str(LAB/'pool')}
    def tmux(*args,**kw): return run(['tmux','-L','fm-lab',*args],env=env,**kw)
    tmux('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','35','-c',ROOT,'bash --noprofile --norc')
    env['TMUX']=tmux('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
    project=LAB/'project'
    run(['git','init','-q','-b','main',project])
    run(['git','-C',project,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','seed'])
    def count(want):
        p=run(['bin/fm-afk-contract.sh','live-workers'],env=env|{'FM_SPAWN_CAP_LAUNCH_GRACE':'0'})
        if p.stdout.strip()!=str(want):
            run(['bin/fm-crew-state.sh','task'],env=env,expected=None)
            run(['bash','-c','. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; fm_busy_classify_meta "$2/state/task.meta" task "$2/state"','_',ROOT,home],env=env,expected=None)
        assert p.stdout.strip()==str(want), (want,p.stdout)
    def meta(**fields):
        (home/'state/task.meta').write_text(''.join(f'{k}={v}\n' for k,v in fields.items()))
    def event(state): run(['bin/fm-busy-event.sh','apply',home/'state','task',state,'--current-gen','--source','claude-hook','--event','stop' if state=='idle' else 'user-prompt-submit'],env=env)
    note('SCENARIO: active raw worker counts; proven idle waits free capacity; resumed or uncertain activity retains it')
    tmux('new-window','-d','-t','primary:','-n','worker','-c',ROOT,'sleep 300')
    meta(kind='scout',backend='tmux',window='primary:worker',harness='claude',worktree=str(project),project=str(project))
    (home/'state/task.status').write_text('working: running\n')
    count(1)
    run(['bin/fm-busy-event.sh','arm',home/'state','task','--state','idle','--source','claude-hook','--event','stop'],env=env)
    for verb in ['paused','needs-decision','captain-held']:
        note('waiting verb='+verb)
        suffix='' if verb=='captain-held' else 'resolved [key=b]: unrelated answer\n'
        (home/'state/task.status').write_text(f'{verb} [key=a]: waiting\n'+suffix)
        event('idle'); count(0)
        event('busy'); count(1)
        event('unknown'); count(1)
    event('idle')
    (home/'state/task.status').write_text('needs-decision [key=a]: waiting\nworking: resumed\nresolved [key=b]: unrelated answer\n')
    count(1)
    note('PASS: all three waits require proven idle and a current waiting event')
    note('SCENARIO: accepted local-only ship and scout deliveries free capacity only with proven idle activity')
    clone=LAB/'accepted-project'
    run(['git','clone','-q',project,clone])
    for kind in ['ship','scout']:
        meta(kind=kind,backend='tmux',window='primary:worker',harness='claude',worktree=str(project),project=str(clone),mode='local-only')
        (home/'state/task.status').write_text('done: ready for review\n')
        event('idle'); count(0)
        event('busy'); count(1)
        event('unknown'); count(1)
    meta(kind='scout',backend='tmux',window='primary:worker',harness='claude',worktree=str(project),project=str(project))
    (home/'state/task.status').write_text('working: resumed\n')
    note('PASS: actual local Git reachability and idle activity allow delivery exclusion; busy/unknown retains capacity')
    note('SCENARIO: away cap rejects fresh work and return brief uses the same count')
    run(['bin/fm-afk-contract.sh','enter','--spend','1','--words','Run no new work above one worker.'],env=env)
    p=run(['bin/fm-spawn.sh','blocked-fresh',LAB/'absent-project','--mode','no-mistakes','--yolo','off'],env=env,expected=1)
    assert 'caps concurrent workers at 1' in p.stdout
    assert not (home/'state/blocked-fresh.meta').exists()
    p=run(['bin/fm-afk-return.sh','begin'],env=env,expected=None)
    assert p.returncode in [0,1,4],p.stdout
    assert '1 task(s) live at return.' in p.stdout
    note('PASS: count=1 blocks fresh admission before project/endpoint creation and return reports one live task')
    note('SCENARIO: renamed worker survives an unacknowledged close and keeps its reservation')
    (home/'state/task.status').write_text('working: still running\n')
    tmux('rename-window','-t','primary:worker','relocated')
    run(['bash','-c','. "$1/bin/fm-backend.sh"; fm_backend_kill_confirmed tmux primary:worker','_',ROOT],env=env,expected=1)
    tmux('display-message','-p','-t','primary:relocated','#{pane_current_command}')
    with (home/'state/task.meta').open('a') as f: f.write('cleanup_recovery=launch\n')
    count(1)
    tmux('kill-window','-t','primary:relocated')
    # Missing old identity cannot prove death; keep reservation conservatively.
    count(1)
    note('PASS: missing recorded name is not a close acknowledgement or proof of death')
    note('SCENARIO: positively exited worker frees capacity; unknown backend reserves capacity; secondmates are exempt')
    tmux('new-window','-d','-t','primary:','-n','exited','bash --noprofile --norc')
    meta(kind='ship',backend='tmux',window='primary:exited',harness='codex')
    count(0)
    meta(kind='ship',backend='unverified-backend',window='recorded-target',harness='codex')
    count(1)
    meta(kind='secondmate',backend='unverified-backend',window='recorded-target',harness='codex')
    count(0)
    note('PASS: positive shell endpoint frees room, unknown backend counts, secondmate does not count')
    note('SCENARIO: recent launch and live metadata lock reserve capacity')
    meta(kind='ship',backend='tmux',window='primary:exited',harness='codex',spawn_gen=f's{int(time.time())}.1')
    run(['bin/fm-afk-contract.sh','live-workers'],env=env)
    assert run(['bin/fm-afk-contract.sh','live-workers'],env=env).stdout.strip()=='1'
    count(0)
    note('PASS: fresh generation reserves a proven-shell slot until the launch-grace boundary')
    holder_code='. "$1/bin/fm-wake-lib.sh"; lock=$(fm_meta_lock_path "$2/state/task.meta"); fm_lock_acquire_wait "$lock"; touch "$2/lock-ready"; while [ ! -e "$2/lock-release" ]; do sleep 0.05; done; fm_lock_release "$lock"'
    holder=subprocess.Popen(['bash','-c',holder_code,'_',str(ROOT),str(home)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    try:
        limit=time.monotonic()+10
        while not (home/'lock-ready').exists() and time.monotonic()<limit: time.sleep(0.05)
        assert (home/'lock-ready').exists()
        count(1)
    finally:
        (home/'lock-release').touch()
        output,_=holder.communicate(timeout=10)
        note('metadata lock holder exit='+str(holder.returncode)+' '+output)
        assert holder.returncode==0
    count(0)
    note('PASS: a live metadata lock reserves capacity and releasing it restores the proven-dead count')
    note('SCENARIO: relaunch, secondmate and quiet admission keep their own checks instead of applying the away fresh-worker cap')
    meta(kind='ship',backend='unverified-backend',window='recorded-target',harness='codex')
    run(['bin/fm-afk-contract.sh','enter','--spend','1','--words','Keep the isolated cap at one.'],env=env)
    p=run(['bin/fm-spawn.sh','absent','--relaunch'],env=env,expected=1)
    assert 'needs an existing task record' in p.stdout and 'caps concurrent workers' not in p.stdout
    p=run(['bin/fm-spawn.sh','mate',LAB/'absent-mate','--secondmate'],env=env,expected=None)
    assert p.returncode!=0 and 'caps concurrent workers' not in p.stdout
    run(['bin/fm-afk-contract.sh','archive'],env=env)
    run(['bin/fm-afk-contract.sh','enter','--spend','1','--words','Remain quietly present.'],env=env|{'FM_AFK_MODE':'quiet'})
    p=run(['bin/fm-spawn.sh','quiet-fresh',LAB/'absent-project','--mode','no-mistakes','--yolo','off'],env=env,expected=None)
    assert p.returncode!=0 and 'caps concurrent workers' not in p.stdout
    note('PASS: exempt calls reached their own missing-record/home/project checks without away-cap refusal')
    note('COMPLETE: all executed product checks passed')
finally:
    if socket:
        subprocess.run(['tmux','-L','fm-lab','kill-server'],env=BASE|{'TMUX_TMPDIR':socket},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        p=subprocess.run(['bin/fm-lab-home.sh','teardown',LAB/'home'],env=BASE,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        note('private tmux teardown exit='+str(p.returncode)+' '+p.stdout)
        assert p.returncode==0
    shutil.rmtree(LAB)
    note('Disposable lab removed; no product children remain')
    log.close()

import os, pathlib, subprocess, time, shutil, json

ROOT = pathlib.Path('/Users/jarad/.no-mistakes/worktrees/a00b7db52042/01M41455GSYFXNEE083YS370GC')
EVIDENCE = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M41455GSYFXNEE083YS370GC')
LAB = ROOT / '.l'
env = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE')) and k not in ('TMUX','TMUX_PANE','FM_GATE_REFUSE_BYPASS')}
env.update(FM_HOME=str(LAB), NM_HOME=str(LAB/'nm'), TMUX_TMPDIR=str(LAB/'t'),
           TREEHOUSE_ROOT=str(LAB/'pool'), SHELL=shutil.which('bash'),
           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid',
           GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid',
           FM_BACKEND='tmux', FM_SPAWN_NO_GUARD='1', FM_SUPERVISION_ACTOR='main',
           FM_CREW_STATE_NO_FORGE='1')
results = []
log = open(EVIDENCE/'live-spend-transcript.log', 'w', buffering=1)
pending = None

def say(text):
    print(text, flush=True); log.write(text+'\n')

def run(args, expected=0, timeout=90, local_env=None):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=local_env or env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    say('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout.rstrip()+'\nexit='+str(p.returncode))
    if expected is not None:
        assert p.returncode == expected, p.stdout
    return p

def tm(*args, expected=0):
    return run(['tmux','-L','fm-lab',*args],expected)

def product(name,*args,expected=0):
    return run([ROOT/'bin'/name,*args],expected)

def count(want):
    p=product('fm-afk-spend-count.sh',LAB/'state')
    assert p.stdout.strip()==str(want),p.stdout

def refuse():
    p=product('fm-spawn.sh','lab-next',LAB/'p','sleep 600','--scout',expected=1)
    assert 'caps concurrent workers at 1' in p.stdout,p.stdout

def cost(want):
    p=product('fm-afk-return.sh','check',expected=None)
    assert p.returncode in (0,3),p.stdout
    assert str(want)+' task(s) live at return.' in p.stdout,p.stdout
    if not (LAB/'state/.afk-contract').exists():
        product('fm-afk-contract.sh','enter','--spend','1')

def outcome(name, fn):
    say('\nSCENARIO: '+name)
    try:
        fn(); results.append(dict(name=name,result='pass',live=True))
        say('OBSERVED: PASS '+name)
    except Exception as e:
        results.append(dict(name=name,result='fail',live=True,reason=str(e)))
        say('OBSERVED: FAIL '+name+' '+str(e)); raise

def meta(id, **values):
    (LAB/'state'/f'{id}.meta').write_text(''.join(k+'='+str(v)+'\n' for k,v in values.items()))

def status(text):
    (LAB/'state'/'lab-raw.status').write_text(text+'\n')

def busy(state):
    product('fm-busy-event.sh','arm',LAB/'state','lab-raw','--state',state,'--source','claude-hook','--event','stop' if state=='idle' else 'user-prompt-submit')

def backend_state(target):
    return run(['bash','-c','. "$1"; fm_backend_worker_state tmux "$2"','_',ROOT/'bin/fm-backend.sh',target]).stdout.strip()

try:
    assert not LAB.exists(), 'lab path already exists'
    product('fm-lab-home.sh','create',LAB)
    (LAB/'t').mkdir()
    (LAB/'config'/'backlog-backend').write_text('manual\n')
    (LAB/'config'/'crew-harness').write_text('codex\n')
    (LAB/'state'/'.last-watcher-beat').touch()
    run(['git','init','-q','-b','main',LAB/'p'])
    run(['git','-C',LAB/'p','commit','-q','--allow-empty','-m','initial'])
    run(['git','clone','--bare','-q',LAB/'p',LAB/'origin.git'])
    run(['git','-C',LAB/'p','remote','add','origin',LAB/'origin.git'])
    run(['git','-C',LAB/'p','fetch','-q','origin'])
    (LAB/'data'/'lab-raw').mkdir()
    (LAB/'data'/'lab-raw'/'brief.md').write_text('# Task\n## Captain\'s intent\nExercise a disposable raw worker.\n\n## Firstmate spec\nWait for explicit test cleanup.\n')
    (LAB/'data'/'lab-next').mkdir()
    (LAB/'data'/'lab-next'/'brief.md').write_text('# Task\n## Captain\'s intent\nCheck fresh admission.\n\n## Firstmate spec\nExercise the cap.\n')
    tm('new-session','-d','-s','fm-lab-spend','-x','120','-y','40','-c',ROOT,
       'bash --noprofile --norc')
    tm('set-option','-g','default-command','bash --noprofile --norc')
    socket=tm('display-message','-p','-t','fm-lab-spend','#{socket_path},#{pid},0').stdout.strip()
    env['TMUX']=socket
    product('fm-afk-contract.sh','enter','--spend','1')

    def launch_raw():
        product('fm-spawn.sh','lab-raw',LAB/'p','sleep 600','--scout')
        status('working: raw launch active')
        count(1); refuse(); cost(1)
        p=product('fm-spawn.sh','absent','--relaunch',expected=1)
        assert 'needs an existing task record' in p.stdout and 'caps concurrent workers' not in p.stdout
        p=product('fm-spawn.sh','mate',LAB/'missing-home','--secondmate',expected=None)
        assert p.returncode!=0 and 'caps concurrent workers' not in p.stdout
    outcome('Supported raw command launches on real tmux, counts and prevents a fresh worker at cap=1',launch_raw)

    def death():
        tm('send-keys','-t','fm-lab-spend:fm-lab-raw','C-c')
        time.sleep(.5)
        assert backend_state('fm-lab-spend:fm-lab-raw')=='dead'
        count(0); cost(0)
        p=product('fm-spawn.sh','lab-admit',LAB/'missing-project','sleep 600','--scout',expected=1)
        assert 'caps concurrent workers' not in p.stdout,p.stdout
        tm('send-keys','-t','fm-lab-spend:fm-lab-raw','sleep 600','Enter')
        time.sleep(.5); count(1)
    outcome('A positively exited raw worker frees capacity without deleting its task record',death)

    def deliveries():
        (LAB/'config/supervision-host').touch()
        tm('new-session','-d','-s','primary','-n','cli','-x','120','-y','40','-c',ROOT,
           'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE claude')
        time.sleep(3)
        tm('capture-pane','-p','-t','primary:cli')
        assert backend_state('primary:cli')=='alive'
        values={line.split('=',1)[0]:line.split('=',1)[1] for line in (LAB/'state/lab-raw.meta').read_text().splitlines() if '=' in line}
        wt=values['worktree']; values['kind']='ship'; values['mode']='no-mistakes'
        values['harness']='claude'; values['window']='primary:cli'
        meta('lab-raw',**values)
        busy('idle'); status('done: implementation complete'); count(1); refuse(); cost(1)
        run(['git','-C',wt,'commit','-q','--allow-empty','-m','unpublished change'])
        head=run(['git','-C',wt,'rev-parse','HEAD']).stdout.strip()
        status('done: PR https://example.invalid/lab/repo/pull/1 checks green')
        count(1)
        run(['git','-C',wt,'update-ref','refs/remotes/origin/worker',head])
        busy('idle'); count(0); cost(0)
        busy('busy'); count(1); refuse(); cost(1)
        busy('idle')
        for mode in ('direct-PR','local-only'):
            values['mode']=mode; meta('lab-raw',**values); status('done: ready for review')
            count(0); busy('busy'); count(1); busy('idle')
        values['kind']='scout'; meta('lab-raw',**values); status('done: report complete')
        count(0); busy('busy'); count(1); busy('idle')
        status('working: continuing'); count(1)
        values['harness']='sleep'; values['window']='fm-lab-spend:fm-lab-raw'; meta('lab-raw',**values)
    outcome('Pre-validation and unpublished claims count; accepted terminal deliveries free room; a busy turn counts again',deliveries)

    def absence():
        tm('rename-session','-t','fm-lab-spend','fm-lab-renamed')
        assert backend_state('fm-lab-spend:fm-lab-raw')=='missing'
        count(1); refuse(); cost(1)
        tm('new-session','-d','-s','fm-lab-moved','-x','120','-y','40','bash --noprofile --norc')
        tm('move-window','-s','fm-lab-renamed:fm-lab-raw','-t','fm-lab-moved:')
        count(1); refuse(); cost(1)
        tm('new-session','-d','-s','fm-lab-foreign','-x','120','-y','40','bash --noprofile --norc')
        foreign=dict(env); foreign['TMUX']=str(LAB/'t/tmux-501/unreachable')+',1,0'
        p=run([ROOT/'bin/fm-afk-spend-count.sh',LAB/'state'],local_env=foreign)
        assert p.stdout.strip()=='1'
        p=run(['bash','-c','. "$1"; fm_backend_kill_confirmed tmux "$2"','_',ROOT/'bin/fm-backend.sh','fm-lab-spend:fm-lab-raw'],expected=1)
        run(['bash','-c','. "$1"; fm_backend_kill tmux "$2"','_',ROOT/'.baseline/bin/fm-backend.sh','fm-lab-spend:fm-lab-raw'],expected=0)
        tm('capture-pane','-p','-t','fm-lab-moved:fm-lab-raw')
        values={line.split('=',1)[0]:line.split('=',1)[1] for line in (LAB/'state/lab-raw.meta').read_text().splitlines() if '=' in line}
        values['window']='fm-lab-moved:fm-lab-raw'; meta('lab-raw',**values)
        tm('send-keys','-t','fm-lab-moved:fm-lab-raw','C-c'); time.sleep(.5)
        count(0)
    outcome('Rename and moved windows do not prove death; confirmed closure refuses the stale target',absence)

    def missing_backends():
        for backend in ('orca','zellij','cmux'):
            meta('unreadable',kind='ship',backend=backend,window='recorded-unreachable')
            count(1); refuse(); cost(1)
            (LAB/'state/unreadable.meta').unlink()
        meta('mate',kind='secondmate',backend='tmux',window='missing:worker')
        count(0); (LAB/'state/mate.meta').unlink()
    outcome('Unavailable experimental backends retain capacity and secondmates remain excluded',missing_backends)

    def pending_cancel():
        global pending
        (LAB/'state/lab-raw.meta').unlink()
        (LAB/'state/lab-raw.status').unlink()
        (LAB/'data/lab-pending').mkdir()
        (LAB/'data/lab-pending/brief.md').write_text('# Task\n## Captain\'s intent\nWait in a disposable launch.\n\n## Firstmate spec\nExercise launch reservation and cancellation.\n')
        tm('rename-session','-t','fm-lab-renamed','fm-lab-pending')
        command="printf 'LAB_PENDING_READY\\n'; while [ ! -e "+str(LAB/'release')+' ]; do read -t 0.1 -r ignored || :; done; sleep 600'
        f=open(EVIDENCE/'pending-launch.log','w')
        pending=subprocess.Popen([str(ROOT/'bin/fm-spawn.sh'),'lab-pending',str(LAB/'p'),command,'--scout'],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        deadline=time.time()+80
        target=None
        while time.time()<deadline:
            if pending.poll() is not None: raise AssertionError('pending spawn stopped: '+(EVIDENCE/'pending-launch.log').read_text())
            record=LAB/'state/lab-pending.meta'
            if record.exists():
                fields=dict(line.split('=',1) for line in record.read_text().splitlines() if '=' in line)
                target=fields['window']
                capture=subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-t',target],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT).stdout
                if 'LAB_PENDING_READY' in capture: break
            time.sleep(.2)
        else: raise AssertionError('pending launch was not submitted')
        count(1); refuse(); cost(1)
        tm('capture-pane','-p','-t',target)
        tm('rename-session','-t',target.split(':',1)[0],'fm-lab-surviving')
        (LAB/'release').touch(); time.sleep(.5)
        assert backend_state('fm-lab-surviving:fm-lab-pending')=='ambiguous'
        pending.terminate()
        rc=pending.wait(timeout=20); pending=None; f.close()
        say('Cancellation exit='+str(rc)+'\n'+(EVIDENCE/'pending-launch.log').read_text())
        assert rc!=0
        record=LAB/'state/lab-pending.meta'
        assert record.exists() and 'cleanup_recovery=launch' in record.read_text(), record.read_text() if record.exists() else 'record lost'
        say('Persisted cancellation contract:\n'+record.read_text())
        assert not (LAB/'state/.meta-lab-pending.lock').exists()
        count(1); refuse(); cost(1)
        assert backend_state('fm-lab-surviving:fm-lab-pending')=='ambiguous'
    outcome('Delayed fresh launch reserves capacity; renaming before cancellation retains surviving endpoint and cleanup capacity',pending_cancel)
finally:
    if pending is not None:
        pending.terminate()
        try: pending.wait(timeout=20)
        except subprocess.TimeoutExpired: pending.kill(); pending.wait()
    tm('kill-server',expected=None)
    if LAB.exists():
        for path, dirs, files in os.walk(LAB):
            os.chmod(path, 0o700)
        shutil.rmtree(LAB)
    (EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    say('CLEANUP: private tmux server stopped and disposable worktree lab removed')
    log.close()

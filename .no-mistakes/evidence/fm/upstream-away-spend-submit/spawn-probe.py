import pathlib, subprocess, os, tempfile, shutil, shlex, time, sys, signal
ROOT=pathlib.Path.cwd(); OUT=pathlib.Path(sys.argv[1]); LAB=pathlib.Path(tempfile.mkdtemp(prefix='spawn-',dir=ROOT/'.test-phase-tmp'))
log=(OUT/'spawn-evidence.log').open('a'); socket=None; child=None
BASE=os.environ.copy()
for key in ['TMUX','TMUX_PANE','FM_ROOT_OVERRIDE','FM_DATA_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TEST_SEAM']:
    BASE.pop(key,None)
BASE.update(FM_HOME=str(LAB/'home'),HOME=str(LAB/'user'),TMPDIR=str(ROOT/'.test-phase-tmp'),TREEHOUSE_ROOT=str(LAB/'pool'),SHELL='/bin/bash',FM_BACKEND='tmux',FM_SUPERVISION_ACTOR='main',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
(LAB/'user').mkdir()
def note(s):
    log.write(str(s).replace(str(ROOT),'<WORKTREE>').replace(str(LAB),'<LAB>').replace(str(pathlib.Path.home()),'<HOME>')+'\n'); log.flush()
def run(args,expected=0,timeout=90,cwd=ROOT,env=None):
    note('$ '+shlex.join(map(str,args)))
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=env or BASE,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    note(p.stdout.rstrip()); note('exit='+str(p.returncode))
    if expected is not None: assert p.returncode==expected,p.stdout
    return p
try:
    run(['bin/fm-lab-home.sh','create',LAB/'home'])
    socket=run(['bin/fm-lab-home.sh','tmux-dir',LAB/'home']).stdout.strip(); BASE['TMUX_TMPDIR']=socket
    def tmux(*args,**kw): return run(['tmux','-L','fm-lab',*args],**kw)
    tmux('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','35','-c',ROOT,'bash --noprofile --norc')
    BASE['TMUX']=tmux('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
    tmux('set-option','-g','default-shell','/bin/bash'); tmux('set-option','-g','default-command','bash --noprofile --norc')
    home=LAB/'home'; project=LAB/'project'
    (home/'config/backlog-backend').write_text('manual\n')
    run(['git','init','-q','-b','main',project])
    run(['git','-C',project,'config','user.name','Test']); run(['git','-C',project,'config','user.email','test@example.invalid'])
    (project/'sample.txt').write_text('disposable product probe\n')
    run(['git','-C',project,'add','sample.txt']); run(['git','-C',project,'commit','-qm','seed'])
    run(['git','clone','-q','--bare',project,LAB/'origin.git'])
    run(['git','-C',project,'remote','add','origin',LAB/'origin.git']); run(['git','-C',project,'fetch','-q','origin']); run(['git','-C',project,'remote','set-head','origin','main'])
    run(['bin/fm-afk-contract.sh','enter','--spend','1','--words','Validate the isolated raw worker.'])
    task='labraw'+str(os.getpid())
    run(['bin/fm-brief.sh',task,'project','--scout'])
    brief=home/'data'/task/'brief.md'
    text=brief.read_text().replace('{TASK}','Wait for the disposable scenario to finish.').replace('{FIRSTMATE_SPEC}','Use only the lab; do not publish anything.')
    brief.write_text(text)
    payload='padding='+'x'*5000+'; printf "%s\\n" "${#padding}" > '+shlex.quote(str(home/'raw-started'))+'; sleep 120'
    note('SCENARIO: real raw scout launch with a >5KB command enters a real Treehouse worktree and reserves away capacity')
    p=run(['bin/fm-spawn.sh',task,project,'--scout','--backend','tmux',payload],timeout=100)
    assert (home/'raw-started').read_text().strip()=='5000'
    meta=home/'state'/f'{task}.meta'; fields=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
    note('published task metadata: '+meta.read_text())
    assert pathlib.Path(fields['worktree'])!=project and pathlib.Path(fields['worktree']).is_dir()
    p=run(['bin/fm-afk-contract.sh','live-workers'],env=BASE|{'FM_SPAWN_CAP_LAUNCH_GRACE':'0'}); assert p.stdout.strip()=='1'
    p=run(['bin/fm-spawn.sh','secondraw',project,'--scout','--backend','tmux','sleep 10'],expected=1)
    assert 'caps concurrent workers at 1' in p.stdout
    tmux('capture-pane','-p','-t',fields['window'],'-S','-20')
    note('PASS: 5000-byte payload ran in an isolated worktree; spawn returned success; second fresh launch was refused')
    note('SCENARIO: confirmed closure of the actual worker frees the same count')
    run(['bash','-c','. "$1/bin/fm-backend.sh"; fm_backend_kill_confirmed tmux "$2"','_',ROOT,fields['window']])
    # Keep an exact-name shell endpoint so positive shell process evidence
    # (rather than uncertain absence after relocation) proves no worker remains.
    name=fields['window'].split(':',1)[1]
    tmux('new-window','-d','-t','primary:','-n',name,'bash --noprofile --norc')
    p=run(['bin/fm-afk-contract.sh','live-workers'],env=BASE|{'FM_SPAWN_CAP_LAUNCH_GRACE':'0'}); assert p.stdout.strip()=='0'
    note('PASS: acknowledged close succeeded and a proven shell endpoint frees capacity')
    note('SCENARIO: renaming a real pending raw launch defeats closure acknowledgement and retains metadata, fresh admission and return cost')
    meta.unlink()
    note('Disposed the first task record after its acknowledged close; otherwise its default 120-second launch grace intentionally still reserves a slot for admission.')
    project2=LAB/'project2'
    run(['git','clone','-q',LAB/'origin.git',project2])
    task2='labcancel'+str(os.getpid())
    run(['bin/fm-brief.sh',task2,'project2','--scout'])
    brief2=home/'data'/task2/'brief.md'
    brief2.write_text(brief2.read_text().replace('{TASK}','Wait inside the disposable lab.').replace('{FIRSTMATE_SPEC}','Do not publish anything.'))
    marker=home/'pending-started'
    command='printf started > '+shlex.quote(str(marker))+'; read -t 120 lab_input'
    args=['bin/fm-spawn.sh',task2,str(project2),'--scout','--backend','tmux',command]
    note('$ '+shlex.join(args))
    child=subprocess.Popen(args,env=BASE,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+80
    while not marker.exists() and child.poll() is None and time.monotonic()<deadline: time.sleep(0.05)
    if not marker.exists() and child.poll() is not None:
        output,_=child.communicate(); note(output); note('early spawn exit='+str(child.returncode))
    assert marker.exists(), 'pending raw command did not start'
    assert child.poll() is None, 'raw shell command unexpectedly completed startup'
    meta2=home/'state'/f'{task2}.meta'
    fields2=dict(line.split('=',1) for line in meta2.read_text().splitlines() if '=' in line)
    endpoint=fields2['window']
    pane_pid=int(tmux('display-message','-p','-t',endpoint,'#{pane_pid}').stdout.strip())
    tmux('rename-window','-t',endpoint,'renamed-pending')
    child.terminate(); output,_=child.communicate(timeout=25)
    note(output); note('cancelled spawn exit='+str(child.returncode)); assert child.returncode!=0
    assert 'record is retained for endpoint cleanup' in output
    assert 'cleanup_recovery=launch' in meta2.read_text()
    run(['ps','-p',str(pane_pid),'-o','pid=,comm='])
    tmux('capture-pane','-p','-t','primary:renamed-pending','-S','-12')
    p=run(['bin/fm-afk-contract.sh','live-workers'],env=BASE|{'FM_SPAWN_CAP_LAUNCH_GRACE':'0'}); assert p.stdout.strip()=='1'
    p=run(['bin/fm-spawn.sh','aftercancel',project,'--scout','--backend','tmux','sleep 10'],expected=1)
    assert 'caps concurrent workers at 1' in p.stdout
    p=run(['bin/fm-afk-return.sh','begin'],expected=None)
    assert '1 task(s) live at return.' in p.stdout
    note('PASS: pending raw launch survived rename/cancel; cleanup recovery metadata, live count, fresh admission and return cost retained one reservation')
finally:
    if child and child.poll() is None:
        child.terminate(); child.wait(timeout=15)
    if socket:
        p=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=BASE,stdout=subprocess.PIPE,stderr=subprocess.PIPE); note('private tmux kill-server exit='+str(p.returncode))
        p=subprocess.run(['bin/fm-lab-home.sh','teardown',LAB/'home'],env=BASE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True); note('tmux-dir teardown exit='+str(p.returncode)+' '+p.stdout); assert p.returncode==0
    for directory in LAB.rglob('*'):
        if directory.is_dir() and not directory.is_symlink(): directory.chmod(directory.stat().st_mode | 0o700)
    shutil.rmtree(LAB); note('Disposable lab removed; all server/worker processes stopped'); log.close()

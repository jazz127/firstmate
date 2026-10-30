import json, os, pathlib, shutil, subprocess, tempfile, time, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64Z9JEQBNE8HSXVPR6KM05B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT/'.validation-tmp'))
children=[]
log=[]
def note(s):
    log.append(s); (E/'hidden-work-transcript.txt').write_text('\n'.join(log)+'\n')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('HERDR_') or k.startswith('TASKS_AXI_') or k in ['TMUX','NO_MISTAKES_GATE','CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'])}
env.update(FM_HOME=str(lab), PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR=str(lab/'tmp'), FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999', FM_STALE='999999', FM_SKIP_SECONDMATE_INHERIT='1')
def run(args, expected=0, timeout=45, inp=None):
    note('$ '+' '.join(map(str,args)))
    p=subprocess.run(list(map(str,args)),env=env,cwd=ROOT,text=True,input=inp,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    note(p.stdout.rstrip()+f'\n[exit {p.returncode}]')
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
sock=E/'hidden-work.sock'
try:
    run(['bin/fm-lab-home.sh','create',lab]);(lab/'tmp').mkdir()
    env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='test@example.invalid')
    note('SCENARIO: cleanup refuses hidden untracked files and preserves their bytes and the real isolated terminal.')
    repo=lab/'projects/disposable';wt=lab/'task-copy'
    run(['git','init','-q','-b','main',repo])
    (repo/'base.txt').write_text('base\n')
    run(['git','-C',repo,'add','base.txt']);run(['git','-C',repo,'commit','-qm','base'])
    run(['git','-C',repo,'worktree','add','-q','-b','fm/hidden-proof',wt,'main'])
    run(['git','-C',repo,'config','status.showUntrackedFiles','no'])
    hidden=wt/'valuable-untracked.txt';hidden.write_text('valuable untracked bytes\n')
    assert run(['git','-C',wt,'status','--porcelain']).strip()==''
    run(['tmux','-S',sock,'-f','/dev/null','new-session','-d','-s','fm-lab-hidden','-n','fm-hidden-proof','-c',wt,'sleep 90'])
    tmuxpid=run(['tmux','-S',sock,'display-message','-p','-t','fm-lab-hidden:fm-hidden-proof','#{pid}']).strip()
    env['TMUX']=str(sock)+','+tmuxpid+',0'
    (lab/'state/hidden-proof.meta').write_text('window=fm-lab-hidden:fm-hidden-proof\nendpoint_task_id=hidden-proof\nbackend=tmux\nworktree='+str(wt)+'\nproject='+str(repo)+'\nkind=ship\nmode=local-only\nspawn_gen=validation-hidden\n')
    out=run(['bin/fm-teardown.sh','hidden-proof'],expected=1,timeout=45)
    assert 'untracked' in out and 'valuable-untracked.txt' in out
    assert hidden.read_text()=='valuable untracked bytes\n'
    assert (lab/'state/hidden-proof.meta').exists()
    run(['tmux','-S',sock,'has-session','-t','fm-lab-hidden'])
    note('Hidden file bytes, task metadata, worktree, and real private tmux session all retained after refusal.')
finally:
    try:run(['tmux','-S',sock,'kill-server'])
    except Exception as ex:note('Cleanup diagnostic: '+str(ex))
    shutil.rmtree(lab)
    if sock.exists():sock.unlink()
    note('Private tmux server stopped and disposable home removed.')

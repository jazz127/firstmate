import os, pathlib, subprocess, tempfile, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M68D38F0G89SR9YF1VG8WT0K')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.phase-scratch'))
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') and k.endswith('_OVERRIDE') or k in ['FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TREEHOUSE_DIR','TREEHOUSE_LEASE_ID','TREEHOUSE_LEASE_HOLDER']:
        env.pop(k,None)
env.update(FM_HOME=str(lab),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='fmtest',GIT_AUTHOR_EMAIL='fmtest@example.invalid',GIT_COMMITTER_NAME='fmtest',GIT_COMMITTER_EMAIL='fmtest@example.invalid',TREEHOUSE_ROOT=str(lab/'pool'),TMPDIR=str(lab/'tmp'),TMUX='./fm-lab-absent-socket,0,0')
log=(evidence/'real-release.log').open('w')
proc=None

def run(args,cwd=lab,check=True):
    log.write('$ '+' '.join(map(str,args))+'\n');log.flush()
    r=subprocess.run(list(map(str,args)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    log.write(r.stdout+f'\nexit_status={r.returncode}\n');log.flush()
    if check and r.returncode: raise RuntimeError(str(args))
    return r.stdout
try:
    run(['bash',root/'bin/fm-lab-home.sh','create',lab],cwd=root)
    (lab/'tmp').mkdir()
    project=lab/'projects/release-proof'
    run(['git','init','-q','-b','main',project])
    (project/'proof.txt').write_text('disposable release verification\n')
    run(['git','add','proof.txt'],project)
    run(['git','commit','-qm','Disposable baseline'],project)
    wt=pathlib.Path(run(['treehouse','get','--lease','--no-fetch','--branch','fm/task-live'],project).strip().splitlines()[-1])
    assert str(wt).startswith(str(lab)+'/'), wt
    (lab/'state/.last-watcher-beat').touch()
    (lab/'state/task-live.meta').write_text(f'window=fm-lab-validation:fm-task-live\nendpoint_task_id=task-live\nworktree={wt}\nproject={project}\nkind=ship\nmode=local-only\nspawn_gen=phase-live-release\n')
    (lab/'.tasks.toml').write_text('backend = "markdown"\n')
    (lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run(['tasks-axi','add','task-live','Disposable live release','--kind','ship','--file',lab/'data/backlog.md'])
    run(['tasks-axi','start','task-live','--file',lab/'data/backlog.md'])
    proc=subprocess.Popen(['sleep','300'],cwd=wt,env=env)
    log.write(f'Owned disposable sleeper pid={proc.pid}, cwd={wt}\n');log.flush()
    run(['treehouse','status'],project)
    run(['bash',root/'bin/fm-teardown.sh','task-live'])
    exit_code=proc.wait(timeout=5)
    assert exit_code != 0, exit_code
    assert not (lab/'state/task-live.meta').exists()
    assert not (lab/'state/task-live.backlog-close').exists()
    state=json.loads((wt.parent.parent/'treehouse-state.json').read_text())
    (evidence/'real-treehouse-state.json').write_text(json.dumps(state,indent=2)+'\n')
    out=run(['treehouse','status'],project)
    assert 'available' in out.lower(), out
    out=run(['tasks-axi','show','task-live','--file',lab/'data/backlog.md'])
    assert 'state: done' in out, out
    shutil.copyfile(lab/'data/backlog.md',evidence/'real-backlog.md')
    log.write(f'OBSERVED: sleeper exited ({exit_code}); task record and pending-close marker absent; real Treehouse pool slot available; real tasks-axi backlog done.\n')
finally:
    if proc is not None and proc.poll() is None:
        proc.kill();proc.wait(timeout=5)
    log.close()
    shutil.rmtree(lab)

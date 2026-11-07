import os,pathlib,subprocess,json
root=pathlib.Path.cwd();sandbox=root/'.test-sync-validation/teardown-live-final';sandbox.mkdir()
home=sandbox/'home';origin=sandbox/'origin.git';project=sandbox/'project';writer=sandbox/'writer';pool=sandbox/'pool'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_','GIT_','TREEHOUSE_'))}
env.update(FM_HOME=str(home),TREEHOUSE_ROOT=str(pool),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',TMPDIR=str(root/'.test-sync-validation/tmp'))
results=[]
def run(args,cwd=root,expected=0):
    p=subprocess.run([str(a) for a in args],cwd=cwd,env=env,text=True,capture_output=True,timeout=90)
    item={'argv':[str(a) for a in args],'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr};results.append(item);print(json.dumps(item),flush=True)
    assert p.returncode==expected,item
    return p.stdout.strip()
try:
    run(['bin/fm-lab-home.sh','create',home])
    (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    run(['tasks-axi','add','sync-validation-task','Disposable teardown validation','--kind','ship','--start','--file',home/'data/backlog.md'],home)
    run(['git','init','--bare','--initial-branch=main',origin])
    run(['git','clone',origin,project])
    (project/'content.txt').write_text('baseline\n')
    run(['git','add','content.txt'],project);run(['git','commit','-m','Disposable baseline'],project);run(['git','push','origin','main'],project)
    worktree=pathlib.Path(run(['treehouse','get','--lease','--no-fetch','-b','work','--base','main'],project))
    assert worktree.is_relative_to(pool),worktree
    (worktree/'content.txt').write_text('new work\n')
    run(['git','add','content.txt'],worktree);run(['git','commit','-m','Disposable task change'],worktree)
    task='sync-validation-task'
    meta=home/'state'/f'{task}.meta'
    meta.write_text(f'project={project}\nworktree={worktree}\nkind=ship\nmode=local-only\nbackend=tmux\n')
    run([root/'bin/fm-teardown.sh',task],expected=1)
    assert 'missing, empty, or ambiguous window' not in results[-1]['stderr']
    assert 'not on any remote' in results[-1]['stderr'],results[-1]
    assert meta.exists() and (worktree/'content.txt').read_text()=='new work\n'
    print('Unpushed work was refused and preserved.',flush=True)
    run(['git','clone',origin,writer]);run(['git','fetch',worktree,'HEAD'],writer);run(['git','push','origin','FETCH_HEAD:refs/heads/landed'],writer)
    refs=run(['git','for-each-ref','--format=%(refname)','refs/remotes/origin/landed'],project)
    assert refs==''
    (worktree/'unsaved.txt').write_text('preserve me\n')
    run([root/'bin/fm-teardown.sh',task],expected=1)
    assert meta.exists() and (worktree/'unsaved.txt').read_text()=='preserve me\n'
    print('Landed work with an untracked edit was refused and preserved.',flush=True)
    (worktree/'unsaved.txt').unlink()
    run([root/'bin/fm-teardown.sh',task])
    assert not meta.exists()
    assert run(['git','for-each-ref','--format=%(refname)','refs/remotes/origin/landed'],project)=='refs/remotes/origin/landed'
    status=run(['treehouse','status'],project)
    print('Stale remote refs refreshed, landed work returned through real Treehouse, and task record retired.',flush=True)
finally:
    pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK/teardown-live.json').write_text(json.dumps(results,indent=2)+'\n')

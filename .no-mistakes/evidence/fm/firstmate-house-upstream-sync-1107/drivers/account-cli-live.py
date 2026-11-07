import os,pathlib,subprocess,json
root=pathlib.Path.cwd();home=root/'.test-sync-validation/account-cli-home'
project=root/'.test-sync-validation/teardown-live-final/project'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','FMX_','HERDR_','REX_','TASKS_AXI_')) and k!='TMUX'}
env.update(FM_HOME=str(home),TMPDIR=str(root/'.test-sync-validation/tmp'))
results=[]
def run(args,expected=0):
    p=subprocess.run([str(a) for a in args],env=env,text=True,capture_output=True,timeout=25)
    results.append({'argv':[str(a) for a in args],'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr});print(json.dumps(results[-1]),flush=True)
    assert p.returncode==expected,results[-1]
    return p.stdout+p.stderr
try:
    run(['bin/fm-lab-home.sh','create',home])
    (home/'config/backlog-backend').write_text('manual\n')
    (home/'config/claude-accounts').write_text('ordinary\n')
    args=['bin/fm-spawn.sh','account-guard-check',project,'--scout','--harness','claude','--backend','tmux']
    out=run(args,1);assert 'must name one with --account' in out,out
    out=run(args+['--account','undeclared'],1);assert 'not declared in config/claude-accounts' in out,out
    (home/'config/claude-account').write_text('ordinary\n')
    out=run(args+['--account','ordinary'],1);assert 'both present' in out,out
    assert not list((home/'state').glob('*.meta'))
    print('Real fm-spawn refused missing, undeclared, and conflicting account selections before task publication or endpoint provisioning.')
finally:
    pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK/account-cli-live.json').write_text(json.dumps(results,indent=2)+'\n')

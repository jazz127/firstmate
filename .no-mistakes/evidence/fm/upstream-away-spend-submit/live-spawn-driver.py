import os, pathlib, subprocess, shutil, time, json
root=pathlib.Path.cwd(); lab=root/'.l'; ev=pathlib.Path(os.environ['FM_TEST_EVIDENCE'])
lab.mkdir(); env=dict(os.environ)
for k in list(env):
 if k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),FM_SUPERVISION_ACTOR='main',NM_HOME=str(lab/'nm'))
def run(args,check=True,**kw):
 r=subprocess.run(args,env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw)
 out=r.stdout.replace(str(root),'$WORKTREE').replace(str(pathlib.Path.home()),'$HOME')
 print('$ '+' '.join(args).replace(str(root),'$WORKTREE')); print(out.rstrip()); print('exit='+str(r.returncode),flush=True)
 if check and r.returncode: raise RuntimeError(out)
 return r

def tm(*args,**kw):return run(['tmux','-L','fm-lab',*args],**kw)
def count(want,label):
 r=run(['bash','bin/fm-afk-contract.sh','live-workers']); assert r.stdout.strip()==str(want),(label,r.stdout,want)
 print('OBSERVED '+label+': '+str(want),flush=True)
def meta(id,window,kind='scout',extra=''):
 (lab/'state'/f'{id}.meta').write_text(f'window=primary:{window}\nkind={kind}\nworktree={lab}/project\nproject={lab}/project\nharness=codex\n'+extra)
try:
 run(['bash','bin/fm-lab-home.sh','create',str(lab)])
 (lab/'tmux').mkdir(); (lab/'config'/'supervision-host').touch()
 (lab/'config'/'crew-harness').write_text('codex\n')
 env['TREEHOUSE_ROOT']=str(lab/'pool')
 env['SHELL']='/bin/bash'
 (lab/'project').mkdir()
 run(['git','-C',str(lab/'project'),'init','-q','-b','main'])
 run(['git','-C',str(lab/'project'),'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','commit.gpgsign=false','commit','-q','--allow-empty','-m','Initial disposable project'])
 (lab/'data'/'raw-launch').mkdir()
 (lab/'data'/'raw-launch'/'brief.md').write_text("# Task\n## Captain's intent\nExercise raw launch reservation with a local process.\n\n## Firstmate spec\nRun only the supplied raw local command.\n")
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'codex --no-alt-screen')
 env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
 run(['bash','bin/fm-afk-contract.sh','enter','--spend','1','--words','Disposable raw launch'])
 r=run(['bash','bin/fm-spawn.sh','raw-launch',str(lab/'project'),'sleep 20','--scout'],check=False,timeout=80)
 tm('capture-pane','-p','-t','primary:fm-raw-launch',check=False)
 assert r.returncode==0,'real raw spawn setup must succeed'
 count(1,'fresh raw launch reserves capacity with real Treehouse and tmux')
 r=run(['bash','bin/fm-spawn.sh','next',str(lab/'project'),'sleep 1','--scout'],check=False,timeout=15)
 assert r.returncode==1 and 'caps concurrent workers' in r.stdout
 print('OBSERVED concurrent raw launch refused at cap=1')
 time.sleep(22)
 env['FM_SPAWN_CAP_LAUNCH_GRACE']='0'
 count(0,'actually exited raw worker frees capacity after grace')
 print('LIVE RAW SPAWN DRIVER COMPLETED')
finally:
 tm('kill-server',check=False)
 for d,dirs,files in os.walk(lab):os.chmod(d,0o700)
 shutil.rmtree(lab)
 print('TEARDOWN disposable home and private tmux server removed',flush=True)

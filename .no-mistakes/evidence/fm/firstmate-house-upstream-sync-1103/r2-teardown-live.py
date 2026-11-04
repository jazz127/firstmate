import os,subprocess,json,signal,time
from pathlib import Path
root=Path.cwd(); E=Path('~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV'); world=root/'.phase-tmp'/'r2-teardown-real-retry';world.mkdir()
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_')):env.pop(k)
env.update(GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',TREEHOUSE_ROOT=str(world/'pool'),TMUX=str(world/'no-server.sock')+',0,0')
log=(E/'r2-teardown-live.log').open('w')
def run(args,cwd=root,ok=(0,),show=True):
 p=subprocess.run(list(map(str,args)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=50)
 if show:log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit: '+str(p.returncode)+'\n');log.flush()
 if p.returncode not in ok:raise RuntimeError(p.stdout)
 return p
origin=world/'origin.git';repo=world/'project';home=world/'home'
run(['git','init','--bare','--initial-branch=main',origin],show=False);run(['git','init','-b','main',repo],show=False)
(repo/'README.md').write_text('landed base\n');run(['git','add','README.md'],repo,show=False);run(['git','commit','-m','base'],repo,show=False)
run(['git','remote','add','origin',origin],repo,show=False);run(['git','push','-u','origin','main'],repo,show=False);run(['git','remote','set-head','origin','main'],repo,show=False)
run([root/'bin/fm-lab-home.sh','create',home]);env['FM_HOME']=str(home)
socket=E/'r2-teardown.sock'
run(['tmux','-S',socket,'new-session','-d','-s','fixture','-x','120','-y','40'])
env['TMUX']=str(socket)+',0,0'
import atexit
atexit.register(lambda:subprocess.run(['tmux','-S',str(socket),'kill-server'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
for task in ['clean','late']:
 p=run(['treehouse','get','--lease','--no-fetch'],repo);wt=Path(p.stdout.strip().splitlines()[-1]);assert wt.is_relative_to(world)
 (home/'state'/f'{task}.meta').write_text(f'window=unavailable:fm-{task}\nbackend=tmux\nkind=ship\nmode=local-only\nworktree={wt}\nproject={repo}\ndecisions_reviewed=1\ndecision_keys=\n')
 worker=None
 if task=='late':
  ready=world/'writer-ready'
  code='import signal,time,sys\nfrom pathlib import Path\ndef end(sig,frame):\n Path("late.txt").write_text("late worker bytes preserved\\n")\n sys.exit(0)\nsignal.signal(signal.SIGTERM,end)\nPath(sys.argv[1]).touch()\nwhile True:time.sleep(.1)\n'
  worker=subprocess.Popen(['python3','-c',code,str(ready)],cwd=wt,env=env,start_new_session=True)
  for _ in range(100):
   if ready.exists():break
   time.sleep(.02)
  assert ready.exists()
 try:
  r=run([root/'bin/fm-teardown.sh',task],ok=(0,) if task=='clean' else (1,))
  if task=='clean':assert not (home/'state'/f'{task}.meta').exists()
  else:
   assert (home/'state'/f'{task}.meta').exists() and (wt/'late.txt').read_text()=='late worker bytes preserved\n'
   log.write('retained worker output:\n'+(wt/'late.txt').read_text());run(['git','status','--short'],wt)
 finally:
  if worker:
   if worker.poll() is None:worker.terminate()
   worker.wait(timeout=10)
log.close()
print('Real Treehouse clean return succeeded; a real process writing during SIGTERM caused cleanup refusal and preserved bytes and task records.')

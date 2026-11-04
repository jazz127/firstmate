import os,subprocess,json,time,shlex
from pathlib import Path
root=Path.cwd();E=Path('~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV');lab=E/'r2d'; lab.mkdir()
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_')) or k in ('TMUX','CLAUDECODE','NO_MISTAKES_GATE'):env.pop(k)
env.update(FM_HOME=str(lab),NM_HOME=str(lab/'nm'),TMUX_TMPDIR=str(lab/'tmux'),DISABLE_AUTOUPDATER='1',FM_TASK_ID='child')
log=(E/'r2-claude-inactive-live.log').open('w')
def run(args,check=True):
 p=subprocess.run(list(map(str,args)),cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
 log.write('$ '+shlex.join(list(map(str,args)))+'\n'+p.stdout+'exit: '+str(p.returncode)+'\n');log.flush()
 if check and p.returncode:raise RuntimeError(p.stdout)
 return p
T=['tmux','-L','fm-lab']
try:
 run(['bin/fm-lab-home.sh','create',lab]);(lab/'tmux').mkdir();state=lab/'state'
 gen=run(['bin/fm-busy-event.sh','arm',state,'child']).stdout.strip()
 hooks={}
 for event,value in [('UserPromptSubmit','busy'),('Stop','idle')]:
  cmd=shlex.join([str(root/'bin/fm-busy-event.sh'),'apply',str(state),'child',value,'--gen',gen,'--source','claude-hook','--event',event])
  hooks[event]=[{'hooks':[{'type':'command','command':cmd}]}]
 settings=lab/'settings.json';settings.write_text(json.dumps({'hooks':hooks}))
 # A persistent native JSON session permits observing a real Stop while its agent remains live.
 cmd=shlex.join(['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--no-session-persistence','--tools','','--system-prompt','Respond READY. Use no tools.','--settings',str(settings)])
 run(T+['new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),cmd,';','set-window-option','-t','primary','remain-on-exit','on'])
 payload=json.dumps({'type':'user','message':{'role':'user','content':'Respond READY only.'}})
 run(T+['send-keys','-t','primary','-l',payload]);run(T+['send-keys','-t','primary','Enter'])
 idle=False
 for _ in range(90):
  if (state/'child.busy-state').exists():
   try:
    record=dict(word.split('=',1) for word in (state/'child.busy-state').read_text().split() if '=' in word)
    if record.get('state')=='idle' and record.get('event')=='Stop':idle=True;break
   except ValueError:pass
  if _>3 and 'pane_dead=1' in run(T+['list-panes','-t','primary','-F','pane_dead=#{pane_dead}']).stdout:break
  time.sleep(1)
 screen=run(T+['capture-pane','-p','-S','-150','-t','primary']).stdout
 (E/'r2-claude-native-screen.txt').write_text(screen)
 if not idle:raise RuntimeError('Native Stop did not publish idle; see native screen')
 log.write('Native Stop busy-state contract: '+json.dumps(record)+'\n')
 project=lab/'project';run(['git','init','-q',project]);(project/'readme').write_text('base\n');run(['git','-C',project,'add','readme']);run(['git','-C',project,'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','-qm','base'])
 meta=state/'child.meta';status=state/'child.status';old=int(time.time())-600
 meta.write_text('window=primary:0\nbackend=tmux\nkind=scout\nharness=claude\nspawn_gen=s'+gen[1:]+'\nworktree='+str(project)+'\nproject='+str(project)+'\n')
 def age():
  for p in (meta,status):os.utime(p,(time.time()-1000,time.time()-1000))
 status.write_text('failed [at='+str(old)+']: prior incarnation failed\n');age()
 # Route all production tmux reads to this private server.
 env['TMUX']=str(lab/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab')+',0,0'
 first=run(['bin/fm-crew-state.sh','child']);assert 'state: failed' in first.stdout,first.stdout
 run(['bin/fm-inactive-reconcile.sh','scan','--startup'])
 assert not list((state/'terminal-outcomes').glob('*.pending'))
 log.write('New live incarnation: prior terminal outcome withheld.\n')
 status.write_text('failed [at='+str(int(time.time())+1)+']: current incarnation finished\n');age()
 run(['bin/fm-inactive-reconcile.sh','scan','--startup'])
 receipts=list((state/'terminal-outcomes').glob('*.pending'));assert receipts, list(state.iterdir())
 for p in receipts:log.write('Idle same-incarnation terminal receipt: '+p.read_text()+'\n')
finally:
 run(T+['kill-server'],check=False);log.close()
 import shutil
 shutil.rmtree(lab)

import os, pathlib, subprocess, json, shlex, time, shutil, re
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.l'; EVIDENCE=pathlib.Path(os.environ['FM_TEST_EVIDENCE'])
LOG=(EVIDENCE/'spawn-evidence.log').open('w')
def clean(s):
 return re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<EMAIL>',str(s).replace(str(ROOT),'<WORKTREE>').replace('<OPERATOR_HOME>','<OPERATOR_HOME>'))
def note(s):
 s=clean(s); LOG.write(s+'\n');LOG.flush();print(s,flush=True)
ENV=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','CLAUDECODE','HERDR_SESSION','HERDR_ENV']:
 ENV.pop(k,None)
ENV.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'t'),TMPDIR=str(LAB/'tmp'),DISABLE_AUTOUPDATER='1',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
def run(args,env=None,check=True,quiet=False,cwd=ROOT,timeout=30):
 p=subprocess.run(args,env=env or ENV,cwd=cwd,capture_output=True,text=True,timeout=timeout)
 if not quiet: note('$ '+shlex.join(map(str,args))+f'\nexit={p.returncode}\n'+p.stdout+p.stderr)
 if check and p.returncode: raise RuntimeError(shlex.join(map(str,args))+' failed')
 return p

def tm(*args,**kw):return run(['tmux','-L','fm-lab',*args],**kw)
def count(expected,label):
 note('SCENARIO: '+label)
 p=run(['bash','bin/fm-afk-spend-count.sh',str(LAB/'state')]); assert p.stdout.strip()==str(expected),(label,p.stdout,expected)
def status(s):
 (LAB/'state/task.status').write_text(s+'\n');note('task.status: '+s)
def readstate():return run(['bash','bin/fm-crew-state.sh','task'],check=False)
def capprobe(blocked):
 p=run(['bash','bin/fm-spawn.sh','fresh',str(LAB/'no-project'),'--mode','no-mistakes','--yolo','off'],check=False)
 assert ('caps concurrent workers' in p.stderr)==blocked,p.stdout+p.stderr
 note('Fresh admission '+('refused at spend cap' if blocked else 'passed spend cap and reached independent missing-project check'))
try:
 LAB.mkdir();run(['bash','bin/fm-lab-home.sh','create',str(LAB)])
 for d in ['t','tmp','project','nm']:(LAB/d).mkdir()
 ENV.update(TREEHOUSE_ROOT=str(LAB/'pool'),SHELL=shutil.which('bash'),NM_HOME=str(LAB/'nm'))
 (LAB/'config/supervision-host-off').touch();(LAB/'config/backlog-backend').write_text('manual\n')
 (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 run(['git','init','-q','-b','main',str(LAB/'project')]);run(['git','-C',str(LAB/'project'),'-c','user.name=lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','Initialize disposable validation project'])
 run(['git','clone','--bare',str(LAB/'project'),str(LAB/'origin.git')]);run(['git','-C',str(LAB/'project'),'remote','add','origin',str(LAB/'origin.git')]);run(['git','-C',str(LAB/'project'),'fetch','origin']);run(['git','-C',str(LAB/'project'),'remote','set-head','origin','main'])
 run(['treehouse','init'],cwd=LAB/'project')
 note('Local real Treehouse configuration:\n'+(LAB/'project/treehouse.toml').read_text())
 run(['bash','bin/fm-afk-contract.sh','enter','--spend','1','--words','Disposable actual spawn validation'])
 tm('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'bash --noprofile --norc')
 tm('set-option','-g','default-shell',shutil.which('bash'));tm('set-option','-g','default-command','bash --noprofile --norc')
 ENV['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
 for key in ['FM_HOME','TREEHOUSE_ROOT','NM_HOME','DISABLE_AUTOUPDATER','TMPDIR']:
  tm('set-environment','-g',key,ENV[key])
 def brief(id):
  run(['bash','bin/fm-brief.sh',id,'demo','--scout'])
  f=LAB/'data'/id/'brief.md';text=f.read_text().replace('{TASK}','Disposable validation: run the provided local command and wait. Do not contact external services.').replace('{FIRSTMATE_SPEC}','No further work.')
  f.write_text(text)
 brief('raw')
 p=run(['bash','bin/fm-spawn.sh','raw',str(LAB/'project'),'sleep 120','--scout'],check=False,timeout=100)
 tm('capture-pane','-p','-t','primary:fm-raw','-S','-25',check=False)
 assert p.returncode==0,p.stdout+p.stderr
 note('Published task metadata:\n'+(LAB/'state/raw.meta').read_text())
 run(['bash','bin/fm-afk-spend-count.sh',str(LAB/'state')]);capprobe(True)
 p=run(['bash','-c','. bin/fm-backend.sh; fm_backend_kill_confirmed tmux primary:fm-raw'],check=False);assert p.returncode==0
 # Kill the worker's window leaves a record whose missing identity remains conservatively counted.
 count(1,'An acknowledged raw-worker close does not turn later unproven tmux absence into proof')
 (LAB/'state/raw.meta').unlink()
 brief('cancel')
 launch=open(LAB/'launch.log','w')
 p=subprocess.Popen(['bash','bin/fm-spawn.sh','cancel',str(LAB/'project'),"bash -c 'while :; do read -t 1 x; done'",'--scout'],env=ENV,stdout=launch,stderr=subprocess.STDOUT)
 deadline=time.monotonic()+90
 while time.monotonic()<deadline:
  if (LAB/'state/cancel.meta').exists():break
  if p.poll() is not None:break
  time.sleep(.005)
 assert (LAB/'state/cancel.meta').exists(),'spawn never published cancellable metadata'
 deadline=time.monotonic()+12
 while time.monotonic()<deadline:
  capture=tm('capture-pane','-p','-t','primary:fm-cancel','-S','-20',quiet=True,check=False).stdout
  if ". '/tmp/fm-cancel+" in capture: break
  if p.poll() is not None: break
  time.sleep(.01)
 note('Delivered launch pane before rename:\n'+capture)
 assert p.poll() is None,'launch ended before cancellation scenario'
 count(1,'Fresh real spawn reserves capacity before startup acknowledgement')
 tm('rename-window','-t','primary:fm-cancel','moved-cancel')
 # wait until the staged launch is delivered (or timeout), then signal the original spawn.
 time.sleep(1.2)
 p.terminate();p.wait(timeout=20);launch.close()
 note('Cancelled spawn transcript:\n'+(LAB/'launch.log').read_text())
 note('Retained metadata:\n'+(LAB/'state/cancel.meta').read_text())
 assert 'cleanup_recovery=launch' in (LAB/'state/cancel.meta').read_text()
 tm('display-message','-p','-t','primary:moved-cancel','#{pane_current_command}')
 count(1,'Real renamed launch survives cancellation and retains its capacity reservation');capprobe(True)
 p=run(['bash','bin/fm-afk-return.sh','check'],check=False,timeout=30);assert '1 task(s) live at return.' in p.stdout
 note('ACTUAL SPAWN DRIVER COMPLETE')
except Exception as e:
 note('DRIVER LIMIT OR FAILURE: '+repr(e));raise
finally:
 if (LAB/'t').exists():tm('kill-server',check=False)
 if LAB.exists():
  for path,dirs,files in os.walk(LAB): os.chmod(path,0o700)
  shutil.rmtree(LAB)
 note('Disposable local origin, Treehouse pool, lab and private server removed');LOG.close()

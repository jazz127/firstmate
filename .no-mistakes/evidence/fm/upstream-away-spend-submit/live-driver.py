import os, pathlib, subprocess, json, shlex, time, shutil, re
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.l'; EVIDENCE=pathlib.Path(os.environ['FM_TEST_EVIDENCE'])
LOG=(EVIDENCE/'product-evidence.log').open('w')
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
 for d in ['t','tmp','worker']: (LAB/d).mkdir()
 (LAB/'config/supervision-host-off').touch();(LAB/'config/backlog-backend').write_text('manual\n')
 (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 run(['git','init','-q','-b','lab-task',str(LAB/'worker')]);run(['git','-C',str(LAB/'worker'),'-c','user.name=lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','Initialize disposable validation project'])
 run(['bash','bin/fm-afk-contract.sh','enter','--spend','1','--words','Disposable live spend-cap validation'])
 tm('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'bash --noprofile --norc')
 tm('set-option','-g','default-command','bash --noprofile --norc')
 ENV['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
 note('All production CLI calls use this lab TMUX socket identity: '+ENV['TMUX'])
 # Test real worker lifecycle via a real CLI that holds stream input open. Normal login is used; no credential copies.
 gen=run(['bash','bin/fm-busy-event.sh','arm',str(LAB/'state'),'task','--state','unknown','--source','claude-hook','--event','lab-start']).stdout.strip()
 busy=ROOT/'bin/fm-busy-event.sh'
 hooks={}
 for event,state in [('UserPromptSubmit','busy'),('Stop','idle'),('StopFailure','idle'),('SessionEnd','idle')]:
  command=shlex.join(['bash',str(busy),'apply',str(LAB/'state'),'task',state,'--gen',gen,'--source','claude-hook','--event',event.lower()])
  hooks[event]=[{'hooks':[{'type':'command','command':command}]}]
 settings=LAB/'settings.json';settings.write_text(json.dumps({'hooks':hooks}))
 meta=LAB/'state/task.meta';meta.write_text(f'window=primary:worker\nworktree={LAB}/worker\nproject={LAB}/worker\nharness=claude\nkind=scout\nmode=no-mistakes\n')
 cli=shlex.join(['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--no-session-persistence','--setting-sources','project,local','--settings',str(settings),'--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools',''])
 fifo=LAB/'input'; os.mkfifo(fifo)
 cli='exec 3<> '+shlex.quote(str(fifo))+'; '+cli+' <&3'
 tm('new-window','-d','-n','worker','-c',str(LAB/'worker'),cli)
 tm('set-window-option','-t','primary:worker','automatic-rename','off')
 payload=json.dumps({'type':'user','message':{'role':'user','content':'Reply exactly SPEND_LAB_READY. Do not use tools or read any file.'}})
 note('Actual Claude stream request: '+payload)
 with fifo.open('w') as f: f.write(payload+'\n'); f.flush()
 deadline=time.monotonic()+60
 while time.monotonic()<deadline:
  rec=(LAB/'state/task.busy-state').read_text()
  if 'state=idle' in rec:break
  time.sleep(.5)
 tm('capture-pane','-p','-t','primary:worker','-S','-100')
 note('Persisted native-hook record:\n'+(LAB/'state/task.busy-state').read_text())
 activity=run(['bash','-c','. bin/fm-backend.sh; . bin/fm-busy-lib.sh; fm_busy_classify_meta "$1" task "$2"','_',str(meta),str(LAB/'state')]).stdout
 if not activity.startswith('idle '): raise RuntimeError('Real Claude hook did not establish idle: '+activity)
 for verb in ['paused','captain-held','needs-decision [key=answer]']:
  status(verb+': waiting for an answer');readstate();count(0,'Proven idle '+verb+' worker frees away capacity');capprobe(False)
 status('paused [key=answer]: waiting\nworking: resumed without resolving answer')
 count(1,'New working event overrides an older unresolved wait');capprobe(True)
 status('needs-decision [key=answer]: waiting\nresolved [key=answer]: answered')
 count(1,'Resolved wait restores capacity reservation')
 status('done: report complete')
 count(0,'An idle completed scout frees capacity')
 # Real submitted request goes through actual Claude to actual upstream, then native hooks.
 payload=json.dumps({'type':'user','message':{'role':'user','content':'Write a detailed explanation of the numbers one through one hundred, then conclude SPEND_LAB_RESUMED. Do not use tools.'}})
 note('Actual Claude stream request: '+payload)
 with fifo.open('w') as f: f.write(payload+'\n'); f.flush()
 deadline=time.monotonic()+15
 while time.monotonic()<deadline:
  activity=run(['bash','-c','. bin/fm-backend.sh; . bin/fm-busy-lib.sh; fm_busy_classify_meta "$1" task "$2"','_',str(meta),str(LAB/'state')],quiet=True).stdout
  if activity.startswith('busy '):break
  time.sleep(.1)
 note('Resumed native-hook activity: '+activity); assert activity.startswith('busy ')
 count(1,'A resumed busy worker with stale done remains counted');capprobe(True)
 # Remove the semantic record to exercise genuine missing evidence while the real worker is running.
 (LAB/'state/task.busy-state').unlink()
 count(1,'A resumed worker with unreadable activity remains counted')
 tm('rename-window','-t','primary:worker','relocated')
 count(1,'A renamed real worker is conservatively counted despite old-target absence');capprobe(True)
 p=run(['bash','-c','. bin/fm-backend.sh; fm_backend_kill_confirmed tmux primary:worker'],check=False); assert p.returncode!=0
 tm('display-message','-p','-t','primary:relocated','#{pane_current_command}')
 note('Confirmed close refused for absent old target; relocated endpoint survived')
 meta.write_text(meta.read_text()+'cleanup_recovery=launch\n')
 count(1,'Cleanup recovery reservation survives an unproven close')
 p=run(['bash','bin/fm-afk-return.sh','check'],check=False);assert '1 task(s) live at return.' in p.stdout
 tm('kill-window','-t','primary:relocated')
 # A positively shell-only endpoint is distinguishable from absence.
 tm('new-window','-d','-n','worker','-c',str(LAB/'worker'),'bash --noprofile --norc')
 count(1,'Unresolved launch cleanup reserves a shell-only endpoint')
 meta.write_text(meta.read_text().replace('cleanup_recovery=launch\n',''))
 count(0,'A positively exited shell-only worker frees away capacity');capprobe(False)
 meta.write_text(meta.read_text()+'kind=secondmate\n')
 count(0,'Persistent secondmate records are excluded from ordinary spend')
 note('LIVE DRIVER COMPLETE')
except Exception as e:
 note('DRIVER LIMIT OR FAILURE: '+repr(e));raise
finally:
 if (LAB/'t').exists():tm('kill-server',check=False)
 if LAB.exists():shutil.rmtree(LAB)
 note('Disposable lab and private server removed');LOG.close()

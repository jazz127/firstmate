import os, subprocess, time, pathlib, shutil, signal, json
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M472BY3F7ZBVXN1MGABMMSVX')
LAB=ROOT/'.l'
assert not LAB.exists(), 'disposable lab path is occupied'
env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX'):
 env.pop(k,None)
env.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'tmux'),FM_SUPERVISION_ACTOR='main',TMPDIR=str(ROOT/'.test-phase-tmp'))
log=open(EVID/'live-tmux.log','w',buffering=1)
results=[]
server_pid=None
stopped=False

def run(args,timeout=25,allow=False):
 p=subprocess.run([str(a) for a in args],env=env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.write('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+f'[exit={p.returncode}]\n')
 if p.returncode and not allow: raise RuntimeError(p.stdout)
 return p

def tm(*args,**kw): return run(['tmux','-L','fm-lab',*args],**kw)
def sh(program,*args,**kw): return run(['bash','-c',program,'_',*args],**kw)
def count(expected):
 p=run([ROOT/'bin/fm-afk-spend-count.sh',LAB/'state'])
 assert p.stdout.strip()==str(expected), f'count expected {expected}, got {p.stdout!r}'
 return p

def snapshot(expected):
 run([ROOT/'bin/fm-afk-contract.sh','enter','--spend','1'])
 count(expected)
 p=run([ROOT/'bin/fm-spawn.sh','fresh',LAB/'absent-project','--mode','no-mistakes','--yolo','off'],allow=True)
 assert p.returncode!=0
 assert ('caps concurrent workers' in p.stdout)==bool(expected), p.stdout
 p=run([ROOT/'bin/fm-afk-return.sh','check'],allow=True)
 assert p.returncode in (0,3), p.stdout
 assert f'{expected} task(s) live at return.' in p.stdout,p.stdout

def meta(target,harness='custom-agent',kind='scout'):
 (LAB/'state/task.meta').write_text(f'backend=tmux\nwindow={target}\nkind={kind}\nharness={harness}\n')
 (LAB/'state/task.status').write_text('working: disposable live validation\n')

try:
 run([ROOT/'bin/fm-lab-home.sh','create',LAB])
 (LAB/'tmux').mkdir()
 (LAB/'config/supervision-host').touch()
 tm('new-session','-d','-s','primary','-n','probe','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={LAB}','codex --disable hooks')
 tm('set-window-option','-t','primary:probe','automatic-rename','off')
 socket=tm('display-message','-p','-t','primary:probe','#{socket_path}').stdout.strip()
 server_pid=int(tm('display-message','-p','-t','primary:probe','#{pid}').stdout.strip())
 env['TMUX']=f'{socket},{server_pid},0'
 time.sleep(3)
 tm('capture-pane','-p','-t','primary:probe','-S','-100')
 meta('primary:probe','codex')
 run([ROOT/'bin/fm-afk-contract.sh','enter','--spend','1'])
 snapshot(1)
 (LAB/'state/task.status').write_text('done: disposable report complete\n')
 run([ROOT/'bin/fm-busy-event.sh','arm',LAB/'state','task','--state','busy','--source','fm-spawn','--event','resume'])
 activity=sh('. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; fm_busy_classify_meta "$2/state/task.meta" task "$2/state"',ROOT,LAB).stdout.strip()
 assert activity=='unknown codex-unverified',activity
 snapshot(1)
 run([ROOT/'bin/fm-busy-event.sh','apply',LAB/'state','task','unknown','--current-gen','--source','fm-spawn','--event','unavailable'])
 snapshot(1)
 tm('send-keys','-t','primary:probe','-l','Live-validation probe only: reply with exactly LIVE_PROBE_OK. Do not run tools or commands, change files, start supervision, or delegate work.')
 tm('send-keys','-t','primary:probe','Enter')
 time.sleep(1)
 tm('send-keys','-t','primary:probe','Enter')
 ready=False
 for _ in range(45):
  time.sleep(1)
  pane=tm('capture-pane','-p','-t','primary:probe','-S','-100').stdout
  if 'LIVE_PROBE_OK' in pane and ('• LIVE_PROBE_OK' in pane or '\n  LIVE_PROBE_OK' in pane or '\nLIVE_PROBE_OK' in pane): ready=True;break
  if 'Do you trust' in pane or 'Hooks need review' in pane or 'Sign in' in pane: break
 (EVID/'codex-pane.txt').write_text(pane)
 results.append(dict(name='Codex resumed done worker remains counted under unknown activity',passed=True,upstream_reply=ready))
 # The raw command is a genuine supported command, not an imitation harness.
 # Its actual foreground process keeps a pane alive until explicitly killed.
 tm('new-window','-d','-t','primary:','-n','raw','-c',ROOT,'python3 -c "import time; print(\'RAW_WORKER_RUNNING\', flush=True); time.sleep(180)"')
 tm('set-window-option','-t','primary:raw','automatic-rename','off')
 meta('primary:raw')
 time.sleep(1)
 state=sh('. "$1/bin/fm-backend.sh"; fm_backend_worker_state tmux primary:raw',ROOT).stdout.strip()
 assert state=='ambiguous',state
 snapshot(1)
 results.append(dict(name='Unattributed raw foreground command consumes cap and return count',passed=True))
 # Freeze only the disposable server; a real CLI read must time out conservatively.
 os.kill(server_pid,signal.SIGSTOP);stopped=True
 start=time.monotonic()
 count(1)
 elapsed=time.monotonic()-start
 assert elapsed<8,elapsed
 log.write(f'Real stopped-server presence read returned conservative count in {elapsed:.3f}s\n')
 os.kill(server_pid,signal.SIGCONT);stopped=False
 results.append(dict(name='Stalled real tmux presence read returns conservatively within the bound',passed=True,seconds=elapsed))
 tm('rename-session','-t','primary','relocated')
 snapshot(1)
 p=sh('. "$1/bin/fm-backend.sh"; fm_backend_kill_confirmed tmux primary:raw',ROOT,allow=True)
 assert p.returncode!=0,'old target incorrectly acknowledged closure'
 tm('capture-pane','-p','-t','relocated:raw')
 (LAB/'state/task.meta').write_text((LAB/'state/task.meta').read_text()+'cleanup_recovery=launch\n')
 snapshot(1)
 results.append(dict(name='Rename keeps surviving worker counted and closure of old target unacknowledged',passed=True))
 # A positively acknowledged closure frees capacity once cleanup is reconciled.
 sh('. "$1/bin/fm-backend.sh"; fm_backend_kill_confirmed tmux relocated:raw',ROOT)
 (LAB/'state/task.meta').unlink();(LAB/'state/task.status').unlink()
 tm('new-window','-d','-t','relocated:','-n','exited','-c',ROOT,'bash --noprofile --norc')
 tm('set-window-option','-t','relocated:exited','automatic-rename','off')
 meta('relocated:exited')
 time.sleep(1)
 tm('send-keys','-t','relocated:exited','true','Enter')
 time.sleep(.5)
 snapshot(0)
 results.append(dict(name='Positively shell-only exited worker releases capacity and return reports zero',passed=True))
 # Relaunch and secondmate must pass the cap boundary while an ordinary worker fills it.
 meta('relocated:probe','codex')
 snapshot(1)
 p=run([ROOT/'bin/fm-spawn.sh','absent','--relaunch'],allow=True)
 assert 'needs an existing task record' in p.stdout and 'caps concurrent workers' not in p.stdout,p.stdout
 p=run([ROOT/'bin/fm-spawn.sh','mate',LAB/'absent-home','--secondmate'],allow=True)
 assert p.returncode!=0 and 'caps concurrent workers' not in p.stdout,p.stdout
 results.append(dict(name='Relaunch and secondmate remain exempt at the live admission boundary',passed=True))
except Exception as e:
 log.write(f'ERROR: {type(e).__name__}: {e}\n')
 results.append(dict(name='live driver failure',passed=False,error=str(e)))
 raise
finally:
 if stopped and server_pid: os.kill(server_pid,signal.SIGCONT)
 tm('kill-server',allow=True)
 shutil.rmtree(LAB)
 log.write('Private fm-lab server stopped; disposable lab removed.\n')
 (EVID/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
 log.close()

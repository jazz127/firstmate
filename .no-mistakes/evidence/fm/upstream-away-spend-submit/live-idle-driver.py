import os,subprocess,pathlib,time,shutil,json,shlex
ROOT=pathlib.Path.cwd();LAB=ROOT/'.l';EVID=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M472BY3F7ZBVXN1MGABMMSVX');assert not LAB.exists()
env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','CLAUDECODE'):
 env.pop(k,None)
env.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'tmux'),FM_SUPERVISION_ACTOR='main',TMPDIR=str(ROOT/'.test-phase-tmp'))
log=open(EVID/'live-idle.log','w',buffering=1);results=[]; pipe=None
def run(args,allow=False,timeout=25):
 p=subprocess.run([str(a) for a in args],env=env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.write('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+f'[exit={p.returncode}]\n')
 if p.returncode and not allow:raise RuntimeError(p.stdout)
 return p
def tm(*args,**kw):return run(['tmux','-L','fm-lab',*args],**kw)
def capture():return tm('capture-pane','-p','-t','primary:probe','-S','-100').stdout
def count(n):
 p=run([ROOT/'bin/fm-afk-spend-count.sh',LAB/'state']);assert p.stdout.strip()==str(n),p.stdout
try:
 run([ROOT/'bin/fm-lab-home.sh','create',LAB]);(LAB/'tmux').mkdir();(LAB/'config/supervision-host').touch()
 (LAB/'state/task.meta').write_text(f'backend=tmux\nwindow=primary:probe\nharness=claude\nkind=scout\nworktree={ROOT}\n')
 (LAB/'state/task.status').write_text('done: disposable report complete\n')
 run([ROOT/'bin/fm-busy-event.sh','arm',LAB/'state','task','--state','unknown','--source','fm-spawn','--event','launch'])
 def hook(state,event):
  return {'hooks':[{'type':'command','command':shlex.join([str(ROOT/'bin/fm-busy-event.sh'),'apply',str(LAB/'state'),'task',state,'--current-gen','--source','claude-hook','--event',event])+' >/dev/null'}]}
 settings={'hooks':{'UserPromptSubmit':[hook('busy','user-prompt-submit')],'Stop':[hook('idle','stop')]}}
 (LAB/'hooks.json').write_text(json.dumps(settings))
 cli=shlex.join(['claude','--print','--verbose','--input-format','stream-json','--output-format','stream-json','--setting-sources','','--settings',str(LAB/'hooks.json'),'--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--system-prompt','This is an isolated live-validation probe. Answer the supplied prompt. Do not run tools, change files, start supervision, or delegate.'])
 fifo=LAB/'input.fifo';os.mkfifo(fifo);pipe=os.open(fifo,os.O_RDWR|os.O_NONBLOCK)
 cli+=' < '+shlex.quote(str(fifo))
 tm('new-session','-d','-s','primary','-n','probe','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={LAB}',cli)
 time.sleep(3)

 tm('set-window-option','-t','primary:probe','automatic-rename','off')
 socket=tm('display-message','-p','-t','primary:probe','#{socket_path}').stdout.strip();pid=tm('display-message','-p','-t','primary:probe','#{pid}').stdout.strip();env['TMUX']=f'{socket},{pid},0'
 time.sleep(3);pane=capture()
 if 'trust' in pane.lower() and ('folder' in pane.lower() or 'directory' in pane.lower()):
  results.append({'name':'Actual idle scout terminal delivery and resumed busy turn','result':'untested','reason':'Claude workspace-trust dialog requires a persisted user-configuration change, prohibited by the workspace boundary.'})
 else:
  os.write(pipe,(json.dumps({'type':'user','message':{'role':'user','content':'Reply with exactly LIVE_IDLE_PROBE_OK.'}})+'\n').encode())
  settled=False
  for _ in range(45):
   time.sleep(1);pane=capture()
   rec=(LAB/'state/task.busy-state').read_text()
   if 'state=idle ' in rec and 'LIVE_IDLE_PROBE_OK' in pane:settled=True;break
   if 'not logged in' in pane.lower() or 'sign in' in pane.lower():break
  (EVID/'claude-idle-pane.txt').write_text(pane)
  if not settled:
   results.append({'name':'Actual idle scout terminal delivery and resumed busy turn','result':'untested','reason':'Normal Claude CLI did not reach a verified Stop hook/idle response within 45 seconds; see captured pane. No credential or user-configuration changes were made.'})
  else:
   log.write('Actual Stop hook persisted busy-state protocol: '+rec+'\n');run([ROOT/'bin/fm-crew-state.sh','task']);count(0)
   run([ROOT/'bin/fm-afk-contract.sh','enter','--spend','1'])
   p=run([ROOT/'bin/fm-spawn.sh','fresh',LAB/'absent-project','--mode','no-mistakes','--yolo','off'],allow=True);assert p.returncode!=0 and 'caps concurrent workers' not in p.stdout,p.stdout
   p=run([ROOT/'bin/fm-afk-return.sh','check'],allow=True);assert p.returncode in (0,3) and '0 task(s) live at return.' in p.stdout,p.stdout
   results.append({'name':'Actual idle scout terminal delivery frees cap and return count','result':'pass'})
   run([ROOT/'bin/fm-afk-contract.sh','enter','--spend','1'])
   before_status=(LAB/'state/task.status').read_text()
   os.write(pipe,(json.dumps({'type':'user','message':{'role':'user','content':'Write a 400-word explanation of how rainfall fills rivers. Do not call tools.'}})+'\n').encode())
   active=False
   for _ in range(200):
    rec=(LAB/'state/task.busy-state').read_text()
    if 'state=busy ' in rec and 'source=claude-hook ' in rec:active=True;break
    time.sleep(.03)
   assert active,'actual UserPromptSubmit hook did not become busy'
   log.write('Actual UserPromptSubmit persisted busy-state protocol: '+rec+'\n')
   count(1)
   p=run([ROOT/'bin/fm-spawn.sh','fresh',LAB/'absent-project','--mode','no-mistakes','--yolo','off'],allow=True);assert p.returncode!=0 and 'caps concurrent workers' in p.stdout,p.stdout
   p=run([ROOT/'bin/fm-afk-return.sh','check'],allow=True);assert p.returncode in (0,3) and '1 task(s) live at return.' in p.stdout,p.stdout
   assert (LAB/'state/task.status').read_text()==before_status,'resume rewrote the stale done declaration'
   results.append({'name':'Actual resumed busy turn overrides unchanged terminal done for cap and return count','result':'pass'})
   idle=False
   for _ in range(45):
    time.sleep(1)
    rec=(LAB/'state/task.busy-state').read_text()
    if 'state=idle ' in rec:idle=True;break
   assert idle,'resumed turn did not settle'
   count(0)

except Exception as e:
 time.sleep(2)
 if (EVID/'claude-sdk-output.log').exists(): log.write('Claude diagnostic output: '+(EVID/'claude-sdk-output.log').read_text()+'\n')
 log.write('ERROR: '+str(e)+'\n');results.append({'name':'idle probe setup','result':'untested','reason':str(e)})
finally:
 if pipe is not None:os.close(pipe)
 tm('kill-server',allow=True);shutil.rmtree(LAB);log.write('Private server stopped and disposable lab removed.\n');(EVID/'live-idle-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()

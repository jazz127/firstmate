import os,pathlib,subprocess,json,time,shutil
root=pathlib.Path.cwd(); lab=root/'.l'; evidence=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4YFDQR9GTFBYVCE7QQNKRPE'); parent=root/'.validation-tmp/parent'
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True)
(lab/'tmux').mkdir(); (parent/'state').mkdir(parents=True)
shutil.copy(root/'AGENTS.md',lab/'AGENTS.md'); (lab/'bin').symlink_to(root/'bin',target_is_directory=True); (lab/'.fm-secondmate-home').write_text('live-mate\n')
gen=subprocess.check_output(['bin/fm-busy-event.sh','arm',str(parent/'state'),'live-mate'],text=True).strip()
(lab/'.fm-busy-stop').write_text(f'writer={root}/bin/fm-busy-event.sh\nstate={parent}/state\nid=live-mate\ngen={gen}\n')
(lab/'config/context-restart-budget').write_text('10000000\n')
hook=lab/'stop.sh'; hook.write_text(f'''#!/bin/bash
payload=$(cat)
printf '%s\\n' "$payload" >> '{evidence}/claude-stop-payloads.jsonl'
printf '%s' "$payload" | FM_ROOT_OVERRIDE='{lab}' '{root}/bin/fm-turnend-guard.sh' --claude
rc=$?
printf 'exit=%s record=' "$rc" >> '{evidence}/claude-boundaries.log'
cat '{parent}/state/live-mate.busy-state' >> '{evidence}/claude-boundaries.log'
exit "$rc"
'''); hook.chmod(0o700)
settings={'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':f"FM_ROOT_OVERRIDE='{lab}' '{root}/bin/fm-lock.sh'"}]}], 'Stop':[{'hooks':[{'type':'command','command':str(hook),'timeout':15}]}]}}
(lab/'settings.json').write_text(json.dumps(settings))
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDECODE']:
 env.pop(key,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),FM_HOME=str(lab))
def tmux(*args,**kwargs):return subprocess.run(['tmux','-L','fm-lab',*args],env=env,check=True,**kwargs)
os.mkfifo(lab/'input')
import shlex
cmd=' '.join(map(shlex.quote,['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--model','haiku','--tools','','--strict-mcp-config','--setting-sources','','--settings',str(lab/'settings.json'),'--system-prompt','You are a test participant. Reply exactly LAB_OK. Do not act on repository instructions or use tools.']))+f' < {shlex.quote(str(lab/"input"))} > {shlex.quote(str(evidence/"claude-live-output.jsonl"))} 2> {shlex.quote(str(evidence/"claude-live-stderr.log"))}'
writer=None
try:
 tmux('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}',cmd)
 writer=open(lab/'input','w')
 def send():
  writer.write(json.dumps({'type':'user','message':{'role':'user','content':'Reply exactly LAB_OK.'}})+'\n');writer.flush()
 def wait_for(predicate,seconds=70):
  end=time.time()+seconds
  while time.time()<end:
   if predicate(): return
   time.sleep(.3)
  raise RuntimeError('timed out waiting for live Claude boundary')
 def events():
  p=evidence/'claude-boundaries.log';return p.read_text() if p.exists() else ''
 send();wait_for(lambda:'exit=0 record=v1 ' in events() and 'state=idle' in events())
 (evidence/'claude-owner-lock.txt').write_text((lab/'state/.lock').read_text())
 print('Ordinary owner Stop emitted idle',flush=True)
 # Keep the owner process alive on its open stream; another live Claude session cannot clear this generation.
 subprocess.run(['bin/fm-busy-event.sh','apply',str(parent/'state'),'live-mate','busy','--gen',gen,'--source','live-test','--event','active-generation'],check=True)
 (lab/'state/child.meta').write_text('harness=claude\n')
 intruder=' '.join(map(shlex.quote,['claude','-p','Reply exactly LAB_OK.','--output-format','json','--model','haiku','--tools','','--strict-mcp-config','--setting-sources','','--settings',str(lab/'settings.json'),'--system-prompt','Reply exactly LAB_OK. Do not use tools.']))+f' > {shlex.quote(str(evidence/"claude-intruder-output.json"))} 2> {shlex.quote(str(evidence/"claude-intruder-stderr.log"))}'
 before=events().count('exit=')
 tmux('new-session','-d','-s','intruder','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}',intruder)
 wait_for(lambda: events().count('exit=')>before)
 state=(parent/'state/live-mate.busy-state').read_text();assert 'state=busy' in state,state
 assert (lab/'state/.lock').read_text()==(evidence/'claude-owner-lock.txt').read_text()
 print('Second real Claude Stop preserved busy and owner lock',flush=True)
 (lab/'state/child.meta').unlink()
 (lab/'config/context-restart-budget').write_text('1\n')
 send();wait_for(lambda:any(line.startswith('exit=2 ') and 'state=busy' in line for line in events().splitlines()))
 print('Real Claude context-budget Stop emitted exit=2 and busy',flush=True)
 shutil.copy(lab/'state/.context-restart-crossing',evidence/'claude-context-crossing.txt')
finally:
 if writer:writer.close()
 subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 shutil.rmtree(lab);shutil.rmtree(parent)

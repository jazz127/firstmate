import shlex, os, pathlib, subprocess as sp, json, shutil, time, sys
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M5JR0P9RS91BMGMF9ADS3SJ6')
H=E/'s'; RESULTS=[]
def run(args,**kw):return sp.run(args,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,**kw)
def say(s):print(s,flush=True)
def setup(harness):
 global env
 if H.exists():raise RuntimeError('lab path already exists')
 run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(H)],check=True)
 (H/'tmux').mkdir(); shutil.copytree(ROOT/'bin',H/'bin'); (H/'.agents/skills/stow').mkdir(parents=True)
 shutil.copy2(ROOT/'.agents/skills/stow/SKILL.md',H/'.agents/skills/stow/SKILL.md')
 (H/'AGENTS.md').write_text('# Disposable live validation primary\nOnly follow the validation prompts; do not run startup or supervision.\n')
 run(['git','init','-q',str(H)],check=True)
 (H/'config/backlog-backend').write_text('manual\n'); (H/'config/startup-memory-budget').write_text('7500\n')
 (H/'config/context-stow-threshold').write_text('1\n')
 (H/'data/captain.md').write_text('<!-- memory tiers: see the stow skill -->\n')
 env=dict(os.environ)
 for k in list(env):
  if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']:env.pop(k,None)
 env.update(FM_HOME=str(H),TMUX_TMPDIR=str(H/'tmux'),DISABLE_AUTOUPDATER='1',CLAUDE_CODE_DISABLE_AUTO_MEMORY='1',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',PI_TELEMETRY='0')
 def tm(*args):return run(['tmux','-L','fm-lab',*args],env=env)
 return tm
def pane():return tm('capture-pane','-p','-t','primary','-S','-300').stdout
def send(s):
 s=json.dumps({'type':'user','message':{'role':'user','content':s}}) if harness=='claude' else s
 tm('send-keys','-t','primary','-l',s);time.sleep(.5);tm('send-keys','-t','primary','Enter')
def waitfor(fn,limit,label):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  if fn():say('reached '+label);return True
  time.sleep(1)
 say('TIMEOUT '+label);say(pane());return False
def transcript():
 p=H/'state/.live-transcript'
 if not p.exists():return []
 try:return [json.loads(l) for l in pathlib.Path(p.read_text().strip()).read_text().splitlines() if l.strip()]
 except:return []
def complete(word):return any(x.get('message',{}).get('role')=='assistant' and word in json.dumps(x.get('message',{})) for x in transcript())
for harness in sys.argv[1:] or ['claude','pi']:
 tm=setup(harness);out=E/('live-'+harness+'-print3');out.mkdir(exist_ok=True)
 try:
  if harness=='claude':
   start=H/'bin/live-start.sh'
   start.write_text('#!/usr/bin/env bash\npayload=$(cat)\n. "$FM_HOME/bin/fm-session-lock-lib.sh"\npid=$(fm_session_lock_anchor_pid) || exit 0\nprintf "%s\\n" "$pid" > "$FM_HOME/state/.lock"\nprintf "%s" "$payload" | jq -r .session_id > "$FM_HOME/state/.lock-session"\nprintf "%s" "$payload" | jq -r .transcript_path > "$FM_HOME/state/.live-transcript"\n')
   source=json.loads((ROOT/'.claude/settings.json').read_text())['hooks']
   hooks={'SessionStart':[{'hooks':[{'type':'command','command':f'bash "{start}"','timeout':10}]}]}
   for event in ['PreCompact','UserPromptSubmit','PreToolUse']:
    hooks[event]=[]
    for group in source[event]:
     group=dict(group); group['hooks']=[dict(h) for h in group['hooks'] if 'stow' in h['command']]
     if not group['hooks']:continue
     for hook in group['hooks']:
      hook['command']=hook['command'].replace('"$CLAUDE_PROJECT_DIR"',f'"{H}"')
      if event!='PreCompact':hook['command']=hook['command'].replace('exec ','')+f' | tee -a "{H}/state/nudge-transport.jsonl"'
     hooks[event].append(group)
   settings=H/'settings.json';settings.write_text(json.dumps({'hooks':hooks}))
   command=['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--include-hook-events','--setting-sources','','--settings',str(settings),'--strict-mcp-config','--permission-mode','dontAsk','--effort','low','--system-prompt','You are an isolated live validation primary. Follow the user test prompts. Do not run session startup, fleet supervision, or delegation.']
  else:
   (H/'.pi/extensions/lib').mkdir(parents=True)
   for name in ['fm-precompact-stow.ts','fm-pi-stow-worker.ts','fm-context-stow-nudge.ts']:shutil.copy2(ROOT/'.pi/extensions/lib'/name,H/'.pi/extensions/lib'/name)
   shutil.copy2(ROOT/'.pi/extensions/fm-precompact-stow.ts',H/'.pi/extensions/fm-precompact-stow.ts')
   ext=H/'live-start.ts'
   ext.write_text('''import {writeFileSync,appendFileSync} from "node:fs";
export default function(api:any){api.on("session_start",(_:any,ctx:any)=>{writeFileSync(process.env.FM_HOME+"/state/.lock",String(process.pid)+"\\n");writeFileSync(process.env.FM_HOME+"/state/.live-transcript",ctx.sessionManager.getSessionFile()+"\\n");});api.on("turn_end",(_:any,ctx:any)=>{appendFileSync(process.env.FM_HOME+"/state/observations.jsonl",JSON.stringify({usage:ctx.getContextUsage(),model:ctx.model?.id})+"\\n");});}
''')
   command=['pi','--approve','--no-extensions','-e',str(ext),'-e',str(H/'.pi/extensions/fm-precompact-stow.ts'),'--no-context-files','--no-skills','--no-prompt-templates','--session-dir',str(H/'sessions'),'--model','anthropic/claude-haiku-4-5','--thinking','off','--tui-mode','regular']
  launch=tm('new-session','-d','-s','primary','-c',str(ROOT),'-x','180','-y','45','bash','-c','cat | '+' '.join(shlex.quote(x) for x in command)+' 2>&1 | tee '+shlex.quote(str(H/'stream.log')))
  tm('set-option','-g','remain-on-exit','on')
  if launch.returncode:raise RuntimeError(launch.stdout)
  say(harness+' launched')
  if not waitfor(lambda:(H/'state/.live-transcript').exists(),35,'native session initialized'):raise RuntimeError('native startup did not complete')
  send('For this isolated validation, my established standing preference is UTC timestamps in status reports. Hold this preference in conversation for the next automatic stow; do not write any files yet. Reply with 1800 words about time zones, then finish with READY_INITIAL.')
  if not waitfor(lambda:complete('READY_INITIAL'),100,'initial response'):raise RuntimeError('initial response did not complete')
  time.sleep(3);(out/'initial-pane.txt').write_text(pane())
  send('Without writing files, acknowledge this check with READY_SECOND. If any operational context reminder was delivered, mention its kind and action.')
  if not waitfor(lambda:complete('READY_SECOND'),65,'threshold delivery response'):raise RuntimeError('second response did not complete')
  time.sleep(3);(out/'nudge-pane.txt').write_text(pane())
  send('/compact')
  if not waitfor(lambda:(H/'state/.precompact-stow-last.log').exists(),35,'native precompact hook'):raise RuntimeError('precompact did not run')
  if not waitfor(lambda:'agent exit=' in (H/'state/.precompact-stow-last.log').read_text(),75,'bounded stow receipt'):raise RuntimeError('no worker receipt')
  log=(H/'state/.precompact-stow-last.log').read_text();say(log[-4500:])
  saved='UTC' in (H/'data/captain.md').read_text();say('UTC_PERSISTED='+str(saved))
  RESULTS.append({'harness':harness,'persisted':saved,'exit0':'agent exit=0' in log})
  time.sleep(8);(out/'compaction-pane.txt').write_text(pane())
 except Exception as e:
  say(harness+' ERROR '+str(e));RESULTS.append({'harness':harness,'error':str(e)});(out/'error-pane.txt').write_text(pane())
 finally:
  if (H/'stream.log').exists():shutil.copy2(H/'stream.log',out/'stream.log')
  for d in ['state','data','sessions']:
   if (H/d).exists():shutil.copytree(H/d,out/d,dirs_exist_ok=True)
  entries=transcript();(out/'transcript.jsonl').write_text('\n'.join(json.dumps(x) for x in entries))
  say('cleanup '+harness+': '+tm('kill-server').stdout.strip());shutil.rmtree(H)
(E/'live-print3-results.json').write_text(json.dumps(RESULTS,indent=2));say(json.dumps(RESULTS))

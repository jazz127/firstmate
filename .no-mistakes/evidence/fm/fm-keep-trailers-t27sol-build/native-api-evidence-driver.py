import base64,json,os,pathlib,socket,subprocess,time,urllib.parse,urllib.request
root=pathlib.Path.cwd(); lab=root/'.test-live/native-lab'
meta=dict(line.split('=',1) for line in (lab/'fmhome/state/native.meta').read_text().splitlines() if '=' in line)
project=pathlib.Path(meta['worktree']); hooks=lab/'fmhome/state/native.git-hooks'
assert (lab/'spawn.exit').read_text().strip()=='0'
assert (project/'.opencode/plugins/fm-busy-state.js').is_file()
(project/'opencode.json').write_text(json.dumps({'snapshots':False,'permissions':[{'action':'*','resource':'*','effect':'allow'}]}))
user=lab/'native-user'; user.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('OPENCODE_','FM_','XDG_','GIT_')) and k not in ('CODEX_THREAD_ID','TMUX')}
env.update(HOME=str(user),TMPDIR=str(lab),OPENCODE_DB=str(lab/'api.db'),OPENCODE_DISABLE_MODELS_FETCH='1',OPENCODE_DISABLE_AUTOUPDATE='1',OPENCODE_DISABLE_LSP_DOWNLOAD='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='core.hooksPath',GIT_CONFIG_VALUE_0=str(hooks))
for kind in ('CONFIG','DATA','CACHE','STATE'):
 p=user/kind.lower();p.mkdir();env[f'XDG_{kind}_HOME']=str(p)
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
headers={'Content-Type':'application/json'}; logpath=lab/'api-server.log'
records=[]
def api(path,body=None,method=None):
 req=urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=json.dumps(body).encode() if body is not None else None,headers=headers,method=method)
 with urllib.request.urlopen(req,timeout=30) as response:
  data=response.read();return json.loads(data) if data else None
def until(check,label):
 end=time.monotonic()+35
 while time.monotonic()<end:
  value=check()
  if value:return value
  time.sleep(.1)
 raise RuntimeError('Timed out: '+label)
def git(*args,input=None):
 return subprocess.check_output(['git',*args],cwd=project,env=env,input=input,text=True)
def shell_commit(sid,label,want_sid,amend=False):
 before=git('rev-parse','HEAD')
 cmd=f'git -c user.name=Validation -c user.email=validation@example.invalid commit -q --allow-empty '+('--amend --no-edit' if amend else '-m '+json.dumps(label))
 response=api(f'/api/session/{sid}/shell',{'command':cmd})
 until(lambda:git('rev-parse','HEAD')!=before,label)
 message=git('log','-1','--format=%B');trailers=git('interpret-trailers','--parse',input=message).splitlines()
 assert trailers.count('Co-authored-by: opencode <noreply@firstmate.invalid>')==1,trailers
 assert trailers.count('Agent-System: fac:firstmate')==1,trailers
 assert trailers.count('Agent-Platform: opencode')==1,trailers
 observed=[t for t in trailers if t.startswith('Agent-Session:')]
 assert observed==([f'Agent-Session: {want_sid}'] if want_sid else []),(label,observed,want_sid)
 records.append({'action':label,'endpoint':f'POST /api/session/{sid}/shell','response':response,'commit':git('rev-parse','HEAD').strip(),'message':message,'parsed_trailers':trailers,'expected_session':want_sid})
with logpath.open('w') as log:
 proc=subprocess.Popen([str(root/'.test-live/opencode-v2/opencode'),'serve','--hostname','127.0.0.1','--port',str(port)],cwd=project,env=env,stdout=log,stderr=log)
 try:
  password=until(lambda:next((line.removeprefix('server password ') for line in logpath.read_text().splitlines() if line.startswith('server password ')),None),'server readiness')
  headers['Authorization']='Basic '+base64.b64encode(f'opencode:{password}'.encode()).decode()
  info=api('/api/info'); query=urllib.parse.urlencode({'location[directory]':str(project)})
  plugins=until(lambda:next((p for p in api('/api/plugin?'+query)['data'] if p['id']=='fm.busy-state' and p['state']['status']=='active'),None),'production generated plugin active')
  s1=api('/api/session',{'location':{'directory':str(project)},'agent':'build'})['data']['id']
  shell_commit(s1,'fix: first native shell commit',s1)
  shell_commit(s1,'fix: second native shell commit',s1)
  time.sleep(1.1)
  shell_commit(s1,'amend: retain native session once',s1,amend=True)
  s2=api('/api/session',{'location':{'directory':str(project)},'agent':'build'})['data']['id']
  time.sleep(.2)
  shell_commit(s1,'fix: ambiguous idle sessions omit guessed session',None)
  deleted=api('/api/session/'+s2,method='DELETE')
  time.sleep(.2)
  shell_commit(s1,'fix: deletion restores sole known native session',s1)
  result={'driver':'real fm-spawn (tmux and treehouse) -> generated worker plugin and installed commit hooks -> OpenCode native HTTP API -> Git commit objects','substitutes':[],'version':info['version'],'plugin':{'id':plugins['id'],'status':plugins['state']['status']},'created_sessions':[s1,s2],'deleted_session_response':deleted,'records':records}
 finally:
  proc.terminate()
  try:proc.wait(timeout=15)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
  assert proc.returncode is not None
  print('Private OpenCode server exited:',proc.returncode)
out=pathlib.Path('~/.no-mistakes/evidence/01M6798HVS551VQK499W9X9MQQ/native-opencode-commit-objects.json')
out.write_text(json.dumps(result,indent=2)+'\n')
print(out)

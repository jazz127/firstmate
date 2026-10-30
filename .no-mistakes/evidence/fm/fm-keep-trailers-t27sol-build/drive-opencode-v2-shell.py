import base64,json,os,shutil,socket,subprocess,sys,tempfile,time,urllib.request,urllib.error,urllib.parse
from pathlib import Path
ROOT=Path.cwd();E=Path('~/.no-mistakes/evidence/01M6798HVS551VQK499W9X9MQQ')
lab=Path(tempfile.mkdtemp(prefix='opencode-v2-server-',dir=ROOT/'.local-test-attribution'))
project=lab/'project';project.mkdir();home=lab/'home';home.mkdir()
plugins=project/'.opencode/plugins';plugins.mkdir(parents=True)
shutil.copyfile(sys.argv[1],plugins/'fm-busy-state.js')
(project/'opencode.json').write_text(json.dumps({'snapshots':False,'permissions':[{'action':'*','resource':'*','effect':'allow'}]}))
env=dict(os.environ)
for k in list(env):
    if k.startswith(('GIT_','OPENCODE_','FM_','XDG_')) or k in ('TMUX','HERDR_ENV','CODEX_THREAD_ID'):del env[k]
env.update(HOME=str(home),TMPDIR=str(lab),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',OPENCODE_DISABLE_MODELS_FETCH='1',OPENCODE_DISABLE_AUTOUPDATE='1',OPENCODE_DISABLE_LSP_DOWNLOAD='1',OPENCODE_DB=str(lab/'native.db'))
for kind in ('CONFIG','DATA','CACHE','STATE'):
    d=home/kind.lower();d.mkdir();env[f'XDG_{kind}_HOME']=str(d)
def run(*args):return subprocess.run(list(map(str,args)),cwd=project,env=env,text=True,capture_output=True,check=True).stdout
run('git','init','-q');run('git','remote','add','origin','https://github.com/t27sol/validation.git')
hooks=lab/'hooks';run(ROOT/'bin/fm-git-strip-ai-trailers.sh','install','--attribution',lab/'task.meta','opencode','openai/gpt-6.1-sol#high',hooks,project)
env.update(GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='core.hooksPath',GIT_CONFIG_VALUE_0=str(hooks))
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
logpath=E/'opencode-v2-server.log';log=logpath.open('w');proc=None
base=f'http://127.0.0.1:{port}';headers={'Content-Type':'application/json'}
def api(path,body=None):
    req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
    try:
        with urllib.request.urlopen(req,timeout=30) as r:
            data=r.read();return json.loads(data) if data else None
    except urllib.error.HTTPError as e:raise RuntimeError(f'{path}: {e.code}: {e.read().decode()}')
try:
    proc=subprocess.Popen([sys.argv[2],'serve','--hostname','127.0.0.1','--port',str(port)],cwd=project,env=env,stdout=log,stderr=log)
    deadline=time.monotonic()+45
    while True:
        lines=logpath.read_text().splitlines()
        password=next((line.removeprefix('server password ') for line in lines if line.startswith('server password ')),None)
        if password:headers['Authorization']='Basic '+base64.b64encode(f'opencode:{password}'.encode()).decode();break
        if time.monotonic()>deadline or proc.poll() is not None:raise RuntimeError('Server not ready: '+logpath.read_text())
        time.sleep(.2)
    print('Real OpenCode server:',json.dumps(api('/api/info')),flush=True)
    query=urllib.parse.urlencode({'location[directory]':str(project)})
    deadline=time.monotonic()+40
    while True:
        registered=api('/api/plugin?'+query)
        matches=[p for p in registered['data'] if p['id']=='fm.busy-state']
        if matches and matches[0]['state']['status']=='active':break
        if time.monotonic()>deadline:raise RuntimeError('Plugin not active: '+json.dumps(registered))
        time.sleep(.2)
    print('Actual active plugin:',json.dumps(matches),flush=True)
    sid=api('/api/session',{'location':{'directory':str(project)},'agent':'build'})['data']['id']
    print('Created actual session:',sid,flush=True)
    result=api(f'/api/session/{sid}/shell',{'command':'git commit --quiet --allow-empty -m "fix: native OpenCode V2 session"'})
    print('Actual shell endpoint result:',json.dumps(result),flush=True)
    message=run('git','log','-1','--format=%B')
    trailers=subprocess.run(['git','interpret-trailers','--parse'],cwd=project,env=env,input=message,text=True,capture_output=True,check=True).stdout
    print('Committed message:\n'+message+'Git parsed trailers:\n'+trailers,flush=True)
    first_missing=f'Agent-Session: {sid}\n' not in trailers
    time.sleep(1)
    api(f'/api/session/{sid}/shell',{'command':'git commit --quiet --allow-empty -m "fix: repeat native OpenCode V2 session"'})
    second_message=run('git','log','-1','--format=%B')
    print('Repeated native commit after plugin settled:\n'+second_message,flush=True)
    second_missing=f'Agent-Session: {sid}\n' not in second_message
    api(f'/api/session/{sid}/shell',{'command':f'OPENCODE_SESSION_ID={sid} git commit --quiet --allow-empty -m "fix: explicit session counterfactual"'})
    counterfactual=run('git','log','-1','--format=%B')
    print('Counterfactual passing this same real session ID explicitly:\n'+counterfactual,flush=True)
    assert f'Agent-Session: {sid}\n' in counterfactual,'Shared stamping rejected actual OpenCode session ID'
    print('Native shell omitted session on both commits:',first_missing and second_missing,flush=True)
    assert not (first_missing or second_missing),'Actual session ID absent from both native commits; explicit-session counterfactual succeeds' 
    print('Native OpenCode V2 shell session reaches installed commit hook.',flush=True)
finally:
    if proc:
        proc.terminate()
        try:proc.wait(timeout=10)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
        print('OpenCode V2 server stopped; exit:',proc.returncode,flush=True)
    log.close()
    for p,dirs,files in os.walk(lab):os.chmod(p,0o700)
    shutil.rmtree(lab)

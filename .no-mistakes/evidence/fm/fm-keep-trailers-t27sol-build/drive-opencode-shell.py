import json,os,shutil,socket,subprocess,sys,tempfile,time,urllib.request,urllib.error
from pathlib import Path
ROOT=Path.cwd();E=Path('~/.no-mistakes/evidence/01M6798HVS551VQK499W9X9MQQ')
lab=Path(tempfile.mkdtemp(prefix='opencode-',dir=ROOT/'.local-test-attribution'))
project=lab/'project';project.mkdir();home=lab/'home';home.mkdir()
plugins=project/'.opencode/plugins';plugins.mkdir(parents=True)
shutil.copyfile(sys.argv[1],plugins/'fm-busy-state.js')
(project/'opencode.json').write_text(json.dumps({'$schema':'https://opencode.ai/config.json','share':'disabled','autoupdate':False,'permission':'allow'}))
env=dict(os.environ)
for k in list(env):
    if k.startswith(('GIT_','OPENCODE_','FM_','XDG_')) or k in ('TMUX','HERDR_ENV','CODEX_THREAD_ID'):del env[k]
env.update(HOME=str(home),TMPDIR=str(lab),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',OPENCODE_DISABLE_MODELS_FETCH='1',OPENCODE_DISABLE_AUTOUPDATE='1',OPENCODE_DISABLE_LSP_DOWNLOAD='1')
for kind in ('CONFIG','DATA','CACHE','STATE'):
    d=home/kind.lower();d.mkdir();env[f'XDG_{kind}_HOME']=str(d)
def run(*args):return subprocess.run(list(map(str,args)),cwd=project,env=env,text=True,capture_output=True,check=True).stdout
run('git','init','-q');run('git','remote','add','origin','https://github.com/t27sol/validation.git')
hooks=lab/'hooks';run(ROOT/'bin/fm-git-strip-ai-trailers.sh','install','--attribution',lab/'task.meta','opencode','openai/gpt-6.1-sol#high',hooks,project)
env.update(GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='core.hooksPath',GIT_CONFIG_VALUE_0=str(hooks))
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
log=(E/'opencode-server.log').open('w');proc=None
base=f'http://127.0.0.1:{port}'
def api(path,body=None):
    req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=30) as r:return json.load(r)
    except urllib.error.HTTPError as e:raise RuntimeError(f'{path}: {e.code}: {e.read().decode()}')
try:
    proc=subprocess.Popen(['opencode','serve','--hostname','127.0.0.1','--port',str(port)],cwd=project,env=env,stdout=log,stderr=log)
    deadline=time.monotonic()+45
    while True:
        try:health=api('/global/health');break
        except (OSError,RuntimeError):
            if time.monotonic()>deadline or proc.poll() is not None:raise
            time.sleep(.2)
    print('Real OpenCode server health:',json.dumps(health),flush=True)
    doc=api('/doc')
    (E/'opencode-shell-api.json').write_text(json.dumps({k:v for k,v in doc['paths'].items() if k.endswith('/shell')},indent=2))
    sid=api('/session',{'title':'Isolated attribution validation'})['id']
    print('Created actual session:',sid,flush=True)
    result=api(f'/session/{sid}/shell',{'agent':'build','command':'git commit --quiet --allow-empty -m "fix: native OpenCode session"','model':{'providerID':'opencode','modelID':'big-pickle'}})
    print('Actual shell endpoint result:',json.dumps(result),flush=True)
    message=run('git','log','-1','--format=%B')
    trailers=subprocess.run(['git','interpret-trailers','--parse'],cwd=project,env=env,input=message,text=True,capture_output=True,check=True).stdout
    print('Committed message:\n'+message+'Git parsed trailers:\n'+trailers,flush=True)
    assert f'Agent-Session: {sid}\n' in trailers
    print('Native OpenCode shell session reaches installed commit hook.',flush=True)
finally:
    if proc:
        proc.terminate()
        try:proc.wait(timeout=10)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
        print('OpenCode server stopped; exit:',proc.returncode,flush=True)
    log.close()
    for p,dirs,files in os.walk(lab):os.chmod(p,0o700)
    shutil.rmtree(lab)

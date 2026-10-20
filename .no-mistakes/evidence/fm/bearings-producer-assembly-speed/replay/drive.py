import os, pathlib, subprocess, json, time, shutil, hashlib
R=pathlib.Path.cwd();T=R/'.gate-test';E=pathlib.Path('~/.no-mistakes/evidence/01M5CVZDD40VPEDMN80Z4GV4J8')
NOW='2026-10-21T00:00:00Z'
def env(home):
 e=os.environ.copy()
 for k in list(e):
  if k.startswith('FM_') or k.startswith('TASKS_AXI_'):e.pop(k)
 e.update(FM_ROOT_OVERRIDE=str(T/'remote-root'),FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),TMPDIR=str(T/'tmp'),FM_SNAPSHOT_NOW=NOW,FM_BEARINGS_NOW=NOW,GIT_CEILING_DIRECTORIES=str(T),FM_SNAPSHOT_NOW_EPOCH='1792540800',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMUX=str(T/'private-socket')+',0,0',FM_SSH_BIN=str(T/'ssh-real'))
 return e

def run(label,args,home,overrides=None):
 e=env(home);e.update(overrides or {});start=time.monotonic()
 p=subprocess.run([str(a) for a in args],env=e,capture_output=True,timeout=180)
 elapsed=time.monotonic()-start
 (E/(label+'.json')).write_bytes(p.stdout);(E/(label+'.stderr')).write_bytes(p.stderr)
 print(json.dumps({'label':label,'seconds':round(elapsed,3),'exit':p.returncode}),flush=True)
 if p.returncode:raise RuntimeError(f'{label}: {p.stderr.decode()}')
 return json.loads(p.stdout),elapsed
if __name__=='__main__':
 for i in range(1,10):
  h=T/f'mate-{i}'
  obj,secs=run(f'home-summary-{i}',[R/'bin/fm-fleet-snapshot.sh','--secondmate-home-summary'],h)
  (h/'state/home-summary.json').write_text(json.dumps(obj));assert obj['valid'] is True

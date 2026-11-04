import os,subprocess,json
from pathlib import Path
root=Path.cwd();E=Path('~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV');home=root/'.phase-tmp'/'r2-github-home'
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_')):env.pop(k)
env['FM_HOME']=str(home);(home/'config'/'pr-health-monitor').touch()
with (E/'r2-pr-health-live.log').open('w') as log:
 for i in range(2):
  p=subprocess.run(['bash','bin/fm-pr-health.sh','poll'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
  log.write('$ bin/fm-pr-health.sh poll (pass '+str(i+1)+')\n'+p.stdout+'exit: '+str(p.returncode)+'\n');log.flush()
  assert p.returncode==0,p.stdout
 state=json.loads((home/'state'/'pr-health.json').read_text())
 (E/'r2-pr-health-state.json').write_text(json.dumps(state,indent=2)+'\n')
 log.write('Persisted PR monitoring state:\n'+json.dumps(state,indent=2)+'\n')

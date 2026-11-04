import os,subprocess,json,time,shutil
from pathlib import Path
root=Path.cwd(); E=Path('~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV'); world=root/'.phase-tmp'/'r2-herdr';world.mkdir()
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_')) or k=='TMUX':env.pop(k)
env.update(FM_HERDR_LAB_STATE_DIR=str(world/'sessions'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',TREEHOUSE_ROOT=str(world/'pool'))
log=(E/'r2-herdr-live.log').open('w'); helper=root/'bin/fm-herdr-lab.sh';session='fm-lab-r2-live'
def run(args,ok=(0,),extra=None):
 e=env.copy();e.update(extra or {})
 p=subprocess.run(list(map(str,args)),cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=100)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit: '+str(p.returncode)+'\n');log.flush()
 if p.returncode not in ok:raise RuntimeError(p.stdout)
 return p
try:
 run([helper,'provision',session])
 data=json.loads(run([helper,'run',session,'session','list','--json']).stdout)
 socket=next(x['socket_path'] for x in data['sessions'] if x['name']==session)
 ws=json.loads(run([helper,'run',session,'workspace','create','--cwd',world,'--label','lab-launcher','--no-focus']).stdout)
 pane=ws['result']['root_pane']['pane_id']
 base={'HERDR_SESSION':session,'HERDR_ENV':'1','HERDR_PANE_ID':pane,'HERDR_SOCKET_PATH':socket}
 identity='. bin/fm-backend.sh; fm_backend_source herdr; fm_backend_herdr_launcher_identity "$HERDR_SESSION"'
 run(['bash','-c',identity],extra=base)
 # A legacy alias resolves to a live pane but does not carry its exact id.
 legacy=pane.replace('w','').replace(':p','-')
 r=run(['bash','-c',identity],ok=(1,),extra=dict(base,HERDR_PANE_ID=legacy))
 assert 'is stale' in r.stdout and 'HERDR_TAB_ID' in r.stdout
 r=run(['bash','-c',identity],ok=(1,),extra=dict(base,HERDR_SOCKET_PATH=str(world/'foreign.sock')))
 assert 'cross-session' in r.stdout
 home=world/'home'; project=world/'project'
 run([root/'bin/fm-lab-home.sh','create',home]);env['FM_HOME']=str(home)
 run(['git','init','-b','main',project]);(project/'README.md').write_text('lab base\n')
 run(['git','-C',project,'add','README.md']);run(['git','-C',project,'commit','-m','base'])
 run(['git','clone','--bare',project,world/'origin.git']);run(['git','-C',project,'remote','add','origin',world/'origin.git'])
 (home/'config'/'herdr-presentation-spaces').write_text('off\n')
 run([root/'bin/fm-brief.sh','lease-live','scratch','--mode','local-only','--herdr-lab'])
 brief=home/'data'/'lease-live'/'brief.md';s=brief.read_text().replace('{TASK}','Verify the isolated task copy lease.').replace('{FIRSTMATE_SPEC}','Run a local shell and retain its cwd for inspection.');brief.write_text(s)
 run([root/'bin/fm-spawn.sh','lease-live',project,'sh -c "echo lease-live-ready"','--backend','herdr','--mode','local-only','--yolo','off'],extra=base)
 meta=dict(line.split('=',1) for line in (home/'state'/'lease-live.meta').read_text().splitlines() if '=' in line)
 actual=json.loads(run([helper,'run',session,'pane','get',meta['window'].split(':',1)[1]]).stdout)['result']['pane']
 assert actual['cwd']==meta['worktree'],(actual,meta)
 log.write('Restorable top-level cwd matches recorded leased task copy: '+actual['cwd']+'\n')
 (E/'r2-herdr-pane.json').write_text(json.dumps(actual,indent=2)+'\n')
 run([root/'bin/fm-teardown.sh','lease-live'],extra=base)
finally:
 run([helper,'teardown',session]);log.close()

import os,subprocess,pathlib,time,shutil,json,hashlib
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.l'; EVID=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M472BY3F7ZBVXN1MGABMMSVX'); assert not LAB.exists()
env=os.environ.copy()
for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX'):
 env.pop(k,None)
env.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'tmux'),FM_SUPERVISION_ACTOR='main',TMPDIR=str(ROOT/'.test-phase-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Disposable test',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Disposable test',GIT_COMMITTER_EMAIL='test@example.invalid',TREEHOUSE_ROOT=str(LAB/'pool'))
log=open(EVID/'live-spawn.log','w',buffering=1)
ID='fm-lab-raw-'+str(os.getpid()); proc=None; results=[]
def run(args,timeout=90,allow=False,cwd=ROOT):
 p=subprocess.run([str(a) for a in args],cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.write('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+f'[exit={p.returncode}]\n')
 if p.returncode and not allow: raise RuntimeError(p.stdout)
 return p
def tm(*args,**kw):return run(['tmux','-L','fm-lab',*args],**kw)
try:
 run([ROOT/'bin/fm-lab-home.sh','create',LAB]);(LAB/'tmux').mkdir();(LAB/'config/supervision-host').touch();(LAB/'config/backlog-backend').write_text('manual\n')
 proj=LAB/'projects/demo';proj.mkdir()
 run(['git','init','-q','-b','main',proj]);run(['git','-C',proj,'commit','-q','--allow-empty','-m','Disposable test seed'])
 run(['treehouse','init'],cwd=proj)
 run([ROOT/'bin/fm-brief.sh',ID,'demo','--scout'])
 brief=LAB/'data'/ID/'brief.md';brief.write_text(brief.read_text().replace('{TASK}','Verify a disposable raw command launch.').replace('{FIRSTMATE_SPEC}','Run the supplied raw command only; this is isolated test data.'))
 tm('new-session','-d','-s','primary','-n','probe','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={LAB}','codex --disable hooks')
 tm('set-window-option','-t','primary:probe','automatic-rename','off')
 socket=tm('display-message','-p','-t','primary:probe','#{socket_path}').stdout.strip();pid=tm('display-message','-p','-t','primary:probe','#{pid}').stdout.strip();env['TMUX']=f'{socket},{pid},0'
 run([ROOT/'bin/fm-afk-contract.sh','enter','--spend','1'])
 p=run([ROOT/'bin/fm-spawn.sh',ID,proj,'sleep 120','--scout'],allow=True)
 if p.returncode:
  results.append(dict(name='fresh raw command startup',result='blocked',output=p.stdout))
  tm('capture-pane','-p','-t',f'primary:fm-{ID}','-S','-100',allow=True)
 else:
  assert f'spawned {ID}' in p.stdout
  p=run([ROOT/'bin/fm-afk-spend-count.sh',LAB/'state']);assert p.stdout.strip()=='1',p.stdout
  p=run([ROOT/'bin/fm-spawn.sh','second',proj,'sleep 120','--scout'],allow=True);assert p.returncode==1 and 'caps concurrent workers' in p.stdout,p.stdout
  tm('capture-pane','-p','-t',f'primary:fm-{ID}','-S','-100')
  results.append(dict(name='Fresh raw command starts through real tmux and Treehouse and reserves cap against a second fresh spawn',result='pass'))
except Exception as e:
 log.write('SETUP/DRIVER ERROR: '+str(e)+'\n');results.append(dict(name='fresh raw command startup',result='blocked',reason=str(e)))
finally:
 tm('kill-server',allow=True)
 # The production launch's per-task build temp is an incidental toolchain temp.
 # Remove exactly this disposable task's path, never any other task temp.
 tasktmp=pathlib.Path('/tmp')/('fm-'+ID)
 if tasktmp.exists(): shutil.rmtree(tasktmp)
 namespace=pathlib.Path('/tmp')/('fm-'+ID+'+'+hashlib.sha256(str(LAB).encode()).hexdigest())
 if namespace.exists(): shutil.rmtree(namespace)
 hooks=LAB/'state'/(ID+'.git-hooks')
 if hooks.exists(): hooks.chmod(0o700)
 shutil.rmtree(LAB)
 log.write('Private fm-lab server stopped; disposable lab and launch temp removed.\n')
 (EVID/'live-spawn-results.json').write_text(json.dumps(results,indent=2)+'\n');log.close()

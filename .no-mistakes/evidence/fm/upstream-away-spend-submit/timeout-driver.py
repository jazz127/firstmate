import os, pathlib, subprocess, json, shlex, time, shutil, re
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.l'; EVIDENCE=pathlib.Path(os.environ['FM_TEST_EVIDENCE'])
LOG=(EVIDENCE/'timeout-evidence.log').open('w')
def clean(s):
 return re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<EMAIL>',str(s).replace(str(ROOT),'<WORKTREE>').replace('<OPERATOR_HOME>','<OPERATOR_HOME>'))
def note(s):
 s=clean(s); LOG.write(s+'\n');LOG.flush();print(s,flush=True)
ENV=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX','CLAUDECODE','HERDR_SESSION','HERDR_ENV']:
 ENV.pop(k,None)
ENV.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'t'),TMPDIR=str(LAB/'tmp'),DISABLE_AUTOUPDATER='1',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
def run(args,env=None,check=True,quiet=False,cwd=ROOT,timeout=30):
 p=subprocess.run(args,env=env or ENV,cwd=cwd,capture_output=True,text=True,timeout=timeout)
 if not quiet: note('$ '+shlex.join(map(str,args))+f'\nexit={p.returncode}\n'+p.stdout+p.stderr)
 if check and p.returncode: raise RuntimeError(shlex.join(map(str,args))+' failed')
 return p

def tm(*args,**kw):return run(['tmux','-L','fm-lab',*args],**kw)
def count(expected,label):
 note('SCENARIO: '+label)
 p=run(['bash','bin/fm-afk-spend-count.sh',str(LAB/'state')]); assert p.stdout.strip()==str(expected),(label,p.stdout,expected)
def status(s):
 (LAB/'state/task.status').write_text(s+'\n');note('task.status: '+s)
def readstate():return run(['bash','bin/fm-crew-state.sh','task'],check=False)
def capprobe(blocked):
 p=run(['bash','bin/fm-spawn.sh','fresh',str(LAB/'no-project'),'--mode','no-mistakes','--yolo','off'],check=False)
 assert ('caps concurrent workers' in p.stderr)==blocked,p.stdout+p.stderr
 note('Fresh admission '+('refused at spend cap' if blocked else 'passed spend cap and reached independent missing-project check'))
import signal
serverpid=None
try:
 LAB.mkdir();run(['bash','bin/fm-lab-home.sh','create',str(LAB)])
 for d in ['t','tmp','nm']:(LAB/d).mkdir()
 ENV['NM_HOME']=str(LAB/'nm')
 (LAB/'config/supervision-host-off').touch();(LAB/'config/backlog-backend').write_text('manual\n')
 (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 run(['bash','bin/fm-afk-contract.sh','enter','--spend','1'])
 tm('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'bash --noprofile --norc')
 ENV['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip();serverpid=int(ENV['TMUX'].split(',')[1])
 tm('new-window','-d','-n','worker','sleep 120')
 (LAB/'state/task.meta').write_text('window=primary:worker\nharness=sleep\nkind=scout\n')
 status('working: actual raw command running')
 count(1,'An unrecognized but running raw process counts')
 os.kill(serverpid,signal.SIGSTOP);note('SIGSTOP sent only to recorded disposable tmux server PID '+str(serverpid))
 t=time.monotonic();count(1,'A hung actual tmux inventory returns a conservative count within its five-second budget');elapsed=time.monotonic()-t
 note(f'Real backend inventory timeout elapsed: {elapsed:.3f}s');assert elapsed<8
 t=time.monotonic();capprobe(True);elapsed=time.monotonic()-t;note(f'Fresh away admission with hung real backend returned in {elapsed:.3f}s');assert elapsed<10
 os.kill(serverpid,signal.SIGCONT)
 tm('display-message','-p','-t','primary:worker','#{pane_current_command}')
 note('TIMEOUT DRIVER COMPLETE')
finally:
 if serverpid:
  try:os.kill(serverpid,signal.SIGCONT)
  except ProcessLookupError:pass
 if (LAB/'t').exists():tm('kill-server',check=False)
 if LAB.exists():shutil.rmtree(LAB)
 note('Disposable backend resumed, stopped and lab removed');LOG.close()

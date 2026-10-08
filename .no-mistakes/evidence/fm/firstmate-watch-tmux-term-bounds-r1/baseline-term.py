import pathlib,subprocess as sp,os,signal,time,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4BYXMSQ45VRM1V0Y30Z00VR'); L=R/'.nm-baseline'; S=E/'s'; old=R/'bin'/'.nm-baseline-watch.sh'; env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('TMUX','NO_MISTAKES_GATE'): env.pop(k,None)
env.update(FM_HOME=str(L),TMUX_TMPDIR=str(S),FM_BACKEND='tmux',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SECONDMATE_LIVENESS_SECS='99999999')
def run(args):
 p=sp.run(args,env=env,text=True,capture_output=True,timeout=10)
 if p.returncode: raise RuntimeError(p.stdout+p.stderr)
 return p.stdout.strip()
def tm(*a): return run(['tmux','-L','fm-lab',*a])
server=None;p=None
try:
 old.write_text(run(['git','show','47aff866dbe0612bd43df66d8fa76576e06a2b3e:bin/fm-watch.sh']))
 run(['bash','bin/fm-lab-home.sh','create',str(L)]); S.mkdir(); S.chmod(0o700)
 tm('new-session','-d','-s','primary','-x','120','-y','40','sleep 60'); tm('new-window','-d','-t','primary:','-n','fm-worker','sleep 60'); server=int(tm('display-message','-p','#{pid}')); env['TMUX']=tm('display-message','-p','#{socket_path}')+','+str(server)+',0'
 st=L/'state'; (st/'home-summary.json').write_text('{}'); (st/'.home-summary-refresh.lock').mkdir(); (st/'.home-summary-refresh.lock'/'pid').write_text(str(os.getpid())); (st/'worker.meta').write_text('window=primary:fm-worker\nkind=ship\nharness=codex\n'); (st/'worker.inbox').mkdir(); rec=st/'worker.inbox'/'001.msg'; rec.write_text('Isolated regression instruction\n'); os.utime(rec,(time.time()-600,time.time()-600))
 os.kill(server,signal.SIGSTOP)
 with (E/'baseline-watcher.out').open('w') as out:
  p=sp.Popen(['bash',str(old)],env=env,stdout=out,stderr=sp.STDOUT)
  deadline=time.monotonic()+10
  while time.monotonic()<deadline:
   rows=[x.split(None,3) for x in run(['ps','-axo','pid=,ppid=,stat=,command=']).splitlines()]; owned={p.pid}
   for _ in range(12): owned.update(int(x[0]) for x in rows if int(x[1]) in owned)
   blocked=[x for x in rows if int(x[0]) in owned and x[3].startswith('tmux list-windows')]
   if blocked: break
   time.sleep(.1)
  assert blocked,'Baseline did not enter original inbox query'
  print('Base watcher blocked on real query:',blocked,flush=True)
  p.terminate(); time.sleep(2)
  assert p.poll() is None,'Base unexpectedly stopped promptly'
  assert (st/'.watch.lock').exists()
  print('After TERM: base watcher still alive after 2 seconds and singleton lock remains',flush=True)
  os.kill(server,signal.SIGCONT); p.wait(timeout=10)
  print('Resuming server releases deferred TERM; exit:',p.returncode,flush=True)
finally:
 if server:
  try: os.kill(server,signal.SIGCONT)
  except ProcessLookupError: pass
 if p and p.poll() is None: p.kill();p.wait()
 sp.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True,timeout=10)
 old.unlink(missing_ok=True)
 shutil.rmtree(L,ignore_errors=True);shutil.rmtree(S,ignore_errors=True)
 print('Baseline lab and transient base script removed',flush=True)

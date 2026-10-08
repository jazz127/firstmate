import pathlib,subprocess as sp,os,signal,time,shutil,json
R=pathlib.Path.cwd();E=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4BYXMSQ45VRM1V0Y30Z00VR'); L=R/'.nm-inactive';S=E/'s'; env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('TMUX','NO_MISTAKES_GATE'): env.pop(k,None)
env.update(TMUX_TMPDIR=str(S),FM_BACKEND='tmux',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SECONDMATE_LIVENESS_SECS='99999999',FM_INACTIVE_RECONCILE_BUDGET_SECS='30')
def run(a):
 p=sp.run(a,env=env,text=True,capture_output=True,timeout=10)
 if p.returncode: raise RuntimeError(p.stdout+p.stderr)
 return p.stdout.strip()
def tm(*a):return run(['tmux','-L','fm-lab',*a])
def rows():return [x.split(None,4) for x in run(['ps','-axo','pid=,ppid=,pgid=,stat=,command=']).splitlines()]
server=None;p=None
try:
 L.mkdir();S.mkdir();S.chmod(0o700)
 tm('new-session','-d','-s','primary','-x','120','-y','40','sleep 120');tm('new-window','-d','-t','primary:','-n','fm-stalled','sleep 120');server=int(tm('display-message','-p','#{pid}'));env['TMUX']=tm('display-message','-p','#{socket_path}')+','+str(server)+',0'
 for mechanism in ('perl','bash'):
  home=L/mechanism;run(['bash','bin/fm-lab-home.sh','create',str(home)]);env['FM_HOME']=str(home);env['FM_TIMEOUT_MECHANISM_OVERRIDE']='bash' if mechanism=='bash' else ''
  st=home/'state';wt=home/'worker';wt.mkdir()
  (st/'home-summary.json').write_text('{}');(st/'.home-summary-refresh.lock').mkdir();(st/'.home-summary-refresh.lock'/'pid').write_text(str(os.getpid()))
  (st/'stalled.meta').write_text('window=primary:fm-stalled\nkind=scout\nharness=codex\nworktree='+str(wt)+'\n');(st/'stalled.status').write_text('working: isolated live validation\n')
  for path in (st/'stalled.meta',st/'stalled.status'):os.utime(path,(time.time()-2000,time.time()-2000))
  os.kill(server,signal.SIGSTOP)
  with (E/f'live-inactive-{mechanism}.out').open('w') as out:
   p=sp.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=sp.STDOUT);deadline=time.monotonic()+15;observed=[]
   while time.monotonic()<deadline and p.poll() is None:
    rr=rows();ids={p.pid}
    for _ in range(20):ids.update(int(x[0]) for x in rr if int(x[1]) in ids)
    observed=[x for x in rr if int(x[0]) in ids and int(x[0])!=p.pid]
    if any(x[4].startswith('tmux display-message') for x in observed):break
    time.sleep(.1)
   assert any(x[4].startswith('tmux display-message') for x in observed),observed
   assert any('fm-inactive-reconcile.sh _scan-locked' in x[4] for x in observed),observed
   assert any('fm-crew-state.sh stalled' in x[4] for x in observed),observed
   concise=[x[:4]+[x[4].split(' -e ')[0] if x[4].startswith('perl ') else x[4]] for x in observed]
   print(mechanism,'real inactive scan blocked processes:',json.dumps(concise),flush=True)
   start=time.monotonic();p.terminate();p.wait(timeout=8);deadline=time.monotonic()+4
   while time.monotonic()<deadline:
    alive={int(x[0]) for x in rows() if not x[3].startswith('Z')};remaining=[x for x in observed if int(x[0]) in alive]
    if not remaining:break
    time.sleep(.1)
   assert not remaining,remaining;assert not (st/'.watch.lock').exists();assert not list(st.glob('.fm-capture-output.*'));assert (st/'.inactive-outcome-reconcile').exists();assert (st/'terminal-outcomes').is_dir();assert (st/'.watcher-down').exists()
   print(mechanism,'TERM exit:',p.returncode,'seconds:',round(time.monotonic()-start,3),'all scanner, crew-state, timeout and tmux descendants reaped; cadence and receipt bookkeeping retained; watcher cleanup complete',flush=True)
  os.kill(server,signal.SIGCONT)
finally:
 if server:
  try:os.kill(server,signal.SIGCONT)
  except ProcessLookupError:pass
 if p and p.poll() is None:p.kill();p.wait()
 sp.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True,timeout=10)
 shutil.rmtree(L,ignore_errors=True);shutil.rmtree(S,ignore_errors=True)
 print('All inactive-scan labs torn down',flush=True)

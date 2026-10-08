import os, pathlib, subprocess as sp, time, signal, shutil, json
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4BYXMSQ45VRM1V0Y30Z00VR'); W=R/'.nm-live'; S=E/'s'; W.mkdir(exist_ok=True); S.mkdir(exist_ok=True); os.chmod(S,0o700)
base=os.environ.copy()
for k in list(base):
 if k.startswith('FM_') or k in ('TMUX','NO_MISTAKES_GATE'): base.pop(k,None)
base.update(TMUX_TMPDIR=str(S),FM_BACKEND='tmux')
shim=W/'route'; shim.mkdir(); real=shutil.which('tmux'); (shim/'tmux').write_text('#!/bin/sh\nexec '+real+' -L fm-lab \"$@\"\n'); (shim/'tmux').chmod(0o700)
results=[]; server=None

def run(args,env=base,check=True):
 p=sp.run(args,env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=20)
 if check and p.returncode: raise RuntimeError(str(args)+': '+p.stdout)
 return p.stdout.strip()
def tm(*a): return run(['tmux','-L','fm-lab',*a])
def rows():
 raw=run(['ps','-axo','pid=,ppid=,pgid=,stat=,command='])
 return [l.strip().split(None,4) for l in raw.splitlines()]
def children(pid):
 rr=rows(); ids={pid}; previous=0
 while len(ids)!=previous:
  previous=len(ids)
  ids.update(int(x[0]) for x in rr if int(x[1]) in ids)
 return [x for x in rr if int(x[0]) in ids and int(x[0])!=pid]
def fresh(name):
 home=W/name; run(['bash','bin/fm-lab-home.sh','create',str(home)])
 env=base.copy(); env['FM_HOME']=str(home)
 st=home/'state'
 (st/'home-summary.json').write_text('{}'); (st/'.home-summary-refresh.lock').mkdir(); (st/'.home-summary-refresh.lock'/'pid').write_text(str(os.getpid()))
 return home,env
try:
 print('Real tmux:',run(['tmux','-V']),flush=True)
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(R),'sleep 600')
 socket=tm('display-message','-p','#{socket_path}'); server=int(tm('display-message','-p','#{pid}')); base['TMUX']=f'{socket},{server},0'
 print('Private server:',server,'socket:',socket,flush=True)
 tm('new-window','-d','-t','primary:','-n','fm-worker','-c',str(R),'sleep 600')
 # The complete product executable hits its new inbox agent-state boundary before pane capture.
 home,env=fresh('inbox'); st=home/'state'
 (st/'worker.meta').write_text('window=primary:fm-worker\nkind=ship\nharness=codex\n')
 (st/'worker.inbox').mkdir(); rec=st/'worker.inbox'/'001.msg'; rec.write_text('Read this isolated test instruction\n'); os.utime(rec,(time.time()-600,time.time()-600))
 env.update(FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SECONDMATE_LIVENESS_SECS='99999999')
 os.kill(server,signal.SIGSTOP)
 with (E/'live-inbox.out').open('w') as out:
  p=sp.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=sp.STDOUT)
  try:
   deadline=time.monotonic()+15; observed=[]
   while time.monotonic()<deadline and p.poll() is None:
    observed=children(p.pid)
    if any('tmux list-windows' in x[4] for x in observed): break
    time.sleep(.1)
   assert any('tmux list-windows' in x[4] for x in observed),str(observed)
   print('inbox blocked processes:',json.dumps(observed),flush=True)
   start=time.monotonic(); p.terminate(); p.wait(timeout=8); elapsed=time.monotonic()-start
   time.sleep(.2); alive={int(x[0]) for x in rows() if not x[3].startswith('Z')}
   assert not any(int(x[0]) in alive for x in observed)
   assert not (st/'.watch.lock').exists(); assert not list(st.glob('.fm-capture-output.*')); assert (st/'.watcher-down').exists()
   print('Full watcher TERM:',p.returncode,'seconds:',round(elapsed,3),'query reaped; lock released; output removed; durable stop exists',flush=True)
   results.append(dict(name='full watcher inbox list-windows cancellation',passed=True,seconds=elapsed))
  finally:
   if p.poll() is None: p.kill(); p.wait()
   os.kill(server,signal.SIGCONT)
 # Explicit executable library driver exercises other changed query boundaries against the same real server.
 cases=[('agent-state','watcher_query fm_backend_agent_state tmux primary:fm-worker','list-windows'),('composer','watcher_query fm_backend_composer_state tmux primary:fm-worker','display-message'),('agent-alive','watcher_query fm_backend_agent_alive tmux primary:fm-worker','list-windows')]
 for mechanism in ('perl','bash'):
  cases.append((f'nested-timeout-{mechanism}','watcher_query fm_run_timed 60 tmux display-message -p -t primary:fm-worker "#{pane_id}"','display-message'))
 for name,cmd,expected in cases:
  home,env=fresh(name); env['FM_TIMEOUT_MECHANISM_OVERRIDE']='bash' if name.endswith('-bash') else ''
  os.kill(server,signal.SIGSTOP)
  with (E/f'live-{name}.out').open('w') as out:
   p=sp.Popen(['bash','-c','. bin/fm-watch.sh; trap "fm_active_check_stop; fm_capture_output_cleanup" EXIT; '+cmd],env=env,stdout=out,stderr=sp.STDOUT)
   try:
    deadline=time.monotonic()+10; observed=[]
    while time.monotonic()<deadline and p.poll() is None:
     observed=children(p.pid)
     if any('tmux '+expected in x[4] for x in observed): break
     time.sleep(.1)
    assert any('tmux '+expected in x[4] for x in observed),str(observed)
    print(name,'blocked:',json.dumps(observed),flush=True)
    start=time.monotonic(); p.terminate(); p.wait(timeout=8)
    deadline=time.monotonic()+4
    while time.monotonic()<deadline:
     alive={int(x[0]) for x in rows() if not x[3].startswith('Z')}
     remaining=[x for x in observed if int(x[0]) in alive]
     if not remaining: break
     time.sleep(.1)
    assert not remaining,str(remaining); assert not list((home/'state').glob('.fm-capture-output.*'))
    print(name,'TERM exit',p.returncode,'seconds',round(time.monotonic()-start,3),'all observed descendants reaped',flush=True)
    results.append(dict(name=name,passed=True))
   finally:
    if p.poll() is None: p.kill(); p.wait()
    os.kill(server,signal.SIGCONT)
 home,env=fresh('healthy')
 output=run(['bash','-c','. bin/fm-watch.sh; watcher_query fm_backend_agent_state tmux primary:fm-worker; printf "agent=%s rc=%s\\n" "$WATCHER_QUERY" "$?"; watcher_query fm_backend_agent_alive tmux primary:fm-worker; printf "alive=%s rc=%s\\n" "$WATCHER_QUERY" "$?"; watcher_query fm_run_timed 5 tmux display-message -p -t primary:fm-worker "#{pane_id}"; printf "pane=%s rc=%s\\n" "$WATCHER_QUERY" "$?"'],env)
 print('Healthy results:',output,flush=True); assert 'pane=%' in output and 'rc=0' in output
 results.append(dict(name='healthy real backend results',passed=True))
 tm('kill-server'); server=None; base.pop('TMUX',None)
 # Scrub actual persistent server and new-window environments using the real adapter.
 home,env=fresh('server-env'); env.update(FM_TIMEOUT_OWNER_PID=str(os.getpid()),FM_EXEC_TIMED_OWNER_PID=str(os.getpid()),FM_TEST_SENTINEL='kept')
 env['PATH']=str(shim)+os.pathsep+env['PATH']
 command='. bin/fm-backend.sh; fm_backend_source tmux; fm_backend_tmux_container_ensure; fm_backend_tmux_create_task firstmate fm-recovered "$PWD"'
 print('Fresh persistent boundary:',run(['bash','-c',command],env),flush=True)
 server=int(tm('display-message','-p','#{pid}'))
 environment=tm('show-environment','-g'); assert 'FM_TIMEOUT_OWNER_PID=' not in environment and 'FM_EXEC_TIMED_OWNER_PID=' not in environment
 assert 'FM_TEST_SENTINEL=kept' in environment
 proof=E/'pane-startup.txt'
 pane_cmd='printf "timeout_owner=%s exec_owner=%s sentinel=%s\\n" "${FM_TIMEOUT_OWNER_PID-unset}" "${FM_EXEC_TIMED_OWNER_PID-unset}" "$FM_TEST_SENTINEL"; . '+str(R)+'/bin/fm-timeout-lib.sh; fm_run_timed 3 bash -c "sleep 0.2; echo startup-complete"'
 tm('send-keys','-t','firstmate:fm-recovered',pane_cmd,'Enter')
 time.sleep(1); capture=tm('capture-pane','-p','-t','firstmate:fm-recovered'); proof.write_text(capture+'\n')
 assert 'timeout_owner=unset exec_owner=unset sentinel=kept' in capture and '\nstartup-complete\n' in capture
 print('Persistent server omits both owner variables; new pane retains sentinel and completes timed startup',flush=True)
 results.append(dict(name='fresh real tmux server and pane ownership scrub',passed=True))
finally:
 if server:
  try: os.kill(server,signal.SIGCONT)
  except ProcessLookupError: pass
 run(['tmux','-L','fm-lab','kill-server'],check=False)
 shutil.rmtree(W,ignore_errors=True); shutil.rmtree(S,ignore_errors=True)
 (E/'live-tmux-results.json').write_text(json.dumps(results,indent=2)+'\n')
 print('Isolated lab torn down',flush=True)

import os,pathlib,subprocess,json,signal,time
root=pathlib.Path.cwd();scratch=root/'.test-sync-validation';results=[]
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK')
def run_case(label,interrupt):
    home=scratch/f'watcher {label}; literal-home'
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','FMX_','HERDR_','REX_','TASKS_AXI_')) and k!='TMUX'}
    env.update(FM_HOME=str(home),TMPDIR=str(scratch/'tmp'),FM_POLL='1',FM_CHECK_INTERVAL='1',FM_CHECK_TIMEOUT='20' if interrupt else '2',FM_HEARTBEAT='999999')
    q=subprocess.run(['bin/fm-lab-home.sh','create',str(home)],env=env,capture_output=True,text=True);assert q.returncode==0
    check=home/'state/bounded.check.sh'
    check.write_text('#!/bin/bash\ntrap "" TERM\necho $$ > "'+str(home/'command.pid')+'"\nsleep 60 &\necho $! > "'+str(home/'descendant.pid')+'"\nwait\n')
    check.chmod(0o700)
    q=subprocess.run(['bin/fm-check-register.sh','bounded'],env=env,capture_output=True,text=True);assert q.returncode==0,q
    p=subprocess.Popen(['bin/fm-watch.sh'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    pids=[]
    try:
        until=time.monotonic()+15
        while not (home/'descendant.pid').exists():
            if p.poll() is not None:
                out,err=p.communicate();raise AssertionError(('watcher exited before check started',p.returncode,out,err))
            assert time.monotonic()<until,'watcher did not run registered check'
            time.sleep(.05)
        pids=[int((home/f).read_text()) for f in ('command.pid','descendant.pid')]
        if interrupt:p.send_signal(signal.SIGTERM)
        out,err=p.communicate(timeout=15)
        states=[]
        for pid in pids:
            state=subprocess.run(['ps','-p',str(pid),'-o','stat='],text=True,capture_output=True).stdout.strip()
            states.append(state or 'absent');assert not state or state.startswith('Z'),(pid,state)
        results.append({'case':label,'driver':'bin/fm-watch.sh with real registered local check','exit':p.returncode,'stdout':out,'stderr':err,'command_and_descendant_states':states})
        print(json.dumps(results[-1]),flush=True)
        if not interrupt:
            assert p.returncode==0 and ('timed out' in out or 'timeout' in out),results[-1]
    finally:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGKILL);p.communicate()
        for pid in pids:
            try:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
        q=subprocess.run(['bin/fm-check-unregister.sh','bounded'],env=env,capture_output=True,text=True);assert q.returncode==0,q
try:
    run_case('deadline',False)
    run_case('interruption',True)
    print('The real watcher bounded a hanging registered check and reaped its TERM-resistant subtree on deadline and watcher interruption.')
finally:
    (evidence/'watcher-timeout-live.json').write_text(json.dumps(results,indent=2)+'\n')

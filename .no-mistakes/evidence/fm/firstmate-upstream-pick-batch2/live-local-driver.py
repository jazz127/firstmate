import os, pathlib, subprocess, time, shutil
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('~/.no-mistakes/evidence/01M5ZZRF6271EFMZCJ4FK22023')
BASE=ROOT/'.test-phase-tmp'
lab=pathlib.Path(subprocess.check_output(['mktemp','-d',str(BASE/'fm-lab.XXXXXX')],text=True).strip())
children=[]
outputs=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'HERDR_')) or k in ('TMUX','TMUX_PANE','PI_CODING_AGENT'):
        env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(BASE),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WATCH_PREDECESSOR_ARM_PID=str(os.getpid()))
# This empty lab has no fleet endpoints; pin any incidental tmux probe away from operator sockets.
env['TMUX']=str(lab/'unused-tmux')+',0,0'
def run(args, **kw):
    return subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,check=True,**kw)
def wait(pred, message, timeout=35):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        if pred(): return
        time.sleep(.1)
    raise RuntimeError(message)
def start(name, args):
    f=open(EV/name,'w'); outputs.append(f)
    p=subprocess.Popen(args,cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
    children.append(p)
    return p
try:
    print(run(['bin/fm-lab-home.sh','create',str(lab)]).stdout.strip(),flush=True)
    owner=start('live-watcher-owner.log',['bin/fm-watch-arm.sh'])
    wait(lambda: 'watcher: started pid=' in (EV/'live-watcher-owner.log').read_text(),'initial watcher failed')
    old=int((lab/'state/.watch.lock/pid').read_text())
    unrelated=subprocess.Popen(['sleep','120']); children.append(unrelated)
    follower=start('live-watcher-foreign-owner.log',['bin/fm-watch-arm.sh','--take-over',str(unrelated.pid)])
    wait(lambda: 'watcher: attached pid=' in (EV/'live-watcher-foreign-owner.log').read_text(),'unrelated-owner takeover did not attach')
    assert int((lab/'state/.watch.lock/pid').read_text())==old
    os.kill(old,0)
    follower.terminate()
    assert follower.wait(timeout=10) in (0,143,-15)
    os.kill(old,0)
    unrelated.terminate(); unrelated.wait(timeout=5)
    print('foreign-owner adversary: takeover attached without stopping or replacing the original watcher',flush=True)
    takeover=start('live-watcher-takeover.log',['bin/fm-watch-arm.sh','--take-over',str(owner.pid)])
    wait(lambda: 'watcher: started pid=' in (EV/'live-watcher-takeover.log').read_text(),'takeover failed')
    fresh=int((lab/'state/.watch.lock/pid').read_text())
    assert fresh != old
    owner_rc=owner.wait(timeout=10)
    assert owner_rc in (0,143,-15), owner_rc
    wait(lambda: subprocess.run(["kill","-0",str(old)],capture_output=True).returncode!=0, "retired watcher is still alive")
    time.sleep(2)
    assert takeover.poll() is None, 'replacement watcher closed without new work'
    print(f'watcher takeover: old={old}, replacement={fresh}, predecessor exit={owner_rc}; replacement remained quiet',flush=True)
    (lab/'state/lab.status').write_text('needs-decision [key=lab-choice]: choose export A or B\n')
    rc=takeover.wait(timeout=35)
    assert rc==0,rc
    out=(EV/'live-watcher-takeover.log').read_text()
    assert 'signal:' in out and 'lab.status' in out,out
    shutil.copy(lab/'state/.watch-cycle-exits.log',EV/'live-watcher-lifecycle.log')
    print('replacement watcher surfaced the new lab.status decision and exited 0',flush=True)
    # Real executable grant interface, real OS owner, and real local queue.
    sleeper=subprocess.Popen(['sleep','120']); children.append(sleeper)
    env['TZ']='America/Los_Angeles'
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check timezone "check: timezone proof"'])
    seq=(lab/'state/.wake-queue.seq').read_text().strip()
    run(['bin/fm-wake-grant.sh','activate',str(sleeper.pid),'timezone-live'])
    before=(lab/'state/.branch-eligible-owner').read_text()
    env['TZ']='Asia/Tokyo'
    run(['bin/fm-wake-grant.sh','publish','timezone-live',seq])
    count=run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_actor_pending_count branch']).stdout.strip()
    assert int(count)==1,count
    print(f'grant activated in America/Los_Angeles and published/read in Asia/Tokyo: branch pending={count}',flush=True)
    shutil.copy(lab/'state/.branch-eligible-owner',EV/'live-timezone-owner.txt')
    run(['bin/fm-wake-grant.sh','release','timezone-live'])
    sleeper.terminate(); assert sleeper.wait(timeout=5)==-15
    failed=subprocess.run(['bin/fm-wake-grant.sh','publish','timezone-live',seq],cwd=ROOT,env=env,capture_output=True,text=True)
    assert failed.returncode==1,failed.returncode
    print(f'dead owner adversary: publish refused with exit={failed.returncode}',flush=True)
finally:
    for p in reversed(children):
        if p.poll() is None:
            p.terminate()
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait(timeout=10)
    pidfile=lab/'state/.watch.lock/pid'
    if pidfile.exists():
        pid=int(pidfile.read_text())
        try: os.kill(pid,15)
        except ProcessLookupError: pass
        wait(lambda: not pathlib.Path('/proc',str(pid)).exists() if pathlib.Path('/proc').exists() else subprocess.run(['kill','-0',str(pid)],capture_output=True).returncode!=0,'watcher did not stop',15)
    for f in outputs:f.close()
    shutil.rmtree(lab)
    print('all lab children waited; disposable home removed',flush=True)

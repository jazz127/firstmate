import pathlib,os,subprocess,time,signal,shutil
root=pathlib.Path.cwd();lab=root/'.l';ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M414DWEJKB1KZEC39HKT1E0P');log=[];arm=None
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') and k.endswith('_OVERRIDE'):env.pop(k)
env.pop('FM_GATE_REFUSE_BYPASS',None)
env.update(FM_HOME=str(lab),FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999',FM_SIGNAL_GRACE='1')
def run(args,check=True):
    p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.append('$ '+' '.join(args)+'\n'+p.stdout+f'exit={p.returncode}\n')
    if check and p.returncode:raise RuntimeError(log[-1])
    return p
def pid():
    try:return int((lab/'state/.watch.lock/pid').read_text())
    except:return 0
def wait(fn,label,n=300):
    for _ in range(n):
        if fn():return
        time.sleep(.1)
    raise RuntimeError('timeout '+label)
def confirm(g,p):return run(['bin/fm-watch-arm.sh','--handling-delivered',g,'--watcher-pid',str(p)],False).returncode
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    # Reproduce the extension's effective child environment without bypassing
    # the marked-lab guard, so the blocker has direct product evidence.
    probe_env=dict(env,FM_ROOT_OVERRIDE=str(root),FM_CONFIG_OVERRIDE=str(lab/'config'))
    refusal=subprocess.run(['bin/fm-watch-arm.sh'],env=probe_env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.append('Pi child environment with its path overrides:\n'+refusal.stdout+f'exit={refusal.returncode}\n');assert refusal.returncode==1
    outf=open(lab/'arm.stdout','w');arm=subprocess.Popen(['bin/fm-watch-arm.sh'],env=env,cwd=root,stdout=outf,stderr=subprocess.STDOUT)
    wait(lambda:pid()>0 and (lab/'state/.last-watcher-beat').exists(),'real watcher ready');p=pid();wait(lambda:'watcher: started' in (lab/'arm.stdout').read_text(),'arm readiness')
    log.append('Real running arm readiness:\n'+(lab/'arm.stdout').read_text())
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" downtime'])
    g=(lab/'state/.watcher-down').read_text().strip().split(':')[-1];assert confirm(g,p)==0
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_recovery_marker_ack "$FM_HOME/state/.watcher-down" "$1"','_',g])
    before=(lab/'state/.watcher-down').read_text();assert confirm(g,p)==0;assert before==(lab/'state/.watcher-down').read_text();log.append('Already-acknowledged token persisted unchanged: '+before)
    assert confirm('superseded.0.deadbeef',p)==3;assert pid()==p;os.kill(p,0)
    assert confirm(g,99999999)==1
    ident=lab/'state/.watch.lock/pid-identity';old=ident.read_text();ident.write_text('foreign-identity\n');assert confirm(g,p)==1;ident.write_text(old);os.kill(p,0)
    log.append('Live watcher preserved after stale generation, dead PID and foreign lock identity rejection.\n')
    (lab/'state/probe.status').write_text('check: disposable live wake\n')
    wait(lambda:arm.poll() is not None,'real arm closes on check wake');outf.close();out=(lab/'arm.stdout').read_text();log.append('Real arm output after status event:\n'+out);assert 'signal:' in out and 'probe.status' in out
    log.append('LIVE ARM SCENARIOS PASSED\n')
finally:
    run(['bin/fm-watch-arm.sh','--stop'],False)
    if arm and arm.poll() is None:arm.terminate();arm.wait(timeout=10)
    for name in ['.watch-cycle-exits.log','.watch-deliveries.log','.wake-queue','.watcher-down']:
        p=lab/'state'/name
        if p.exists():log.append(name+':\n'+p.read_text())
    (ev/'arm-recovery-live.txt').write_text(''.join(log))
    shutil.rmtree(lab,ignore_errors=True)

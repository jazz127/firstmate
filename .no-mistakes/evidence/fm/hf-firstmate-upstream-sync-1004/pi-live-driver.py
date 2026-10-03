import os, subprocess, time, json, pathlib, signal
root=pathlib.Path.cwd(); lab=root/'.l'; ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M414DWEJKB1KZEC39HKT1E0P'); transcript=[]
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TMUX']:
    env.pop(key,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),PI_CODING_AGENT_DIR=str(lab/'agent'),PI_OFFLINE='1',PI_TELEMETRY='0',FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999',FM_SIGNAL_GRACE='1',FM_WATCH_EXTENSION_LOG_KEEP_LINES='4')
def run(args,check=True):
    p=subprocess.run(args,env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if check and p.returncode: raise RuntimeError(str(args)+': '+p.stdout)
    return p
def tm(*args,check=True):return run(['tmux','-L','fm-lab',*args],check)
def capture(label):
    out=tm('capture-pane','-p','-S','-150','-t','primary').stdout
    transcript.append('\n=== '+label+' ===\n'+out); return out
def wait(fn,label,n=240):
    for _ in range(n):
        if fn():return
        time.sleep(.1)
    raise RuntimeError('timeout '+label+'\n'+capture(label))
def command(c):tm('send-keys','-t','primary','-l',c);tm('send-keys','-t','primary','Enter')
def pid():
    try:return int((lab/'state/.watch.lock/pid').read_text().strip())
    except:return 0
def alive(p):
    try:os.kill(p,0);return True
    except:return False
def confirm(g,p):
    x=run(['bin/fm-watch-arm.sh','--handling-delivered',g,'--watcher-pid',str(p)],False)
    transcript.append(f'--handling-delivered {g} --watcher-pid {p}: exit={x.returncode}\n{x.stdout}');return x.returncode
try:
    run(['bin/fm-lab-home.sh','create',str(lab)])
    (lab/'tmux').mkdir();(lab/'agent').mkdir()
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'pi','--offline','--no-context-files','--no-skills','--no-prompt-templates','--no-themes','--no-extensions','-e',str(root/'.pi/extensions/fm-primary-pi-watch.ts'),'--session',str(lab/'main.jsonl'))
    time.sleep(2)
    initial=capture('Pi CLI initial isolated home')
    if 'Trust project folder?' in initial:
        tm('send-keys','-t','primary','Down','Down','Enter');time.sleep(2);capture('session-only project trust accepted')
    pane=int(tm('display-message','-p','-t','primary','#{pane_pid}').stdout.strip());(lab/'state/.lock').write_text(str(pane)+'\n')
    command('/fm-watch-arm-pi');wait(lambda:pid()>0,'first watcher');p=pid();wait(lambda:(lab/'state/.last-watcher-beat').exists(),'beacon');capture('watcher armed')
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" downtime'])
    generation=(lab/'state/.watcher-down').read_text().strip().split(':')[-1]
    assert confirm(generation,p)==0
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_recovery_marker_ack "$FM_HOME/state/.watcher-down" "$1"','_',generation])
    before=(lab/'state/.watcher-down').read_text();assert confirm(generation,p)==0;assert (lab/'state/.watcher-down').read_text()==before
    assert confirm('superseded.0.deadbeef',p)==3;assert pid()==p and alive(p)
    assert confirm(generation,99999999)==1
    ident=lab/'state/.watch.lock/pid-identity';original=ident.read_text();ident.write_text('foreign-identity\n');assert confirm(generation,p)==1;ident.write_text(original)
    transcript.append('matching acknowledged generation remained '+before+'; stale generation, dead PID, and foreign identity rejected; healthy watcher preserved\n')
    # Kill the actual arm while its real watcher still holds stdout open: the
    # extension must consider the dead-but-unclosed child an empty slot.
    arms=run(['ps','-o','pid=','-o','ppid=','-p',str(p)]).stdout.split();arm=int(arms[1]);os.kill(arm,signal.SIGKILL);time.sleep(.3);assert alive(p)
    command('/fm-watch-arm-pi');time.sleep(3);out=capture('repair dead arm with live watcher retaining pipes');assert 'started Pi extension arm child' in out
    assert alive(pid());transcript.append(f'killed arm {arm}, real watcher {p} retained pipes; repair started fresh arm\n')
    # End a real watcher unexpectedly; real arm+extension restore continuity.
    old=pid();os.kill(old,signal.SIGKILL);wait(lambda:pid()>0 and pid()!=old,'replacement watcher',400)
    wait(lambda:(lab/'state/.watch-extension.log').exists(),'extension recovery log',400)
    time.sleep(2);capture('unexpected watcher death restored')
    log=(lab/'state/.watch-extension.log').read_text();transcript.append('bounded diagnostic log:\n'+log);assert 0<len(log.splitlines())<=4
    assert alive(pid());transcript.append(f'restored real watcher {old} -> {pid()}\n')
    # Explicit quit is delivered on only the disposable socket.
    command('/quit');time.sleep(2)
    if (lab/'main.jsonl').exists():
        (ev/'pi-live-session.jsonl').write_bytes((lab/'main.jsonl').read_bytes())
        ex=run(['pi','--offline','--export',str(lab/'main.jsonl'),str(ev/'pi-live-session.html')],False)
        transcript.append('Pi HTML export: '+ex.stdout)
    transcript.append('LIVE SCENARIOS PASSED\n')
finally:
    tm('kill-server',check=False)
    run(['bin/fm-watch-arm.sh','--stop'],False)
    (ev/'pi-watcher-live.txt').write_text(''.join(transcript))
    import shutil
    shutil.rmtree(lab,ignore_errors=True)

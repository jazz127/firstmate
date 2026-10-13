import pathlib,subprocess,os,time,shlex,json
r=pathlib.Path.cwd(); h=r/'.lab/h'; e=pathlib.Path('<operator-home>/.no-mistakes/evidence/01M4SDKM6WTX0CEK2C5DQ3RE1K'); env=os.environ.copy()
for k in list(env):
    if k=='FM_GATE_REFUSE_BYPASS' or k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k,None)
env.update(FM_HOME=str(h),FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',TMUX_TMPDIR='.lab/h/tmux',TMPDIR=str(r/'.test-tmp'))
socket=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env,text=True).strip(); env['TMUX']=socket+',501,0'
log=[]; holder=None; result={}
def run(args):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    log.append('$ '+shlex.join(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n'); return p

def count(expected):
    p=run([str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')]); assert p.returncode==0 and p.stdout.strip()==str(expected),p.stdout
try:
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','pending','bash'])
    meta=h/'state/pending.meta'; meta.write_text('backend=tmux\nwindow=primary:pending\nkind=scout\nharness=codex\n')
    (h/'state/pending.status').write_text('done: report complete\n')
    count(0)
    holder=subprocess.Popen(['bash','-c','. "$1"; . "$2"; lock=$(fm_meta_lock_path "$3"); fm_lock_acquire_wait "$lock" || exit; touch "$4"; while [ ! -e "$5" ]; do sleep .1; done; fm_lock_release "$lock"','_',str(r/'bin/fm-backend.sh'),str(r/'bin/fm-wake-lib.sh'),str(meta),str(h/'lock-ready'),str(h/'lock-release')],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    for _ in range(100):
        if (h/'lock-ready').exists(): break
        time.sleep(.1)
    assert (h/'lock-ready').exists()
    count(1)
    run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'])
    p=run([str(r/'bin/fm-spawn.sh'),'candidate',str(h/'absent-project'),'--scout']); assert p.returncode==1 and 'caps concurrent workers' in p.stdout,p.stdout
    p=run([str(r/'bin/fm-afk-return.sh'),'check']); assert p.returncode in (0,3) and '1 task(s) live at return.' in p.stdout,p.stdout
    (h/'lock-release').touch(); holder.wait(timeout=5); count(0)
    result={'name':'A live lifecycle lock reserves a shell-only done endpoint through admission and return until release','result':'pass'}
finally:
    (h/'lock-release').touch()
    if holder is not None: holder.wait(timeout=5)
    (e/'live-reservation-transcript.log').write_text(''.join(log)); (e/'live-reservation-result.json').write_text(json.dumps(result,indent=2))

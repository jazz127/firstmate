import pathlib, subprocess, os, json, time, shlex
r=pathlib.Path.cwd(); h=r/'.lab/h'; e=pathlib.Path('<operator-home>/.no-mistakes/evidence/01M4SDKM6WTX0CEK2C5DQ3RE1K')
env=os.environ.copy()
for k in list(env):
    if k=='FM_GATE_REFUSE_BYPASS' or k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k,None)
env.update(FM_HOME=str(h),FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',TMUX_TMPDIR='.lab/h/tmux',TMPDIR=str(r/'.test-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
socket=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env,text=True).strip()
env['TMUX']=socket+',501,0'
results=[]; transcript=[]
def run(args,timeout=30):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    transcript.append('$ '+shlex.join(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n')
    return p

def count(expected):
    p=run([str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')]); assert p.returncode==0 and p.stdout.strip()==str(expected),p.stdout

def admission(blocked):
    run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'])
    p=run([str(r/'bin/fm-spawn.sh'),'candidate',str(h/'absent-project'),'--scout'])
    assert p.returncode!=0,p.stdout
    assert ('caps concurrent workers' in p.stdout)==blocked,p.stdout
    if not blocked: assert 'No such file or directory' in p.stdout or 'no dispatchable backlog item' in p.stdout,p.stdout

def report(expected):
    p=run([str(r/'bin/fm-afk-return.sh'),'check'])
    assert p.returncode in (0,3),p.stdout
    assert f'{expected} task(s) live at return.' in p.stdout,p.stdout

def scenario(name,fn):
    transcript.append('\nSCENARIO: '+name+'\n')
    try: fn(); results.append(dict(name=name,result='pass'))
    except Exception as ex: results.append(dict(name=name,result='fail',error=str(ex))); raise

def status(s): (h/'state/worker.status').write_text(s)

def snapshots(expected): count(expected); admission(expected==1); report(expected)

try:
    run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'])
    transcript.append('Native model response: '+(h/'native-answer.txt').read_text())
    transcript.append('Native lifecycle event: '+(h/'state/worker.busy-state').read_text())
    scenario('Paused, held and decision-waiting native-idle workers free capacity and return reports zero', lambda: [(status(v+' [key=wait]: awaiting input\n'),snapshots(0)) for v in ['paused','captain-held','needs-decision']])
    scenario('Working and unrecognized events before an unrelated resolution keep the old waiting worker counted', lambda: [(status('needs-decision [key=a]: awaiting input\n'+v+': resumed\nresolved [key=b]: unrelated answer\n'),snapshots(1)) for v in ['working','unexpected-event']])
    scenario('Unrelated resolution preserves an idle pause while resolving the actual wait resumes capacity use', lambda: [(status(s),snapshots(n)) for s,n in [('paused [key=a]: waiting\nresolved [key=b]: unrelated\n',0),('paused [key=a]: waiting\nresolved [key=a]: answered\n',1)]])
    status('paused: waiting\n')
    original=(h/'state/worker.busy-state').read_text()
    def unreadable():
        (h/'state/worker.busy-state').unlink(); snapshots(1)
        (h/'state/worker.busy-state').write_text('malformed\n'); snapshots(1)
        (h/'state/worker.busy-state').write_text(original)
        snapshots(0)
    scenario('Missing and malformed semantic records remain counted despite a paused declaration',unreadable)
    # Invoke real native model with production generation-bound hooks and a bounded Bash operation.
    script=h/'native-resume.sh'
    prompt='Use the Bash tool to run sleep 12. Then reply READY. Do nothing else.'
    script.write_text('#!/usr/bin/env bash\n'+shlex.join(['claude','-p','--setting-sources','project,local','--settings',str(h/'native-hooks.json'),'--allowedTools','Bash(sleep *)','--tools','Bash','--',prompt])+' > '+shlex.quote(str(h/'resume-answer.txt'))+' 2>&1\nprintf "NATIVE_RESUME_EXIT=%s\\n" "$?"\n'+shlex.join(['claude','--setting-sources','project,local','--settings',str(h/'native-hooks.json')])+'\n')
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','resumed','-c',str(h/'projects/demo'),'bash '+shlex.quote(str(script))])
    meta=h/'state/worker.meta'; meta.write_text(meta.read_text().replace('primary:native','primary:resumed'))
    def resumed():
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            record=(h/'state/worker.busy-state').read_text()
            if 'state=busy source=claude-hook' in record: break
            time.sleep(.1)
        else: raise AssertionError('native submitted-turn hook did not arrive')
        transcript.append('Native resumed lifecycle event: '+record)
        snapshots(1)
        deadline=time.monotonic()+55
        while time.monotonic()<deadline:
            record=(h/'state/worker.busy-state').read_text()
            if 'state=idle source=claude-hook' in record and 'READY' in (h/'resume-answer.txt').read_text(): break
            time.sleep(.2)
        else: raise AssertionError('native model did not finish its operation: '+(h/'resume-answer.txt').read_text())
        transcript.append('Native resumed answer: '+(h/'resume-answer.txt').read_text())
        time.sleep(1)
        snapshots(0)
    scenario('A real Claude submitted turn counts while busy and frees room after its native stop hook',resumed)
    def closure():
        run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','raw','sleep 90'])
        meta.write_text('backend=tmux\nwindow=primary:raw\nkind=scout\nharness=custom-agent\n')
        status('working: raw operation\n'); snapshots(1)
        run(['tmux','-L','fm-lab','rename-window','-t','primary:raw','relocated'])
        p=run(['bash','-c','. "$1"; fm_backend_kill_confirmed tmux primary:raw','_',str(r/'bin/fm-backend.sh')])
        assert p.returncode!=0,'absent old target incorrectly acknowledged closure'
        snapshots(1)
        run(['tmux','-L','fm-lab','kill-window','-t','primary:relocated'])
        # Kill acknowledgement at a live endpoint succeeds.
        run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','raw','bash'])
        count(0)
        p=run(['bash','-c','. "$1"; fm_backend_kill_confirmed tmux primary:raw','_',str(r/'bin/fm-backend.sh')]); assert p.returncode==0,p.stdout
    scenario('Raw running operations count; renamed endpoints refuse closure proof; shell-only endpoints free room',closure)
    def unknown():
        meta.write_text('backend=unrecognized\nwindow=unknown:worker\nkind=scout\n')
        status('done: report complete\n'); snapshots(1)
        (h/'state/mate.meta').write_text('backend=unrecognized\nwindow=unknown:mate\nkind=secondmate\n')
        count(1)
        (h/'state/mate.meta').unlink()
        meta.unlink(); count(0)
    scenario('Unknown backends count conservatively while secondmates stay excluded',unknown)
finally:
    (e/'live-product-transcript.log').write_text(''.join(transcript))
    (e/'live-product-results.json').write_text(json.dumps(results,indent=2))

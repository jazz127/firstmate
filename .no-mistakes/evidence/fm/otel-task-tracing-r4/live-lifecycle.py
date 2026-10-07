import os, subprocess, pathlib, time, socket, json, re, signal, shlex, shutil
root=pathlib.Path.cwd(); home=root/'.l'; ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4AJTXSFP6X4C9M1TFE2BGVN')
env=dict(os.environ)
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TASK_ID']:
    env.pop(k,None)
env.update(FM_HOME=str(home),TMUX_TMPDIR=str(home/'tmux'),FM_SEND_SETTLE='0',CODEX_HOME=str(home/'codex'))
socketpath=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env,text=True).strip()
env['TMUX']=socketpath+',0,0'
log=(ev/'live-lifecycle-transcript.txt').open('w',buffering=1)
results=[]
def run(args, expect=None, extra=None, timeout=90):
    log.write('$ '+ ' '.join(map(str,args))+'\n')
    e=dict(env); e.update(extra or {})
    p=subprocess.run(list(map(str,args)),env=e,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    log.write(p.stdout+'\nexit='+str(p.returncode)+'\n')
    if expect is not None: assert p.returncode==expect,p.stdout
    return p

def pane(label):
    p=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-probe'])
    (ev/(label+'.txt')).write_text(p.stdout)
    return p.stdout

def names():
    time.sleep(.4)
    return re.findall(r'Name\s*:\s*(firstmate\.[\w.]+)',(ev/'collector.log').read_text())

def case(name,fn):
    try:
        fn(); results.append(dict(name=name,result='pass')); log.write('OBSERVED: '+name+' passed\n')
    except Exception as ex:
        results.append(dict(name=name,result='fail',error=str(ex))); log.write('FAILED: '+name+' '+str(ex)+'\n')

# Official OpenTelemetry Collector, actual OTLP/HTTP receiver and debug exporter.
config=home/'collector.yaml'
config.write_text('''receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:24318
exporters:
  debug:
    verbosity: detailed
    sampling_initial: 10000
    sampling_thereafter: 1
service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
''')
collectorlog=(ev/'collector.log').open('w')
collector=subprocess.Popen([str(root/'.validation-lab/tools/otelcol'),'--config',str(config)],stdout=collectorlog,stderr=subprocess.STDOUT)
try:
    for i in range(100):
        try:
            with socket.create_connection(('127.0.0.1',24318),.2): break
        except OSError:
            assert collector.poll() is None,'collector exited'
            time.sleep(.1)
    else: raise RuntimeError('collector not listening')
    (home/'config/trace-export.json').unlink(missing_ok=True)
    if (home/'state/probe.inbox').is_dir(): shutil.rmtree(home/'state/probe.inbox')
    meta=home/'state/probe.meta'
    meta.write_text(f'window=primary:fm-probe\nendpoint_task_id=probe\nworktree={home}/wt\nproject={home}/project\nbackend=tmux\nharness=codex\nkind=scout\nmodel=default\neffort=default\ntraceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n')
    # The generated public launch brief's task contract, not source-code inspection.
    brief=home/'data/probe/brief.md'
    text=brief.read_text().replace('{TASK}','Observe the disposable lifecycle validation only. Do not modify project files, launch agents, run pipelines, or access another home.').replace('{FIRSTMATE_SPEC}','Remain idle for validation; when prompted, reply with validation-ready and take no further action.')
    brief.write_text(text)
    (home/'data/projects.md').write_text('- project - disposable validation project (mode: local-only; yolo: off; forge: none)\n')
    run(['tmux','-L','fm-lab','kill-window','-t','primary:fm-probe'],0)
    command=shlex.join(['codex','-c','features.hooks=false','-c',f'projects."{home}/project".trust_level="trusted"','-c',f'projects."{home}/wt".trust_level="trusted"'])+'; exec bash --noprofile --norc'
    run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n','fm-probe','-c',home/'wt','-e',f'CODEX_HOME={home}/codex','bash','-c',command],0)
    for i in range(50):
        ready=pane('worker-ready')
        if 'esc skip' in ready and 'Update available' in ready:
            run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-probe','Escape'],0)
            time.sleep(.3)
            continue
        if 'GPT-' in ready: break
        assert 'Trust this folder?' not in ready, 'Runtime-only trust override did not cover repository root'
        time.sleep(.2)
    assert 'GPT-' in ready, 'Actual Codex did not initialize' 
    def defaultoff():
        run(['bin/fm-send.sh','probe','--key','Escape'],0)
        assert names()==[],names()
    case('Default-off key delivery produces no export',defaultoff)
    auth=home/'auth-header'; auth.write_text('Authorization: Bearer disposable-validation-token\n'); auth.chmod(0o600)
    (home/'config/trace-export.json').write_text(json.dumps({'enabled':True,'endpoint':'http://127.0.0.1:24318/v1/traces','auth-header-file':str(auth)}))
    (home/'state/.lock').write_text(str(os.getpid())+'\n'); (home/'config/trace-context').touch()
    run(['bash','-c','. bin/fm-trace-context-lib.sh; fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"'],0)
    # An actual pending composer prevents the doorbell from submitting an LLM turn.
    run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-probe','-l','pending-validation-text'],0)
    time.sleep(.5)
    def inbox():
        before=names().count('firstmate.steer')
        p=run(['bin/fm-send.sh','probe','privacy-canary-7zQ'],0)
        assert 'durably recorded' in p.stdout and 'doorbell skipped' in p.stdout,p.stdout
        record=home/'state/probe.inbox/001.msg'
        assert record.is_file() and 'privacy-canary-7zQ' in record.read_text()
        assert names().count('firstmate.steer')==before+1,names()
        received=(ev/'collector.log').read_text()
        assert 'firstmate.plane: Str(inbox)' in received,received[-4000:]
        assert 'privacy-canary-7zQ' not in received
        for forbidden in ['firstmate.sequence','firstmate.correlation','firstmate.decision']:
            assert forbidden not in received
        (ev/'delivered-inbox-record.txt').write_text(record.read_text())
    case('Durable inbox delivery exports aggregate dimensions without message contents',inbox)
    def decision():
        before=names().count('firstmate.steer')
        status=home/'state/probe.status'; status.write_text('needs-decision [key=live-choice]: choose A or B\n')
        run(['bin/fm-send.sh','probe','--resolve-key','live-choice','decision-answer-canary-A'],0)
        assert 'resolved [key=live-choice]' in status.read_text(),status.read_text()
        assert names().count('firstmate.steer')==before+1,names()
        received=(ev/'collector.log').read_text()
        assert 'decision-answer-canary-A' not in received and 'live-choice' not in received
        (ev/'decision-status.txt').write_text(status.read_text())
    case('Decision answer closes the hold and exports no decision or answer identities',decision)
    def refused():
        before=names()
        for args in [['bin/fm-send.sh','probe','   '],['bin/fm-send.sh','probe','--key','Enter','--resolve-key','forbidden'],['bin/fm-control.sh','primary:fm-probe','interrupt']]:
            assert run(args).returncode!=0
        assert names()==before,names()
    case('Empty steer key-answer combination and unowned control are refused without export',refused)
    def key():
        before=names().count('firstmate.steer')
        run(['bin/fm-send.sh','probe','--key','Escape'],0)
        assert names().count('firstmate.steer')==before+1
        assert 'firstmate.plane: Str(key)' in (ev/'collector.log').read_text()
    case('Delivered Escape key exports one key-plane observation',key)
    run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-probe','C-u'],0); time.sleep(.5)
    def typed():
        before=names().count('firstmate.steer')
        run(['bin/fm-send.sh','probe','/status'],0)
        assert names().count('firstmate.steer')==before+1,names()
        assert 'firstmate.plane: Str(typed)' in (ev/'collector.log').read_text()
        assert 'Account:' in pane('typed-status'), 'status output missing'
    case('Harness-native status submission exports only after confirmed acceptance',typed)

    def interrupted():
        before=names()
        run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-probe','Escape'],0)
        p=subprocess.Popen(['bin/fm-send.sh','probe','/status'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        typed=False
        for i in range(300):
            rendered=subprocess.check_output(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-probe'],env=env,text=True)
            if re.search(r'^› /status\s*$',rendered,re.M):
                typed=True
                (ev/'interrupted-composer.txt').write_text(rendered)
                os.killpg(p.pid,signal.SIGTERM)
                break
            if p.poll() is not None: break
            time.sleep(.01)
        out,_=p.communicate(timeout=10)
        log.write('$ bin/fm-send.sh probe /status (TERM after actual composer typing, before Enter)\n'+out+'\nexit='+str(p.returncode)+'\n')
        assert typed and p.returncode!=0, 'Could not interrupt before submission'
        assert names()==before,names()
        run(['tmux','-L','fm-lab','send-keys','-t','primary:fm-probe','C-u'],0)
    case('Interrupted typed delivery before Enter exports no success observation',interrupted)
    def interrupt():
        before=names().count('firstmate.control')
        p=run(['bin/fm-control.sh','probe','interrupt'],0)
        assert 'verified=agent-alive' in p.stdout,p.stdout
        assert names().count('firstmate.control')==before+1,names()
        received=(ev/'collector.log').read_text()
        assert 'firstmate.control.verb: Str(interrupt)' in received
        assert 'firstmate.control.confirmed: Str(false)' in received
    case('Verified interrupt preserves the agent and distinguishes unconfirmed cancellation',interrupt)
    def promote():
        before=names().count('firstmate.promote')
        run(['bin/fm-promote.sh','probe','--mode','local-only','--yolo','off'],0)
        assert 'kind=ship\n' in meta.read_text() and 'mode=local-only\n' in meta.read_text()
        assert (home/'data/probe/ship-instructions.md').is_file()
        assert names().count('firstmate.promote')==before+1,names()
        received=(ev/'collector.log').read_text()
        assert 'firstmate.task.kind: Str(ship)' in received and 'firstmate.task.kind.prior: Str(scout)' in received
        (ev/'promoted-meta.txt').write_text(meta.read_text())
    case('Scout promotion publishes ship metadata before its lifecycle observation',promote)
    def rejectedpromotion():
        before=names(); prior=meta.read_bytes()
        assert run(['bin/fm-promote.sh','probe','--mode','local-only','--yolo','off']).returncode!=0
        assert names()==before and prior==meta.read_bytes()
    case('Re-promoting a ship is refused without metadata change or export',rejectedpromotion)
    def offswitch():
        before=names()
        run(['bin/fm-send.sh','probe','--key','Escape'],0,{'FM_TRACE_EXPORT':'off'})
        assert names()==before
    case('Explicit export off switch suppresses successful lifecycle delivery',offswitch)

    def relaunch():
        before=names().count('firstmate.control')
        old=meta.read_text()
        p=run(['bin/fm-control.sh','probe','relaunch','--note','Validation only: remain idle, do not modify files or run pipelines.'],0,timeout=120)
        assert 'relaunched probe' in p.stdout,p.stdout
        assert names().count('firstmate.control')==before,names()
        new=meta.read_text()
        assert 'window=primary:fm-probe' in new and f'worktree={home}/wt' in new
        assert 'spawn_gen=' in new and new!=old
        assert names().count('firstmate.spawn')>=1,names()
        pane('relaunched-worker')
    case('Relaunch replaces the real harness without counting its internal stop as interrupt or exit',relaunch)
    def stop():
        before=names().count('firstmate.control')
        marker=home/'wt/uncommitted-validation.txt'; marker.write_text('preserve this uncommitted work\n')
        p=run(['bin/fm-control.sh','probe','exit'],0)
        assert 'stopped probe' in p.stdout,p.stdout
        assert names().count('firstmate.control')==before+1,names()
        assert marker.read_text()=='preserve this uncommitted work\n'
        run(['tmux','-L','fm-lab','has-session','-t','primary'],0)
        rendered=pane('stopped-worker')
        assert 'firstmate.control.verb: Str(exit)' in (ev/'collector.log').read_text()
    case('Verified exit emits one observation and preserves endpoint and uncommitted work',stop)
    def idempotent():
        before=names().count('firstmate.control')
        p=run(['bin/fm-control.sh','probe','exit'],0)
        assert 'already-stopped' in p.stdout,p.stdout
        assert names().count('firstmate.control')==before+1
    case('Already-stopped exit reports the verified postcondition and exports successfully',idempotent)
finally:
    collector.terminate()
    try: collector.wait(10)
    except subprocess.TimeoutExpired: collector.kill(); collector.wait()
    collectorlog.close()
    (ev/'live-results.json').write_text(json.dumps(results,indent=2))
    log.close()
print(json.dumps(results,indent=2))

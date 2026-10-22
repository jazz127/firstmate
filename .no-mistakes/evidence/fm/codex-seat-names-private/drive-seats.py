import json, os, pathlib, shlex, shutil, subprocess, tempfile
ROOT = pathlib.Path.cwd()
EV = pathlib.Path('~/.no-mistakes/evidence/01M5J2004G7W3164824QGJGPGV')
log = []
lab = pathlib.Path(tempfile.mkdtemp(prefix='.seat-validation-', dir=ROOT))
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'CMUX_', 'CODEX_', 'OPENAI_', 'TYPESAFE_', 'TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE')}
env.update(HOME=str(lab/'os-home'), FM_HOME=str(lab), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
(lab/'os-home').mkdir()
# Lab helper requires a fresh empty directory, so the operational home is separate.
home = lab/'home'
env['FM_HOME'] = str(home)

def run(args, expect=0, overrides=None):
    e=env.copy(); e.update(overrides or {})
    p=subprocess.run([str(a) for a in args], cwd=ROOT, env=e, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=50)
    log.append('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+'[exit '+str(p.returncode)+']\n')
    assert p.returncode == expect, (args, p.returncode, p.stdout)
    return p.stdout

def record(seats, target=home):
    (target/'config').mkdir(parents=True, exist_ok=True)
    (target/'config/dock.json').write_text(json.dumps({'version':1,'id':'disposable-dock','seats':{k:{'harness':'codex','credential_home':str(v)} for k,v in seats.items()}}))

def dock(name, expect=0, overrides=None, harness='codex'):
    return run(['bash','bin/fm-dock.sh','resolve','--seat',name,'--harness',harness], expect, overrides)

try:
    # A real consumer of disposable private configuration, no service substitutes.
    run(['bash','bin/fm-lab-home.sh','create',home])
    paths=[lab/'credentials one', lab/"credentials $(literal) 'two'", lab/'credentials three']
    for p in paths: p.mkdir()
    record({'before-name':paths[0]})
    assert 'seat=before-name' in dock('before-name')
    record({'renamed-27':paths[0], 'build-3':paths[1], '9':paths[2]})
    for name,path in zip(['renamed-27','build-3','9'],paths):
        out=dock(name)
        assert 'credential_home='+str(path) in out and 'source=dock.json' in out
    assert 'does not bind seat before-name' in dock('before-name',1)
    log.append('OBSERVED: editing only private dock.json renamed one seat and added two independently resolved seats.\n')
    # Before/after regression uses the actual base CLI and library, with identical config.
    base=lab/'base'; base.mkdir()
    for name in ['fm-dock.sh','fm-dock-lib.sh']:
        content=subprocess.check_output(['git','show','c6034e03f504346dc462a050bec0bddd9a645148:bin/'+name],cwd=ROOT)
        (base/name).write_bytes(content)
    out=run(['bash',base/'fm-dock.sh','resolve','--seat','renamed-27','--harness','codex'],1, {'FM_CONFIG_OVERRIDE':str(home/'config')})
    assert 'unsupported dock seat' in out
    log.append('OBSERVED: unchanged base CLI rejects renamed-27; target CLI resolves it with the same private record.\n')
    # Length/character boundary from docs/configuration.md, not implementation regex.
    for name in ['a','0','a-b','a'*64]:
        record({name:paths[0]}); assert 'seat='+name in dock(name)
    invalid=['','-start','Upper','under_score','dot.name','slash/name','space name','a'*65,'line\n','nul\x00']
    # NUL cannot be passed in OS argv; it remains a JSON key tested as unselected.
    for name in invalid:
        record({name:paths[0], 'valid':paths[1]})
        if '\x00' not in name: assert 'no ambient account selected' in dock(name,1)
        assert 'no ambient account selected' in dock('valid',1)
    record({'valid':paths[0]})
    assert 'no ambient account selected' in dock('valid',1,harness='claude')
    # A home cannot borrow another home's record or the caller's ambient path.
    other=lab/'other-home'; record({'valid':paths[2]},other)
    assert 'credential_home='+str(paths[2]) in dock('valid',overrides={'FM_HOME':str(other)})
    assert 'credential_home='+str(paths[0]) in dock('valid')
    (home/'config/dock.json').unlink()
    for name in ['valid','luna','main']:
        assert 'is absent' in dock(name,1, {'CODEX_HOME':str(paths[0])})
    record({'valid':paths[0]})
    assert 'does not bind seat unconfigured' in dock('unconfigured',1,{'CODEX_HOME':str(paths[0])})
    log.append('OBSERVED: unsafe selected and unselected keys, unsupported harness, absent records, and absent bindings all refuse; per-home paths remain independent.\n')
    # Exercise public startup diagnostic against real tools, only its local read-only mode.
    dispatch=home/'config/crew-dispatch.json'
    dispatch.write_text(json.dumps({'rules':[], 'default':[{'harness':'codex','seat':'valid'},{'harness':'codex','seat':'9'}]}))
    record({'valid':paths[0],'9':paths[2]})
    bootstrap_env={'FM_BOOTSTRAP_DETECT_ONLY':'1','FM_BOOTSTRAP_NETWORK':'skip','FM_BOOTSTRAP_VERBOSE_FACTS':'1'}
    out=run(['bash','bin/fm-bootstrap.sh'],overrides=bootstrap_env)
    assert 'CREW_DISPATCH: invalid' not in out
    # Trigger only resolver preflight: empty rules deliberately end before the API.
    preflight_env={'TYPESAFE_API_KEY':'local-preflight-only-not-a-credential'}
    brief=home/'brief.md'; brief.write_text('## Captain\'s intent\nExercise private seat configuration.\n')
    out=run(['bash','bin/fm-dispatch-resolve.sh',brief],overrides=preflight_env)
    assert 'reason: no rules to match' in out
    for name in ['bad_name','a'*65,'line\n']:
        dispatch.write_text(json.dumps({'default':{'harness':'codex','seat':name}}))
        out=run(['bash','bin/fm-bootstrap.sh'],overrides=bootstrap_env)
        assert 'unsupported default profile seat' in out
        out=run(['bash','bin/fm-dispatch-resolve.sh',brief],2,preflight_env)
        assert 'unsupported default profile seat' in out
    dispatch.write_text(json.dumps({'default':{'harness':'codex','seat':'unconfigured'}}))
    out=run(['bash','bin/fm-dispatch-resolve.sh',brief],2,preflight_env)
    assert 'does not bind seat unconfigured' in out
    log.append('OBSERVED: startup and resolver preflight accept private names, reject unsafe names, and resolver rejects undeclared bindings before network. No Typesafe service response was supplied or simulated.\n')
    # Real installed Codex, empty isolated credential home: no synthetic auth file.
    run(['codex','--version'])
    out=run(['codex','login','status','-c','cli_auth_credentials_store="file"','-c','model_provider="openai"'],1,{'CODEX_HOME':str(paths[0])})
    assert 'Not logged in' in out
    # Spawn runs the actual refusal path, no fake pane/backend and no launch.
    out=run(['bash','bin/fm-spawn.sh','seat-auth-probe',ROOT,'--scout','--harness','codex','--seat','valid'],1)
    assert 'no ordinary readable file-backed sign-in' in out
    assert not (home/'state/seat-auth-probe.meta').exists()
    out=run(['bash','bin/fm-spawn.sh','seat-auth-probe',ROOT,'--scout','--harness','codex','--seat','bad_name'],1)
    assert 'invalid --seat' in out
    assert not (home/'state/seat-auth-probe.meta').exists()
    log.append('OBSERVED: real fm-spawn accepts the configured label through dock resolution, then refuses the empty login before publishing task metadata. An authenticated worker/model request was not possible with this disposable empty credential home.\n')
finally:
    shutil.rmtree(lab)
    log.append('CLEANUP: removed the entire disposable lab; no backend session was started.\n')
    (EV/'live-seat-transcript.txt').write_text('\n'.join(log))
print('Live private-configuration, guard, bootstrap, resolver preflight, and unauthenticated spawn checks completed. Transcript retained.')

import json, os, pathlib, subprocess, tempfile, shutil
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4687SB7R6HXT3B6F34XJ7FP')
lab=pathlib.Path(tempfile.mkdtemp(prefix='seat-lab-',dir=root/'.local-test-tmp'))
log=[]
env={'PATH':os.environ['PATH'],'HOME':str(lab/'os-home'),'TMPDIR':str(root/'.local-test-tmp'),'FM_HOME':str(lab),'FM_BACKEND':'tmux','FM_BOOTSTRAP_DETECT_ONLY':'1','FM_BOOTSTRAP_NETWORK':'skip'}
def run(label,args,code=0,contains=None,extra=None,filter_bootstrap=False):
    p=subprocess.run(args,env=env| (extra or {}),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
    out=p.stdout
    shown='\n'.join(s for s in out.splitlines() if s.startswith('CREW_DISPATCH:')) if filter_bootstrap else out.strip()
    log.append(f'$ {label}\nexit={p.returncode}\n{shown or "(no crew-dispatch diagnostic)"}\n')
    assert p.returncode==code, (label,p.returncode,out)
    if contains: assert contains in out,(label,out)
    return out
try:
    run('bash bin/fm-lab-home.sh create <disposable-worktree-home>',['bash','bin/fm-lab-home.sh','create',str(lab)])
    for d in ['os-home','credentials/main','credentials/luna','project']:(lab/d).mkdir(parents=True,exist_ok=True)
    seats={name:{'harness':'codex','credential_home':str(lab/'credentials'/name)} for name in ['main','luna']}
    dock=lab/'config/dock.json'
    dock.write_text(json.dumps({'version':1,'id':'isolated-seat-lab','seats':seats}))
    before=dock.read_bytes()
    for seat in ['main','luna']:
        run(f'FM_HOME=<lab> bash bin/fm-dock.sh resolve --seat {seat} --harness codex',['bash','bin/fm-dock.sh','resolve','--seat',seat,'--harness','codex'],contains='credential_home='+seats[seat]['credential_home'])
    assert dock.read_bytes()==before
    run('unknown seat refuses',['bash','bin/fm-dock.sh','resolve','--seat','other','--harness','codex'],1,'no ambient account selected')
    run('main on Claude refuses',['bash','bin/fm-dock.sh','resolve','--seat','main','--harness','claude'],1,'no ambient account selected')
    run('git init disposable project',['git','init','-q','-b','main',str(lab/'project')])
    run('scaffold disposable scout brief',['bash','bin/fm-brief.sh','probe','seat-lab','--scout'])
    brief=lab/'data/probe/brief.md'
    brief.write_text(brief.read_text().replace('{TASK}','Inspect only this disposable project and report the selected seat.').replace('{FIRSTMATE_SPEC}','Do not change any files.'))
    for seat in ['main','luna']:
        run(f'fm-spawn --scout --harness codex --seat {seat}: missing sign-in refuses',['bash','bin/fm-spawn.sh','probe',str(lab/'project'),'--scout','--harness','codex','--seat',seat],1,'no ordinary readable file-backed sign-in',{'CODEX_HOME':str(lab/'credentials'/('luna' if seat=='main' else 'main'))})
        assert not (lab/'state/probe.meta').exists()
    run('fm-spawn mismatched measured seat home refuses',['bash','bin/fm-spawn.sh','probe',str(lab/'project'),'--scout','--harness','codex','--seat','main','--seat-home',seats['luna']['credential_home']],1,'profile was measured against')
    saved=seats.pop('main')
    dock.write_text(json.dumps({'version':1,'id':'isolated-seat-lab','seats':seats}))
    run('fm-spawn missing main binding refuses rather than selecting Luna',['bash','bin/fm-spawn.sh','probe',str(lab/'project'),'--scout','--harness','codex','--seat','main'],1,'does not bind seat main')
    dock.unlink()
    run('main without dock refuses even on legacy-compatible host',['bash','bin/fm-dock.sh','resolve','--seat','main','--harness','codex'],1,'configure seat main',{'HOME':'/Users/jarad'})
    seats['main']=saved
    dock.write_text(json.dumps({'version':1,'id':'isolated-seat-lab','seats':seats}))
    rules=lab/'config/crew-dispatch.json'
    rules.write_text(json.dumps({'rules':[{'when':'Seat tasks','use':{'harness':'codex','seat':'main'}}],'default':{'harness':'codex','seat':'luna'}}))
    out=run('real bootstrap accepts string main and luna profiles',['bash','bin/fm-bootstrap.sh'],filter_bootstrap=True)
    assert 'CREW_DISPATCH:' not in out,out
    # This sentinel merely activates input validation; every request must be
    # rejected as a configuration error before reaching any upstream service.
    for val in [[],['main'],['luna'],['main','luna'],None,{},False,0,'other']:
        for loc in ['use','default']:
            for shape in ['object','array']:
                profile={'harness':'codex','seat':val}
                if shape=='array':profile=[profile]
                cfg={'rules':[{'when':'Seat tasks','use':profile if loc=='use' else {'harness':'codex'}}]}
                if loc=='default':cfg['default']=profile
                rules.write_text(json.dumps(cfg))
                label=f'{loc} {shape} seat={json.dumps(val)}'
                run('resolver rejects '+label,['bash','bin/fm-dispatch-resolve.sh',str(brief)],2,'unsupported '+loc+' profile seat',{'TYPESAFE_API_KEY':'validation-only-no-request'})
        # Bootstrap production validator, one representative of each bad type.
        rules.write_text(json.dumps({'default':{'harness':'codex','seat':val}}))
        run('bootstrap diagnoses default seat='+json.dumps(val),['bash','bin/fm-bootstrap.sh'],contains='unsupported default profile seat',filter_bootstrap=True)
    log.append('All commands used real installed product CLIs; no CLI/service substitutes.\nRejected resolver inputs used an opt-in sentinel solely to reach the configuration validator; no request was made.\nNo authenticated credential homes or TYPESAFE_API_KEY were supplied for successful upstream scenarios.\n')
finally:
    shutil.rmtree(lab)
    log.append('Disposable lab, project, and credential directories removed.\n')
    (ev/'live-seat-guards.log').write_text('\n'.join(log))
print('Live product bindings and guards completed; transcript: '+str(ev/'live-seat-guards.log'))

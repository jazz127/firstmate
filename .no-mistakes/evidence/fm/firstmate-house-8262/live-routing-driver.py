import os, pathlib, tempfile, subprocess, json, time, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M750V5HM86FSEERS94RGJ55B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.fm-lab.',dir=root))
log=(evidence/'live-routing.txt').open('w')
results=[]
socketdir=None
original_seat=os.environ.get('CODEX_HOME',str(pathlib.Path.home()/'.codex'))
def note(s):
    log.write(str(s)+'\n'); log.flush()
def run(args,env=None,cwd=None,timeout=180):
    p=subprocess.run([str(x) for x in args],env=env,cwd=cwd or root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    return p.returncode,p.stdout
def must(args,**kw):
    rc,out=run(args,**kw)
    if rc: raise RuntimeError(f'{args[0]} exited {rc}: {out}')
    return out.strip()
def record(id,harness='codex',model=None,effort='low',seat='devprimary',status='clear'):
    d=lab/'data'/id; d.mkdir(exist_ok=True)
    (d/'brief.md').write_text("# Task\n## Captain's intent\nVerify a disposable worker launch. Reply LIVE_DISPATCH_ACK once and stop. Do not run tools or change any files.\n\n## Firstmate spec\nThis is a disposable live CLI check. Reply LIVE_DISPATCH_ACK once and stop. Do not run any commands, skills, or tools.\n")
    (d/'dispatch-resolution.json').write_text(json.dumps(dict(task=id,status=status,profile=dict(harness=harness,model=model,effort=effort,seat=seat) if status=='clear' else None)))
def call(name,id,flags,expected,needle=None,scout=False):
    args=[str(root/'bin/fm-spawn.sh'),id,str(lab/'project')]
    args+=['--scout'] if scout else ['--mode','local-only','--yolo','off']
    args+=flags
    note('\n$ bin/fm-spawn.sh '+' '.join(args[1:]))
    rc,out=run(args,env=env)
    note(out); note(f'exit={rc}')
    meta=lab/'state'/f'{id}.meta'
    if meta.exists(): note('persisted metadata:\n'+meta.read_text())
    ok=rc==expected and (not needle or needle in out)
    if expected!=0: ok=ok and not meta.exists()
    results.append(dict(name=name,pass_check=ok,exit=rc))
    return rc
try:
    must([root/'bin/fm-lab-home.sh','create',lab])
    for d in ('user','tmp','cache','unsigned','other-seat'): (lab/d).mkdir()
    socketdir=must([root/'bin/fm-lab-home.sh','tmux-dir',lab])
    env={'HOME':str(lab/'user'),'PATH':os.environ['PATH'],'TERM':'xterm-256color','LANG':'en_US.UTF-8','FM_HOME':str(lab),'TMPDIR':str(lab/'tmp'),'XDG_CACHE_HOME':str(lab/'cache'),'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','TREEHOUSE_ROOT':str(lab/'pool'),'TMUX_TMPDIR':socketdir,'CODEX_HOME':original_seat}
    tmux=['tmux','-L','fm-lab']
    must(tmux+['-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',root,'/bin/bash --noprofile --norc'],env=env)
    must(tmux+['set-option','-g','default-shell','/bin/bash'],env=env)
    must(tmux+['set-option','-g','default-command','/bin/bash --noprofile --norc'],env=env)
    env['TMUX']=must(tmux+['display-message','-p','-t','primary','#{socket_path},#{pid},#{session_id}'],env=env).replace('$','')
    note('Driver: real fm-spawn CLI, real tmux private fm-lab server (120x40), real Treehouse, installed Codex CLI; no tool substitutes. Disposable dispatch records seeded as input data. devprimary and luna are lab aliases to the same existing Codex login; unsigned is an empty disposable credential home.')
    project=lab/'project'; project.mkdir()
    must(['git','init','-q','-b','main',project],env=env)
    (project/'README.md').write_text('Disposable live spawn verification.\n')
    must(['git','-C',project,'add','README.md'],env=env)
    must(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','Initialize disposable project'],env=env)
    (lab/'config/crew-dispatch.json').write_text(json.dumps(dict(shared_quota=True,rules=[dict(when='Disposable launch verification',use=dict(harness='codex',seat='devprimary',effort='low'))],default=dict(harness='codex',seat='devprimary'))))
    seats={k:dict(harness='codex',credential_home=v) for k,v in [('devprimary',original_seat),('luna',original_seat),('unsigned',str(lab/'unsigned'))]}
    (lab/'config/dock.json').write_text(json.dumps(dict(version=1,id='live-dispatch-lab',seats=seats)))
    note('Codex authentication status: '+must(['codex','login','status'],env=env))
    # Acceptance is dispatch refusal/launch and recorded identity. Stop at the
    # actual Codex folder-trust surface; accepting would modify operator config.
    for kind in ('matching','override','scout'):
        id='routing-'+kind; record(id)
        flags=['--harness','codex','--effort','low','--seat','devprimary' if kind=='matching' else 'luna']
        if kind=='matching': flags+=['--seat-home',original_seat]
        else: flags+=['--dispatch-override=standing worker seat rule']
        rc=call(kind+' seated worker launch',id,flags,0,scout=kind=='scout')
        if rc==0:
            meta=(lab/'state'/f'{id}.meta').read_text()
            target=next(x.split('=',1)[1] for x in meta.splitlines() if x.startswith('window='))
            time.sleep(2)
            c,o=run(tmux+['capture-pane','-p','-t',target,'-S','-60'],env=env)
            note('Actual worker TUI (no trust decision submitted):\n'+o)
            (evidence/f'routing-{kind}-pane.txt').write_text(o)
    ids=['routing-batch-a','routing-batch-b']
    record(ids[0]); record(ids[1],seat='luna')
    args=[root/'bin/fm-spawn.sh']+[f'{id}={project}' for id in ids]+['--mode','local-only','--yolo','off','--harness','codex','--effort','low','--seat','luna','--dispatch-override','standing worker seat rule']
    note('\n$ '+' '.join(str(x) for x in args))
    rc,out=run(args,env=env,timeout=300); note(out); note(f'exit={rc}')
    ok=rc==0
    for id in ids:
        meta=lab/'state'/f'{id}.meta'
        if not meta.exists(): ok=False; continue
        text=meta.read_text(); note('Persisted '+id+' metadata:\n'+text)
        ok=ok and 'seat=luna\n' in text and 'dispatch_override=standing worker seat rule\n' in text
        target=next(x.split('=',1)[1] for x in text.splitlines() if x.startswith('window='))
        c,o=run(tmux+['capture-pane','-p','-t',target,'-S','-60'],env=env)
        note('Actual batch worker TUI:\n'+o)
    results.append(dict(name='two-task batch forwards seat and reason independently',pass_check=ok,exit=rc))
    note('\nScenario observations:\n'+json.dumps(results,indent=2))
    (evidence/'live-routing-observations.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    if socketdir:
        rc,out=run(['tmux','-S',f'{socketdir}/tmux-{os.getuid()}/fm-lab','kill-server'],env=env)
        note(f'Private tmux kill-server exit={rc}: {out.strip()}')
        rc,out=run([root/'bin/fm-lab-home.sh','teardown',lab])
        note(f'Lab socket cleanup exit={rc}: {out.strip()}')
    for base,dirs,files in os.walk(lab): os.chmod(base,0o700)
    shutil.rmtree(lab)
    note('Removed disposable lab home, repository, worktree pool and data.'); log.close()

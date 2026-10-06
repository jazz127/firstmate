import os,sys,time,json,shutil,signal,subprocess,re
from pathlib import Path
ROOT=Path.cwd(); W=ROOT/'.test-live'; E=Path('/Users/jarad/.no-mistakes/evidence/01M48RKGRN8MZABF6PR8SCS3NE')
BASE=os.environ.copy(); LOG=open(E/'live-product-transcript.log','a',buffering=1)
RESULTS=json.loads((E/'live-results.json').read_text()) if (E/'live-results.json').exists() else []; ACTIVE=[]
def run(args,env=BASE,cwd=ROOT,ok=True,timeout=45):
    LOG.write('\n$ '+str(args)+'\n')
    p=subprocess.run([str(x) for x in args],env=env,cwd=cwd,text=True,capture_output=True,timeout=timeout)
    LOG.write(p.stdout+p.stderr+'\nexit: '+str(p.returncode)+'\n')
    if ok and (p.returncode or p.stdout.startswith('error:')): raise RuntimeError(p.stdout+p.stderr)
    return p

def wait(pred,label,seconds=30):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=pred()
        if value:return value
        time.sleep(.1)
    raise RuntimeError('Timed out: '+label)
def chrome(*args):return run(['chrome-devtools-axi',*args])
def ui(js):return chrome('eval',js).stdout

def text_contains(text):
    return 'true' in ui('() => document.body.innerText.includes('+json.dumps(text)+')')
def send(message,end=False):
    ui('() => { const t=document.querySelector("textarea"); t.value='+json.dumps(message)+'; t.dispatchEvent(new Event("input",{bubbles:true})); document.getElementById('+json.dumps('sendAndEnd' if end else 'send')+').click(); return "clicked"; }')
def pe(env,*args,**kw):return run([ROOT/'bin/fm-procevent.sh',*args],env=env,**kw)
def lavish(env,*args,**kw):return run([ROOT/'bin/fm-procevent-lavish.sh',*args],env=env,**kw)
def task(env,*args,**kw):return run([ROOT/'bin/fm-captain-hold.sh',*args],env=env,**kw)
def captures(env,id):return list((Path(env['FM_HOME'])/'state/procevent-inbox').glob(id+'.*.result'))
def wait_capture(env,id,n):return wait(lambda:len(captures(env,id))==n,'capture '+id+' '+str(n))
def screenshot(name):chrome('screenshot',str(E/(name+'.png')))
def result(name):
    RESULTS.append({'name':name,'result':'pass'}); (E/'live-results.json').write_text(json.dumps(RESULTS,indent=2)); print('PASS '+name,flush=True)
def prepare(name,version):
    home=W/name
    if home.exists(): shutil.rmtree(home)
    run([ROOT/'bin/fm-lab-home.sh','create',home]); ACTIVE.append(home)
    env=BASE.copy();env['FM_HOME']=str(home);env['PATH']=(str(W/'modern/node_modules/.bin')+os.pathsep+BASE['PATH']) if version=='modern' else BASE['PATH']
    art=W/(name+'-'+str(os.getpid())+'.html');shutil.copyfile(W/'board.html',art)
    cli='lavish-axi'; p=run([cli,art,'--no-open','--no-gate'],env=env)
    sessions=json.loads((W/'lavish-state/state.json').read_text())['sessions']; sess=next(s for s in sessions.values() if s['file']==str(art))
    chrome('open',sess['url']+'?no-gate=1')
    id=lavish(env,'source-id',art).stdout.strip(); return env,art,id

def main_flow(version):
    name=version+'-conversation';env,art,id=prepare(name,version)
    # A fresh reply arm must post before it waits, retaining caller-owned bytes.
    reply=W/(name+'-fresh.md');reply.write_text('Firstmate is ready to review this private atlas.\n')
    lavish(env,'arm',art,'--agent-reply-file',reply)
    wait(lambda:text_contains('Firstmate is ready to review'),'fresh reply visible')
    assert reply.read_text()=='Firstmate is ready to review this private atlas.\n'
    send('Can firstmate answer back on this page?');wait_capture(env,id,1)
    pe(env,'reconcile') # Restore the waiting monitor before replacing it with the answer.
    reply.write_text('Yes. Firstmate can answer here and continue receiving your feedback.\n')
    lavish(env,'arm',art,'--agent-reply-file',reply)
    wait(lambda:text_contains('Yes. Firstmate can answer here'),'replacement reply visible')
    screenshot(name)
    # An invalid file must leave the current listener serving the page.
    old=(Path(env['FM_PROCEVENT_CLAIM_ROOT'])/(id+'.claim')).read_text().splitlines()[1]
    p=lavish(env,'arm',art,'--agent-reply-file',W/'missing.md',ok=False)
    assert p.returncode and 'does not exist' in p.stderr
    assert (Path(env['FM_PROCEVENT_CLAIM_ROOT'])/(id+'.claim')).read_text().splitlines()[1]==old
    # Another home cannot replace the live owner of this same source.
    other=W/(name+'-foreign')
    if other.exists(): shutil.rmtree(other)
    run([ROOT/'bin/fm-lab-home.sh','create',other]);ACTIVE.append(other)
    foreign=env.copy();foreign['FM_HOME']=str(other)
    p=lavish(foreign,'arm',art,'--agent-reply-file',reply,ok=False)
    assert p.returncode
    assert (Path(env['FM_PROCEVENT_CLAIM_ROOT'])/(id+'.claim')).read_text().splitlines()[1]==old
    send('Second message after the reply.');wait_capture(env,id,2)
    pe(env,'reconcile')
    ui_reply_count=ui('() => [...document.querySelectorAll(".chat-message, .chat-entry, .message")].map(x=>x.innerText)')
    # The persisted Lavish chat contract is the oracle for consumed-reply replay.
    state=json.loads((W/'lavish-state/state.json').read_text())
    sess=next(s for s in state['sessions'].values() if s['file']==str(art))
    (E/(name+'-session.json')).write_text(json.dumps(sess,indent=2))
    assert json.dumps(sess).count('Yes. Firstmate can answer here and continue receiving your feedback.')==1
    for f in captures(env,id):shutil.copyfile(f,E/(name+'-'+f.name))
    result(name+' fresh reply, active replacement, continued feedback, missing-file and foreign-owner refusal')
    lavish(env,'retire',art);run(['lavish-axi','end',art],env=env)

def bound_flow(version,boundary,terminal):
    name=version+'-'+('terminal' if terminal else 'bound')+'-'+boundary
    env,art,id=prepare(name,version);home=Path(env['FM_HOME'])
    shutil.copyfile(ROOT/'.tasks.toml',home/'.tasks.toml');(home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    for tid in ['sample-reconcile-call','sample-keyed-answer']:
        run(['tasks-axi','add',tid,'Captain call '+tid,'--repo','sample'],env=env,cwd=home)
        task(env,'hold',tid,'--reason','waiting for the captain')
    task(env,'bind',id);lavish(env,'arm',art)
    wait(lambda:text_contains('Conversation'),'page ready')
    wait(lambda:(Path(env['FM_PROCEVENT_CLAIM_ROOT'])/(id+'.claim')).exists(),'claim ready')
    claim=(Path(env['FM_PROCEVENT_CLAIM_ROOT'])/(id+'.claim')).read_text().splitlines();pid=int(claim[1]);token=claim[2]
    lockproc=None;release=W/(name+'.release');ready=W/(name+'.ready')
    try:
        if boundary=='precommit':
            # Suspend only the real runner, allowing its real Lavish child to finish.
            os.kill(pid,signal.SIGSTOP);LOG.write('SIGSTOP isolated runner '+str(pid)+' before real feedback\n')
        else:
            # Ordinary task-control contention pauses the actual intake after durable capture.
            lockscript='. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2"; trap \'fm_lock_release "$2"\' EXIT; touch "$3"; while [ ! -e "$4" ]; do sleep 0.05; done'
            lockproc=subprocess.Popen(['bash','-c',lockscript,'_',str(ROOT),str(home/'state/.control-sample-reconcile-call.lock'),str(ready),str(release)],env=env,stdout=LOG,stderr=LOG)
            wait(lambda:ready.exists(),'task lock ready')
        for label in ['Queue Reconcile','Queue Accepted']:
            snap=chrome('snapshot').stdout
            ref=re.search(r'uid=(\S+) button '+re.escape(json.dumps(label)),snap).group(1)
            chrome('click','@'+ref.split(':')[-1])
        if terminal: screenshot(name+'-queued')
        send('Final decisions.' if terminal else 'Please apply these decisions.',end=terminal)
        out=home/'state/procevent'/('.'+id+'.'+token+'.output')
        if boundary=='precommit':
            wait(lambda:out.exists() and out.stat().st_size>0,'real feedback staged')
            assert len(captures(env,id))==0
            LOG.write('Observed staged actual Lavish feedback before capture\n'+out.read_text()+'\n')
        else:
            wait_capture(env,id,1)
            assert not (home/'state/reconcile-requests/sample-reconcile-call.request').exists()
            assert out.exists() and out.stat().st_size>0
            LOG.write('Observed committed actual Lavish feedback awaiting intake under the source boundary\n')
        reply=W/(name+'.md');reply.write_text('Firstmate received the choices.\n')
        armout=open(E/(name+'-rearm.log'),'w')
        armer=subprocess.Popen([str(ROOT/'bin/fm-procevent-lavish.sh'),'arm',str(art),'--agent-reply-file',str(reply)],env=env,stdout=armout,stderr=armout)
        if boundary=='postcommit':
            time.sleep(.7);assert armer.poll() is None,'Reply replaced runner while its committed decisions were unfinished'
            LOG.write('Competing reply waited while captured decisions were unfinished\n');release.touch();lockproc.wait(timeout=10)
        status=armer.wait(timeout=30);armout.close();LOG.write((E/(name+'-rearm.log')).read_text())
        assert (status!=0) if terminal else (status==0)
        wait_capture(env,id,1)
        request=wait(lambda:(home/'state/reconcile-requests/sample-reconcile-call.request').exists(),'reconcile request')
        show=run(['tasks-axi','show','sample-keyed-answer','--full'],env=env,cwd=home).stdout
        assert 'Answer: accepted' in show and 'state: done' in show
        shutil.copyfile(home/'state/reconcile-requests/sample-reconcile-call.request',E/(name+'-request.txt'))
        (E/(name+'-answer.txt')).write_text(show)
        for f in captures(env,id):shutil.copyfile(f,E/(name+'-'+f.name))
        if terminal:
            assert 'stop and conclude' in (E/(name+'-rearm.log')).read_text()
            assert not (home/'state/procevent'/(id+'.source')).exists()
            pe(env,'reconcile');time.sleep(.3);assert len(captures(env,id))==1
            assert not text_contains('Firstmate received the choices.')
        else:
            wait(lambda:text_contains('Firstmate received the choices.'),'bound reply visible')
            # Complete the Reconcile request while its capture remains unacknowledged.
            note=W/(name+'-note.md');note.write_text('Checked; the captain call remains open.\n')
            task(env,'reconcile','note','sample-reconcile-call','--note-file',note)
            assert not (home/'state/reconcile-requests/sample-reconcile-call.request').exists()
            reply.write_text('Checked. The call remains open.\n');lavish(env,'arm',art,'--agent-reply-file',reply)
            wait(lambda:text_contains('Checked. The call remains open.'),'reply to completed request')
            assert not (home/'state/reconcile-requests/sample-reconcile-call.request').exists(),'old pending decision replayed'
            send('Feedback continues after applying decisions.')
            wait(lambda:any('Feedback continues after applying decisions.' in f.read_text() for f in captures(env,id)), 'continued feedback')
            assert sum('selection' in f.read_text() and 'sample-keyed-answer' in f.read_text() for f in captures(env,id))==1
            for f in captures(env,id): shutil.copyfile(f,E/(name+'-'+f.name))
            screenshot(name)
            lavish(env,'retire',art);run(['lavish-axi','end',art],env=env)
        if terminal:
            state=json.loads((W/'lavish-state/state.json').read_text())
            sess=next(s for s in state['sessions'].values() if s['file']==str(art))
            (E/(name+'-session.json')).write_text(json.dumps(sess,indent=2))
        result(name+' preserves reconcile and keyed decisions'+(' and refuses further replies/polls' if terminal else ' without replaying old requests'))
    finally:
        release.touch()
        if lockproc and lockproc.poll() is None:lockproc.wait(timeout=10)
        try:os.kill(pid,signal.SIGCONT)
        except ProcessLookupError:pass

try:
    for version in ['modern','legacy']:
        if not any(x['name'].startswith(version+'-conversation') for x in RESULTS): main_flow(version)
        for terminal in [False,True]:
            for boundary in ['precommit','postcommit']:bound_flow(version,boundary,terminal)
except Exception as e:
    LOG.write('FAILED '+repr(e)+'\n');print('FAILED '+repr(e),flush=True);raise
finally:
    for home in ACTIVE:
        env=BASE.copy();env['FM_HOME']=str(home)
        pe(env,'sweep-home',ok=False)
    LOG.close()

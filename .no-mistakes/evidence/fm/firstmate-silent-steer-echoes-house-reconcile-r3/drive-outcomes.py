import json, os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M43G853WBY3DHHDZBWG396HF')
transcript = []
base = os.environ.copy()
for key in list(base):
    if key.startswith('FM_') or key in ('STATE', 'CONFIG', 'DATA', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'TMUX', 'NO_MISTAKES_GATE'):
        base.pop(key)
base['TMPDIR'] = str(root / '.test-tmp')
homes = []
def home(name):
    h = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-'+name+'-',dir=root/'.test-tmp'))
    homes.append(h)
    subprocess.run([str(root/'bin/fm-lab-home.sh'),'create',str(h)],check=True,capture_output=True)
    (h/'config/supervision-host-off').touch()
    return h
def run(h,script,*args,ok=True,envextra=None):
    env = {**base,'FM_HOME':str(h), **(envextra or {})}
    p = subprocess.run([str(root/'bin'/script),*args],env=env,text=True,capture_output=True,timeout=40)
    transcript.append({'home':h.name,'command':'bin/'+script+' '+ ' '.join(args),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert (p.returncode == 0) == ok, transcript[-1]
    return p.stdout

def append(h,task,summary,silent=False,verdict='routine'):
    return run(h,'fm-branch-outcome.sh','append','--task',task,'--verdict',verdict,'--summary',summary,'--silent',str(silent).lower())

def note(name,h):
    state = h/'state'
    transcript.append({'scenario':name,'state':{p.name:p.read_text() for p in state.iterdir() if p.is_file() and (p.name.endswith('.jsonl') or 'index' in p.name or p.name.endswith('.status') or p.name == '.branch-outcomes-cursor')}})
try:
    h=home('replay')
    append(h,'paused','Scheduled recheck: registered pause unchanged',True)
    append(h,'action','Worker recovered after restart')
    append(h,'release','Release checks failed; action needed',verdict='captain')
    output=run(h,'fm-branch-outcome.sh','startup-replay')
    assert 'registered pause' not in output and 'Worker recovered after restart' in output and 'Release checks failed' not in output
    assert (h/'state/.branch-outcomes-cursor').read_text().strip() == '2'
    unread=[json.loads(s) for s in run(h,'fm-branch-outcome.sh','unread').splitlines()]
    assert len(unread)==1 and unread[0]['verdict']=='captain' and not unread[0]['silent']
    run(h,'fm-branch-outcome.sh','append','--task','release','--verdict','captain','--summary','Must stay visible','--silent','true',ok=False)
    note('Silent replay is omitted; non-silent routine replay remains available; captain cannot be silent',h)

    h=home('silent-backstop')
    (h/'state/ship.status').write_text('done: requested work ready for review\n')
    append(h,'ship','Status record echoed unchanged',True)
    assert not (h/'state/.ship.branch-outcome-index').exists()
    output=run(h,'fm-wake-drain.sh')
    assert 'ship done: requested work ready for review' in output
    output=run(h,'fm-wake-drain.sh')
    assert 'STATUS OUTCOME BACKSTOP (' not in output
    note('Silent echo does not cover a lost completion; next main drain recovers it once',h)

    h=home('mixed')
    (h/'state/ship.status').write_text('done: prior completion delivered\n')
    append(h,'ship','Prior completion delivered',verdict='captain')
    assert 'STATUS OUTCOME BACKSTOP (' not in run(h,'fm-wake-drain.sh')
    with (h/'state/ship.status').open('a') as f:f.write('failed: later attempt failed\n')
    append(h,'ship','Unchanged echo of latest record',True)
    assert (h/'state/.ship.branch-outcome-index').read_text().split('\t')[1]=='1'
    assert 'ship failed: later attempt failed' in run(h,'fm-wake-drain.sh')
    assert (h/'state/.branch-outcome-index-ready').read_text().strip()=='visible-only-v1:2'
    note('Visible coverage suppresses repeats but a later silent row cannot hide a new failure; readiness includes silent tail',h)

    h=home('migration')
    (h/'state/visible.status').write_text('done: already delivered\n')
    (h/'state/silent.status').write_text('failed: never delivered\n')
    append(h,'visible','Already delivered',verdict='captain')
    append(h,'silent','Unchanged echo',True)
    rows=[json.loads(s) for s in (h/'state/branch-outcomes.jsonl').read_text().splitlines()]
    for row in rows:
        (h/('state/.'+row['task']+'.branch-outcome-index')).write_text('fm-branch-outcome-index-v1\t%s\t%s\t%s\n'%(row['seq'],row['statusEndpoint'],row['statusIdent']))
    (h/'state/.branch-outcome-index-ready').write_text('2\n')
    before=(h/'state/branch-outcomes.jsonl').read_bytes()
    output=run(h,'fm-wake-drain.sh')
    assert 'silent failed: never delivered' in output and 'visible done:' not in output
    assert not (h/'state/.silent.branch-outcome-index').exists()
    assert before==(h/'state/branch-outcomes.jsonl').read_bytes()
    note('Legacy silent coverage migrates without changing history or legitimate coverage',h)

    h=home('contention')
    (h/'state/ship.status').write_text('done: completion waiting during contention\n')
    append(h,'fleet','Unchanged review',True)
    env={**base,'FM_HOME':str(h)}
    holder=subprocess.Popen(['bash','-c','. "$1"; fm_lock_acquire_wait "$STATE/.branch-outcomes.lock" || exit 1; printf "locked\\n"; read -r release; fm_lock_release "$STATE/.branch-outcomes.lock"','_',str(root/'bin/fm-wake-lib.sh')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    try:
        assert holder.stdout.readline().strip()=='locked'
        output=run(h,'fm-wake-drain.sh',envextra={'FM_STATUS_PRESENTATION_LOCK_TIMEOUT':'1'})
        assert 'history is busy; retry on the next drain' in output and 'ship done:' not in output
    finally:
        holder.communicate('release\n',timeout=5)
    assert 'ship done: completion waiting during contention' in run(h,'fm-wake-drain.sh')
    note('Healthy-store lock contention skips once and subsequent drain recovers completion',h)

    h=home('protocol')
    output=run(h,'fm-supervision-instructions.sh','--harness','pi')
    (evidence/'pi-protocol.txt').write_text(output)
    note('Primary receives emitted Pi protocol',h)
finally:
    (evidence/'live-outcomes-transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
    for h in homes:shutil.rmtree(h)
print('Live outcome/recovery scenarios completed; disposable homes removed.')

import copy, hashlib, json, os, pathlib, shutil, subprocess, time
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('~/.no-mistakes/evidence/01M53SN5VBX95AZ3PSX0JPQRR8')
WORK = ROOT / '.local-validation'
NOW = '2026-10-17T01:00:00Z'
REPORT = {'driver':'real bin/fm-fleet-snapshot.sh, bin/fm-contributions.sh and bin/fm-wake-drain.sh; real jq/tasks-axi/tmux; no shims; local read-only snapshot mode makes no forge calls', 'checks':[]}
def env(home):
    e = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'CMUX_')) and k not in ('TMUX', 'TMUX_PANE')}
    e.update(FM_HOME=str(home), TMPDIR=str(WORK/'tmp'), TMUX=str(home/'absent-socket')+',0,0', TMUX_TMPDIR=str(home/'tmux'), FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH='1792198800', FM_CONTRIBUTIONS_NOW=NOW)
    return e
def run(home, args, name=None, code=0):
    start=time.monotonic()
    p=subprocess.run([str(a) for a in args],env=env(home),cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=240)
    elapsed=time.monotonic()-start
    if name:
        (EVID/(name+'.stdout')).write_text(p.stdout)
        (EVID/(name+'.stderr')).write_text(p.stderr)
    assert p.returncode==code, (args,p.returncode,p.stdout[-2000:],p.stderr[-2000:])
    return p.stdout,elapsed

def home(name):
    h=WORK/name
    run(h,[ROOT/'bin/fm-lab-home.sh','create',h])
    (h/'config/supervision-host-off').touch()
    (h/'config/backend').write_text('tmux\n')
    (h/'tmux').mkdir()
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return h

def meta(h, task, kind='ship'):
    wt=h/'projects'/task
    wt.mkdir()
    p=h/'state'/f'{task}.meta'
    p.write_text(f'window=fm-lab-snapshot:fm-{task}\nbackend=tmux\nworktree={wt}\nproject=sample\nharness=claude\nkind={kind}\nmode={kind}\n')
    p.chmod(0o600)

def saved(h, task, n, pending=True):
    record={'schema':'fm-contributions.v1','task':task,'records':[{'url':f'https://github.com/example/lab/pull/{n}','kind':'pr','checked_at':NOW,'error':None,'pending':[{'token':f'item-{n}','summary':f'Saved answer {n}: é / REST'}] if pending else [],'seen':[],'verdict':None,'observation':{'head':'a'*40,'state':'merged','draft':False,'mergeable':'mergeable','review_decision':'APPROVED','can_merge':False,'checks':[],'reviews':[],'events':[]}}]}
    p=h/'data'/task/'contributions.json'
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(record,ensure_ascii=False)+'\n')
    return p,record

def snapshot(h,name):
    raw,seconds=run(h,[ROOT/'bin/fm-fleet-snapshot.sh','--json'],name)
    return json.loads(raw),seconds

def record_check(name,**details):
    REPORT['checks'].append(dict(name=name,**details))
    (EVID/'live-results.json').write_text(json.dumps(REPORT,indent=2,ensure_ascii=False)+'\n')
    print(name, details, flush=True)

homes=[]
try:
    h=home('records'); homes.append(h)
    expected=[]
    for n in range(1,524):
        task=f'task{n:04d}'
        _,r=saved(h,task,n)
        expected.append(dict(r['records'][0]['pending'][0],task=task,url=r['records'][0]['url']))
    raw,seconds=run(h,[ROOT/'bin/fm-contributions.sh','pending'],'523-pending')
    assert json.loads(raw)==expected
    input_path=h/'input.json'
    raw,_=run(h,[ROOT/'bin/fm-fleet-snapshot.sh','--contribution-input'])
    input_path.write_text(raw)
    valid_raw,_=run(h,[ROOT/'bin/fm-contributions.sh','snapshot',input_path,'--all'],'523-contributions')
    valid=json.loads(valid_raw)
    assert valid['known']==523 and valid['checked']==523 and valid['unreadable_records']==0 and valid['complete']
    p,r=saved(h,'boundary',900)
    p.write_bytes(p.read_bytes()+b' '*(1048576-p.stat().st_size))
    p,r=saved(h,'oversized',901)
    p.write_bytes(p.read_bytes()+b' '*(1048577-p.stat().st_size))
    p,r=saved(h,'mismatch',902); r['task']='different'; p.write_text(json.dumps(r))
    p,r=saved(h,'schema',903); r['schema']='unknown'; p.write_text(json.dumps(r))
    p,r=saved(h,'malformed',904); p.write_text('{"schema":')
    p,r=saved(h,'empty',905); p.write_text('')
    p,r=saved(h,'two',906); p.write_text(json.dumps(r)+'\n'+json.dumps(r))
    (h/'data/symlink-file').mkdir(); (h/'data/symlink-file/contributions.json').symlink_to(h/'data/task0001/contributions.json')
    (h/'data/symlink-dir').symlink_to(h/'data/task0002',target_is_directory=True)
    (h/'data/dir-file/contributions.json').mkdir(parents=True)
    bad_raw,_=run(h,[ROOT/'bin/fm-contributions.sh','snapshot',input_path,'--all'],'adversarial-contributions')
    bad=json.loads(bad_raw)
    assert bad['unreadable_records']==9 and bad['known']==524 and bad['checked']==524 and not bad['complete']
    assert {r['task'] for r in bad['rows']}=={f'task{n:04d}' for n in range(1,524)}|{'boundary'}
    run(h,[ROOT/'bin/fm-contributions.sh','pending'],'pending-refuses-invalid',code=1)
    for task in ('malformed','empty','two'):
        shutil.rmtree(h/'data'/task)
    retry,_=run(h,[ROOT/'bin/fm-contributions.sh','snapshot',input_path,'--all'],'adversarial-without-parse-failures')
    retry=json.loads(retry)
    assert retry['unreadable_records']==6 and retry['rows']==bad['rows']
    record_check('Saved contributions cross three batches and retain safety boundaries',accepted=523,boundary_bytes=1048576,rejected=9,remaining_rejections_after_parse_errors_removed=6,pending_seconds=seconds)

    h=home('decisions'); homes.append(h); meta(h,'task1')
    status=h/'state/task1.status'
    wake=h/'state/.task1.open-decisions-cursor'
    sentinel=b'version=sentinel\noffset=0\nident=sentinel\n'
    wake.write_bytes(sentinel)
    decisions=[]
    def check(label, want):
        s,t=snapshot(h,'decisions-'+label)
        actual=s['tasks'][0]['hints']['open_decisions']
        assert actual==[{'key':k,'verb':v,'summary':m} for k,v,m in want],(label,actual,want)
        assert wake.read_bytes()==sentinel
        decisions.append({'step':label,'open_decisions':actual,'seconds':t})
        return s
    status.write_text('needs-decision [key=a]: choose A\n')
    a=check('cold',[('a','needs-decision','choose A')])
    b=check('warm',[('a','needs-decision','choose A')]); assert a==b
    with status.open('a') as f:f.write('note: unrelated\nresolved [key=a]: A selected\nneeds-decision [key=b]: choose B\n')
    check('appended',[('b','needs-decision','choose B')])
    with status.open('a') as f:f.write('needs-decision [key=a]: choose again\nresolved [key=b]: part')
    check('partial',[('a','needs-decision','choose again')])
    with status.open('a') as f:f.write('ial completed\nblocked [key=c]: need access\n')
    check('completed',[('a','needs-decision','choose again'),('c','blocked','need access')])
    with status.open('a') as f:f.write('captain-held [key=a]: filed\n')
    check('captain-held',[('c','blocked','need access')])
    status.write_text('needs-decision [key=d]: replaced history\n'+'note: padding\n'*25)
    check('rewritten',[('d','needs-decision','replaced history')])
    status.write_text(status.read_text().replace('key=d','key=e'))
    check('same-size-edit',[('e','needs-decision','replaced history')])
    status.write_text('needs-decision [key=f]: after truncation\n')
    check('truncated',[('f','needs-decision','after truncation')])
    replacement=h/'state/replacement'; replacement.write_text('needs-decision [key=g]: new inode\n'); replacement.replace(status)
    check('new-inode',[('g','needs-decision','new inode')])
    (h/'state/.task1.snapshot-open-decisions-cursor').write_text('corrupted cache\n')
    check('corrupt-cache',[('g','needs-decision','new inode')])
    (EVID/'decision-transitions.json').write_text(json.dumps(decisions,indent=2)+'\n')
    record_check('Snapshot decision cache tracks appends, partial lines, rewrites, truncation and replacement',transitions=decisions)

    h=home('unread'); homes.append(h); meta(h,'task1')
    (h/'state/task1.status').write_text('note: captain said use REST not RPC\n')
    assert not (h/'state/.status-presentation-cursor').exists()
    snapshot(h,'before-first-drain')
    assert not (h/'state/.status-presentation-cursor').exists()
    out,_=run(h,[ROOT/'bin/fm-wake-drain.sh'],'first-drain')
    assert 'UNREAD STATUS ' in out and 'task1 note: captain said use REST not RPC' in out
    out2,_=run(h,[ROOT/'bin/fm-wake-drain.sh'],'second-drain')
    assert 'task1 note: captain said use REST not RPC' not in out2
    with (h/'state/task1.status').open('a') as f:f.write('note: follow-up answer\n')
    snapshot(h,'before-followup-drain')
    out3,_=run(h,[ROOT/'bin/fm-wake-drain.sh'],'followup-drain')
    assert 'task1 note: follow-up answer' in out3 and 'task1 note: captain said use REST not RPC' not in out3
    record_check('Snapshot leaves first and later unread notes available exactly once',first_drain=out,second_drain=out2,followup_drain=out3)

    h=home('load'); homes.append(h)
    for n in range(1,524):saved(h,f'saved{n:04d}',n,False)
    for n in range(1,24):
        task=f'worker{n:02d}'; meta(h,task)
        (h/'state'/f'{task}.status').write_text('note: historical event\n'*1008+f'needs-decision [key=route-{n}]: choose route {n}\n')
    baseline=WORK/'baseline'; baseline.mkdir()
    archive=subprocess.run(['git','archive','b062eb94c50a68dd4467fba25346a7d7b4083288'],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
    subprocess.run(['tar','-xf','-','-C',str(baseline)],input=archive.stdout,check=True)
    # Serial timings, after other focused checks finish; compare full product outputs.
    raw,base_time=run(h,[baseline/'bin/fm-fleet-snapshot.sh','--json'],'load-baseline')
    base=json.loads(raw)
    cold,cold_time=snapshot(h,'load-cold')
    warm,warm_time=snapshot(h,'load-warm')
    def normalize(s):
        s=copy.deepcopy(s); s['roots']['fm_root']='<code-root>'; return s
    equal=normalize(base)==normalize(cold)==normalize(warm)
    if not equal:
        (EVID/'load-normalized-base.json').write_text(json.dumps(normalize(base),indent=2)+'\n')
        (EVID/'load-normalized-current.json').write_text(json.dumps(normalize(warm),indent=2)+'\n')
    assert equal, 'baseline/current full snapshot output changed'
    assert warm_time < base_time * 0.8, (base_time,warm_time)
    record_check('Loaded fleet snapshots preserve full output while reducing latency',saved_files=523,tasks=23,status_lines_per_task=1009,baseline_seconds=base_time,cold_seconds=cold_time,warm_seconds=warm_time,warm_speedup=base_time/warm_time,full_output_equal_except_code_root=True)
finally:
    for h in homes:shutil.rmtree(h,ignore_errors=True)
    if (WORK/'baseline').exists():shutil.rmtree(WORK/'baseline')

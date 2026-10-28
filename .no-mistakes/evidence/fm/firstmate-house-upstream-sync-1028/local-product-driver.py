import hashlib,json,os,pathlib,subprocess,time
R=pathlib.Path.cwd(); W=R/'.test-phase-disposable'; E=pathlib.Path(__file__).resolve().parent
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','REX_SESSION','REX_BLOCK','REX_SERVER']: env.pop(k,None)
env['TMPDIR']=str(W/'tmp')
W.mkdir(exist_ok=True); (W/'tmp').mkdir(exist_ok=True)
lines=[]; results=[]
def log(s): lines.append(str(s).replace(str(R),'<worktree>')); print(lines[-1],flush=True)
def home(name):
    h=W/name
    for d in ['config','data','state','projects']: (h/d).mkdir(parents=True,exist_ok=True)
    return h
def run(h,args,expected=0,input=None):
    p=subprocess.run([str(x) for x in args],cwd=h,env=dict(env,FM_HOME=str(h)),input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    log('$ '+' '.join(str(x).replace(str(R)+'/','') for x in args)+'\n'+p.stdout.rstrip()+'\nexit='+str(p.returncode))
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
def done(name): results.append(dict(name=name,result='pass',live=True,surface='product')); log('OBSERVED: '+name)
try:
    h=home('marks-plan')
    (h/'state/task-a.meta').write_text('backend=rex\nwindow=unused:no-session\nkind=ship\n')
    for status,expected in [('blocked: missing login token','task-a\tblocked\tauth\tBlocked: missing login token\n'),('failed: build failed','task-a\terror\t\tFailed: build failed\n'),('working: resumed','task-a\tclear\t\t\n')]:
        (h/'state/task-a.status').write_text(status+'\n')
        assert run(h,[R/'bin/fm-rex-marks.sh','plan'])==expected
    done('Rex plan maps blocked credentials, failure, and resumed work without opening a backend session')
    h=home('export-home'); dest=W/'export-destination'
    (h/'data/projects.md').write_text('sample project\n'); (h/'data/private.txt').write_text('excluded\n')
    run(h,[R/'bin/fm-record-export.sh','sync']); assert not dest.exists()
    (h/'config/record-export-root').write_text(str(dest)+'\n')
    run(h,[R/'bin/fm-record-export.sh','sync'])
    assert (dest/'live/data/projects.md').read_text()=='sample project\n'
    assert not (dest/'live/data/private.txt').exists()
    log('Persisted export: live/data/projects.md = '+(dest/'live/data/projects.md').read_text().strip()+'; private.txt absent')
    done('Record export is inert by default and copies only allowed records after opt-in')
    (h/'state/task-a.meta').write_text('task=task-a\nspawn_gen=s1700000000.1.abc\nkind=ship\n')
    (h/'state/task-a.status').write_text('done: sample complete\n')
    run(h,[R/'bin/fm-record-export.sh','archive-task','task-a'])
    archive=dest/'archive/task-a/s1700000000.1.abc'; manifest=json.loads((archive/'manifest.v1.json').read_text())
    assert manifest['complete'] and manifest['schema']=='firstmate-record-export-archive.v1'
    for f in manifest['files']:
        data=(h/f['source']).read_bytes()
        assert f['sha256']==hashlib.sha256(data).hexdigest()
    log('Committed manifest: '+json.dumps(manifest,sort_keys=True))
    before=(archive/'manifest.v1.json').read_bytes()
    run(h,[R/'bin/fm-record-export.sh','archive-task','task-a']); assert (archive/'manifest.v1.json').read_bytes()==before
    done('Record archive commits integrity metadata and an exact retry preserves the committed archive')
    previous=(dest/'live/data/projects.md').read_bytes()
    (h/'data/projects.md').unlink(); (h/'data/projects.md').symlink_to(h/'data/private.txt')
    run(h,[R/'bin/fm-record-export.sh','sync'],expected=1)
    assert (dest/'live/data/projects.md').read_bytes()==previous
    log('Published live generation remains byte-identical after symlink refusal')
    done('Unsafe source symlink is refused while the last published record snapshot survives')
    h=home('pin-home'); cfg=h/'config'; (cfg/'secondmate-harness.d').mkdir()
    (cfg/'secondmate-harness').write_text('claude opus high\nmate alpha: codex model-a xhigh\n')
    (cfg/'secondmate-harness.d/alpha').write_text('pi model-b high\n')
    for mate,expected in [('alpha',['pi','model-b','high']),('beta',['claude','opus','high'])]:
        got=[run(h,[R/'bin/fm-harness.sh',verb,mate]).strip() for verb in ['secondmate','secondmate-model','secondmate-effort']]
        assert got==expected,(got,expected)
    (cfg/'secondmate-harness.d/alpha').unlink()
    got=[run(h,[R/'bin/fm-harness.sh',verb,'alpha']).strip() for verb in ['secondmate','secondmate-model','secondmate-effort']]
    assert got==['codex','model-a','xhigh'],got
    done('Per-mate file pin wins over global mate grammar, which wins over the default profile')
    h=home('timeout-home')
    script='. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 3 cat'
    assert run(h,['bash','-c',script,'_',R],input='stdin survives\n')=='stdin survives\n'
    start=time.monotonic()
    run(h,['bash','-c','. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 1 sleep 30','_',R],expected=124)
    elapsed=time.monotonic()-start; assert elapsed<8,elapsed
    log('Deadline returned 124 after %.2fs'%elapsed)
    done('Timed executor preserves stdin and stops an overlong real subprocess promptly')
    h=home('hold-home')
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = \'data/review#é.md\'\ndone_keep = 10\n')
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    run(h,['tasks-axi','add','sample-review','Review sample','--kind','scout','--repo','sample','--start'])
    (h/'data/sample-review').mkdir(); (h/'data/sample-review/report.md').write_text('# Review\nOne choice remains.\n')
    (h/'state/sample-review.meta').write_text('window=unused:sample-review\nkind=scout\nmode=scout\nspawn_gen=fixture-review\n')
    (h/'state/sample-review.status').write_text('done: report complete\n')
    run(h,[R/'bin/fm-captain-hold.sh','hold','sample-call','--title','Choose sample','--reason','pending choice','--repo','sample','--origin','sample-review'])
    run(h,[R/'bin/fm-captain-hold.sh','complete','sample-review','sample-call'])
    (h/'answer.txt').write_text('Use the sample option.\n')
    run(h,[R/'bin/fm-captain-hold.sh','answer','sample-call','--decision-file',h/'answer.txt'])
    run(h,[R/'bin/fm-captain-hold.sh','verify','sample-review'])
    conf=h/'.tasks.toml'; conf.write_text(conf.read_text().replace('done_keep = 10','done_keep = 0'))
    run(h,['tasks-axi','add','trigger','Trigger retention','--kind','ship','--repo','sample'])
    run(h,['tasks-axi','done','trigger'])
    archive=h/'data/review#é.md'; assert archive.exists() and 'sample-call' in archive.read_text()
    run(h,['tasks-axi','show','sample-call'],expected=1)
    conf.write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/review\\u0023\\U000000e9.md" # escaped reader path\ndone_keep = 0\n')
    run(h,[R/'bin/fm-captain-hold.sh','verify','sample-review'])
    run(h,[R/'bin/fm-captain-hold.sh','complete','sample-review','sample-call'])
    log('Persisted archive path: data/review#é.md; answered hold absent from live backlog; verify and complete both accepted it')
    done('Answered hold remains verifiable after real tasks-axi archives it to a TOML-escaped path')
finally:
    (E/'local-product-transcript.txt').write_text('\n'.join(lines)+'\n')
    (E/'local-product-results.json').write_text(json.dumps(results,indent=2)+'\n')

import json, os, pathlib, shutil, subprocess, time, traceback

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M49YHGQ1ZTS9V2MP714MEZST')
WORK = ROOT / '.fm-test-phase/live-work'
CHECK = ROOT / 'bin/fm-startup-growth-check.sh'
LOG = []
RESULTS = []
BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'CMUX_')) and k not in ('TMUX', 'NO_MISTAKES_GATE')}
BASE_ENV['TMPDIR'] = str(ROOT / '.fm-test-phase/tmp')

def say(text):
    LOG.append(text)
    print(text, flush=True)

def world(name, real_root=False):
    home = WORK / name / 'home'
    root = ROOT if real_root else WORK / name / 'root'
    for sub in ('data', 'config', 'state', 'projects'):
        (home / sub).mkdir(parents=True, exist_ok=True)
    if not real_root:
        for rel in ('AGENTS.md', 'CLAUDE.md', 'bin/fm-session-start.sh', 'bin/fm-bootstrap.sh', 'bin/fm-supervision-instructions.sh'):
            dest = root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, dest)
    (home / 'config/startup-memory-budget').write_text('7500\n')
    return root, home

def env_for(root, home, **extra):
    return dict(BASE_ENV, FM_ROOT_OVERRIDE=str(root), FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'), FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'), FM_PROJECTS_OVERRIDE=str(home/'projects'), **extra)

def run(root, home, args=('check',), extra=None, expected=0, timeout=30):
    env = env_for(root, home)
    env.update(extra or {})
    cmd = [str(CHECK), *args]
    p = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=timeout)
    say('$ ' + ' '.join(cmd) + '\nFM_HOME=' + str(home) + '\nexit=' + str(p.returncode) + '\n' + (p.stdout or '<silent>\n') + p.stderr)
    assert p.returncode == expected, (p.returncode, p.stdout, p.stderr)
    return p.stdout

def due(home):
    path = home/'state/.startup-growth-check'
    lines = path.read_text().splitlines()
    path.write_text('\n'.join('last_eval\t'+str(int(time.time())-86401) if line.startswith('last_eval\t') else line for line in lines)+'\n')
    say('Disposable daily record dated to yesterday; real wall clock remains unchanged.')

def append(path, n):
    with path.open('a') as f:
        f.write('x' * n)

def record(home):
    return (home/'state/.startup-growth-check').read_text()

def budget(root, home):
    p = subprocess.run([str(ROOT/'bin/fm-startup-memory-budget.sh'), 'report'], env=env_for(root,home), text=True, capture_output=True, check=True)
    say('$ bin/fm-startup-memory-budget.sh report\n'+p.stdout)
    return p.stdout

def watcher(root, home):
    env = env_for(root, home, FM_CHECK_INTERVAL='0', FM_POLL='1', FM_HEARTBEAT='999999', FM_HOME_SUMMARY_INTERVAL='999999')
    p = subprocess.run([str(ROOT/'bin/fm-watch.sh')], env=env, text=True, capture_output=True, timeout=35)
    say('$ bin/fm-watch.sh (isolated empty home; authenticated check sweep)\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    assert p.returncode == 0, p.stderr
    return p.stdout

def scenario(name, fn):
    say('\nSCENARIO: '+name)
    try:
        fn()
        RESULTS.append(dict(name=name,result='pass',live=True,surface='product'))
        say('OBSERVED: independent behavioral expectations satisfied.')
    except Exception as exc:
        RESULTS.append(dict(name=name,result='fail',live=True,surface='product',error=str(exc)))
        say(traceback.format_exc())

def lifecycle():
    root, home = world('lifecycle', real_root=True)
    run(root, home, ('arm',))
    shim = home/'state/startup-growth.check.sh'
    trust = home/'state/startup-growth.check-trust'
    assert shim.stat().st_mode & 0o777 == 0o700
    assert trust.stat().st_mode & 0o777 == 0o600
    inode = shim.stat().st_ino
    run(root, home, ('arm',))
    assert shim.stat().st_ino == inode
    # Execute the installed shim with no ambient FM_HOME: the armed home is pinned.
    pinned_env = env_for(root, home)
    pinned_env.pop('FM_HOME')
    for key in ('FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE'):
        pinned_env.pop(key)
    p = subprocess.run([str(shim)], env=pinned_env, capture_output=True, text=True, check=True)
    say('$ env -u FM_HOME <installed shim>\n'+(p.stdout or '<silent>\n')+p.stderr)
    assert not p.stdout and (home/'state/.startup-growth-check').exists()
    # First content establishes a baseline, then material growth wakes the watcher.
    (home/'data/learnings.md').write_text('local memory\n')
    due(home)
    assert run(root, home) == ''
    append(home/'data/learnings.md', 900)
    due(home)
    out = watcher(root, home)
    assert 'check:' in out and 'memory growth data/learnings.md +300 estimated_tokens' in out
    queue = home/'state/.wake-queue'
    say('Durable watcher notification:\n'+queue.read_text())
    assert 'startup-growth:' in queue.read_text()
    run(root, home, ('disarm',))
    assert not shim.exists() and not trust.exists() and not (home/'state/.startup-growth-check').exists()
    say('Disarm removed the installed shim, its trust binding, and the daily record.')

def cadence():
    root, home = world('cadence')
    assert run(root, home) == ''
    before = record(home)
    # Strictly less than the documented 2048-byte threshold remains quiet.
    append(root/'AGENTS.md', 2047)
    assert run(root, home) == '' and record(home) == before
    due(home)
    assert run(root, home) == ''
    append(root/'AGENTS.md', 1)
    due(home)
    assert 'tracked startup surface growth AGENTS.md +2048 bytes' in run(root, home)
    due(home)
    assert run(root, home) == ''
    # Optional file first content does not constitute growth; accumulated 748 bytes = 250 tokens.
    (home/'data/projects.md').write_text('p'*900)
    due(home)
    assert run(root, home) == ''
    append(home/'data/projects.md', 747)
    due(home)
    assert run(root, home) == ''
    (home/'data/projects.md').unlink()
    due(home)
    assert run(root, home) == ''
    (home/'data/projects.md').write_text('p'*1648)
    due(home)
    out = run(root, home)
    assert 'printed-memory growth data/projects.md +250 estimated_tokens (+748 bytes' in out
    assert 'memory_budget\t7500\t0\twithin-budget' in record(home)
    say('Persisted public daily record:\n'+record(home))

def budget_dedupe():
    root, home = world('budget')
    (home/'data/captain.md').write_text('x'*300)
    (home/'config/startup-memory-budget').write_text('99\n')
    out = run(root, home)
    assert 'startup memory budget overrun total_estimated_tokens=100 budget=99' in out
    assert 'total_estimated_tokens=100\n' in budget(root,home)
    due(home)
    assert run(root, home) == ''
    # Growth in printed registry and tracked code must not inflate prompt memory.
    (home/'data/projects.md').write_text('p'*30000)
    append(root/'bin/fm-bootstrap.sh', 3000)
    due(home)
    out = run(root, home)
    assert 'tracked startup surface growth bin/fm-bootstrap.sh +3000 bytes' in out
    assert 'total_estimated_tokens=100 budget=99' in out
    (home/'config/startup-memory-budget').write_text('100\n')
    due(home)
    assert run(root, home) == ''
    assert 'memory_budget\t100\t100\twithin-budget' in record(home)
    (home/'config/startup-memory-budget').write_text('99\n')
    due(home)
    assert 'startup memory budget overrun' in run(root, home)
    say('Persistent overrun stayed silent until findings changed; clearing and recurring overrun notified again.')

def ownership():
    root, home = world('secondmate')
    (home/'.fm-secondmate-home').touch()
    (home/'config/startup-memory-budget').write_text('100\n')
    (home/'data/captain-shared.md').write_text('x'*303)
    (home/'data/learnings.md').write_text('local\n')
    assert run(root, home) == ''
    append(home/'data/captain-shared.md', 900)
    due(home)
    assert run(root, home) == ''
    assert 'primary-owned-shared-file-alone-exceeds-budget' in record(home)
    append(home/'data/learnings.md', 900)
    due(home)
    out = run(root, home)
    assert 'memory growth data/learnings.md +300 estimated_tokens' in out
    assert 'growth data/captain-shared.md' not in out and 'budget overrun' not in out
    say('Secondmate daily record:\n'+record(home))
    (home/'.fm-secondmate-home').unlink()
    due(home)
    assert 'startup memory budget overrun' in run(root, home)
    append(home/'data/captain-shared.md', 900)
    due(home)
    assert 'memory growth data/captain-shared.md +300 estimated_tokens' in run(root, home)

def adversarial():
    root, home = world('unsafe')
    assert run(root, home) == ''
    original = (root/'AGENTS.md').read_bytes()
    (root/'AGENTS.md').unlink()
    target = home/'sentinel'
    target.write_text('DO NOT MODIFY\n')
    (root/'AGENTS.md').symlink_to(target)
    (home/'data/learnings.md').symlink_to(target)
    (root/'bin/fm-bootstrap.sh').unlink()
    # Same-day polls must not inspect even unsafe or absent watched surfaces.
    assert run(root, home) == ''
    due(home)
    out = run(root, home)
    assert 'unsafe tracked AGENTS.md' in out and 'unsafe memory data/learnings.md' in out
    assert 'missing tracked bin/fm-bootstrap.sh' in out and 'missing memory data/captain-shared.md' not in out
    due(home)
    assert run(root, home) == ''
    # Publishing to a symlink must refuse without overwriting its target or dropping the finding.
    (home/'state/.startup-growth-check').unlink()
    (home/'state/.startup-growth-check').symlink_to(target)
    out = run(root, home, expected=1)
    assert 'unsafe tracked AGENTS.md' in out and target.read_text() == 'DO NOT MODIFY\n'
    assert not list((home/'state').glob('.startup-growth-check.??????'))
    # Recover after refusal; only aged empty orphan files are removed.
    (home/'state/.startup-growth-check').unlink()
    (root/'AGENTS.md').unlink()
    (root/'AGENTS.md').write_bytes(original)
    (home/'data/learnings.md').unlink()
    shutil.copy2(ROOT/'bin/fm-bootstrap.sh',root/'bin/fm-bootstrap.sh')
    aged = home/'state/.startup-growth-check.aaaaaa'
    filled = home/'state/.startup-growth-check.bbbbbb'
    fresh = home/'state/.startup-growth-check.cccccc'
    aged.touch(); filled.write_text('retained bytes\n'); fresh.touch()
    for path in (aged,filled):
        os.utime(path,(time.time()-7200,time.time()-7200))
    assert run(root, home) == ''
    assert not aged.exists() and filled.exists() and fresh.exists()
    say('Unsafe inputs were diagnosed; refused publication preserved its target and finding; cleanup removed only an aged empty orphan.')

def authenticated_guard():
    root, home = world('tamper', real_root=True)
    run(root, home, ('arm',))
    shim = home/'state/startup-growth.check.sh'
    marker = home/'SHOULD-NOT-EXECUTE'
    with shim.open('a') as f:
        f.write('\ntouch '+str(marker)+'\n')
    out = watcher(root, home)
    assert 'rejected unauthenticated state checks:' in out
    assert not marker.exists() and not (home/'state/.startup-growth-check').exists()
    say('Tampered registered shim was rejected without execution.')
    run(root, home, ('disarm',))

def capped():
    root, home = world('capped')
    # Real unsafe data path below Darwin PATH_MAX, plus real missing-owner findings.
    deep = home/'data'
    while len(str(deep)) < 840:
        deep = deep/('memory'*16)
    deep.mkdir(parents=True)
    target = home/'sentinel'
    target.write_text('never read as prompt memory\n')
    (deep/'learnings.md').symlink_to(target)
    for rel in ('AGENTS.md','bin/fm-session-start.sh','bin/fm-bootstrap.sh','bin/fm-supervision-instructions.sh'):
        (root/rel).unlink()
    assert len(str(deep/'learnings.md')) < 1024
    out = run(root, home, extra={'FM_DATA_OVERRIDE':str(deep)})
    assert len(out.rstrip('\n').encode()) <= 1000 and ' [truncated]' in out
    full = next(line for line in record(home).splitlines() if line.startswith('reported\t'))
    assert len(full) > 1000
    due(home)
    assert run(root, home, extra={'FM_DATA_OVERRIDE':str(deep)}) == ''
    say('Full uncapped persisted finding for deduplication:\n'+full)
    say('All filesystem paths remained below Darwin PATH_MAX; real budget-owner diagnostics produced the overlong finding.')

try:
    WORK.mkdir(parents=True,exist_ok=True)
    say('Drivers: real worktree bin/fm-startup-growth-check.sh, real budget owner and authenticated watcher. No fake CLI, model, or upstream service. Authentic instruction-file copies and disposable home records only. Oracle: docs/configuration.md daily-check contract and script public help thresholds; boundary examples use known byte counts.')
    for name,fn in [
        ('Arm, rearm, deliver a durable growth notification through the real watcher, and disarm',lifecycle),
        ('Daily silence, exact growth thresholds, cumulative growth, and optional-file restoration',cadence),
        ('Report budget overrun without counting code or registry bytes, deduplicate, and re-notify after clearing',budget_dedupe),
        ('Suppress primary-owned shared-memory growth in a secondmate while reporting local growth',ownership),
        ('Diagnose unsafe and missing inputs, retain findings on refused publication, and safely sweep orphans',adversarial),
        ('Reject an altered authenticated shim without executing it',authenticated_guard),
        ('Cap a real oversized diagnostic with the truncation marker while retaining full deduplication state',capped),
    ]:
        scenario(name,fn)
finally:
    shutil.rmtree(WORK,ignore_errors=True)
    say('Disposable live homes and instruction copies removed.')
    (EVIDENCE/'live-growth-transcript.log').write_text('\n'.join(LOG)+'\n')
    (EVIDENCE/'live-growth-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
if any(result['result']!='pass' for result in RESULTS):
    raise SystemExit(1)

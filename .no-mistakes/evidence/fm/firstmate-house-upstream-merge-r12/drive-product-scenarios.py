import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path.cwd()
evidence = Path('/Users/jarad/.no-mistakes/evidence/01M47Y1SJ1V22FPGCJR39F05VD')
lab = root / 'fm-test-phase-temp' / 'product'
lab.mkdir()
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'NM_HOME'):
        env.pop(key)
env.update(TMPDIR=str(root / 'fm-test-phase-temp' / 'tmp'),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')

def home(name):
    p = lab / name
    for child in ('state', 'data', 'config', 'projects'):
        (p / child).mkdir(parents=True)
    return p

def run(args, *, cwd=root, extra=None, expect=0, log=None):
    merged = env | (extra or {})
    p = subprocess.run(args, cwd=cwd, env=merged, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
    if log is not None:
        log.append('$ ' + ' '.join(map(str, args)) + '\n' + p.stdout + f'\nexit={p.returncode}\n')
    assert p.returncode == expect, (args, p.returncode, p.stdout)
    return p.stdout

def save(name, lines):
    (evidence / name).write_text('\n'.join(lines))

try:
    h = home('briefs')
    log = ['Real fm-brief.sh public CLI; stock /bin/bash; disposable FM_HOME. No harness launched.']
    run(['/bin/bash', '-c', 'echo "$BASH_VERSION"'], log=log)
    for mode in ('no-mistakes', 'direct-PR', 'local-only', 'scout', 'secondmate'):
        args = ['/bin/bash', 'bin/fm-brief.sh', 'proof-' + mode]
        args += ['--secondmate', '--no-projects'] if mode == 'secondmate' else ['sample'] + (['--scout'] if mode == 'scout' else ['--mode', mode])
        run(args, extra={'FM_HOME': str(h), 'FM_SECONDMATE_CHARTER': 'Supervise the disposable sample domain.'}, log=log)
        text = (h / 'data' / ('proof-' + mode) / 'brief.md').read_text()
        assert '# Definition of done' in text and '# Firstmate instruction inbox' in text
        (evidence / ('generated-' + mode + '-brief.md')).write_text(text)
    run(['/bin/bash', 'bin/fm-brief.sh', 'proof-base', 'sample', '--mode', 'direct-PR', '--base-branch', 'release/proof'], extra={'FM_HOME': str(h)}, log=log)
    text = (h / 'data/proof-base/brief.md').read_text()
    assert 'Base branch: release/proof' in text and '--base release/proof' in text
    (evidence / 'generated-named-base-brief.md').write_text(text)
    for name, flags in (
        ('local', ['--mode', 'local-only', '--base-branch', 'release/proof']),
        ('invalid', ['--mode', 'direct-PR', '--base-branch', 'bad..name']),
        ('gerrit', ['--mode', 'direct-PR', '--forge', 'gerrit', '--base-branch', 'release/proof']),
        ('house', ['--mode', 'direct-PR', '--base-branch', 'release/proof', '--house-feature', 'proof', '--branch-base', 'house']),
    ):
        run(['/bin/bash', 'bin/fm-brief.sh', 'refuse-' + name, 'sample'] + flags, extra={'FM_HOME': str(h)}, expect=1, log=log)
        assert not (h / 'data' / ('refuse-' + name) / 'brief.md').exists()
    role = run(['/bin/bash', '-c', '. "$1/bin/fm-dod-lib.sh"; fm_brief_worker_role "$2/state" proof "$1"', '_', str(root), str(h)], log=log)
    assert str(root / '.agents/skills/firstmate-coding-guidelines/SKILL.md') in role
    save('brief-product-transcript.txt', log)

    h = home('spend')
    log = ['Real fm-pipeline-spend.sh public CLI; no fake no-mistakes or database.']
    relative_home = str(h.relative_to(root))
    run(['/bin/bash', 'bin/fm-pipeline-spend.sh', 'record', 'absent'], extra={'FM_HOME': relative_home}, log=log)
    assert not (h / 'data/pipeline-spend.jsonl').exists()
    (h / 'config/pipeline-spend').touch()
    (h / 'state/gone.meta').write_text('kind=ship\nspawn_gen=proof1\nworktree=' + str(h / 'gone-copy') + '\n')
    for _ in range(2):
        run(['/bin/bash', 'bin/fm-pipeline-spend.sh', 'record', 'gone'], extra={'FM_HOME': relative_home}, log=log)
    rows = (h / 'data/pipeline-spend.jsonl').read_text().splitlines()
    assert len(rows) == 1
    row = json.loads(rows[0])
    assert row['source'] == 'unavailable' and row['total'] is None and row['runs'] == []
    log.append('Persisted ledger after retry:\n' + rows[0])
    (h / 'override-data').mkdir()
    run(['/bin/bash', 'bin/fm-pipeline-spend.sh', 'record', 'gone'], extra={'FM_HOME': relative_home, 'FM_DATA_OVERRIDE': str((h / 'override-data').relative_to(root))}, log=log)
    override = json.loads((h / 'override-data/pipeline-spend.jsonl').read_text())
    assert override['task'] == 'gone' and override['source'] == 'unavailable'
    log.append('Relative FM_DATA_OVERRIDE ledger:\n' + json.dumps(override))
    copy = h / 'task-copy'
    run(['git', 'init', '-q', '-b', 'fm/proof', str(copy)])
    (copy / 'proof.txt').write_text('disposable product check\n')
    run(['git', '-C', str(copy), 'add', 'proof.txt'])
    run(['git', '-C', str(copy), '-c', 'user.name=Product proof', '-c', 'user.email=proof@example.invalid', 'commit', '-qm', 'seed'])
    (h / 'state/copy.meta').write_text('kind=ship\nspawn_gen=proof2\nworktree=' + str(copy) + '\n')
    for _ in range(2):
        run(['/bin/bash', 'bin/fm-pipeline-spend.sh', 'record', 'copy'], extra={'FM_HOME': relative_home, 'NM_HOME': str(h / 'nm')}, log=log)
    rows = (h / 'data/pipeline-spend.jsonl').read_text().splitlines()
    assert len(rows) == 2
    row = json.loads(rows[1])
    assert row['task'] == 'copy' and row['source'] == 'unavailable' and row['branch'] == 'fm/proof'
    log.append('Live task copy; real no-mistakes read on uninitialized disposable NM_HOME; ledger:\n' + rows[1])
    for task, expected in (('missing', 1), ('../unsafe', 2)):
        run(['/bin/bash', 'bin/fm-pipeline-spend.sh', 'record', task], extra={'FM_HOME': relative_home}, expect=expected, log=log)
    save('spend-product-transcript.txt', log)

    h = home('contributions')
    url = 'https://github.com/disposable-proof/deleted/pull/1'
    d = h / 'data/proof'
    d.mkdir()
    record = {'schema': 'fm-contributions.v1', 'task': 'proof', 'records': [{'url': url, 'kind': 'pr', 'checked_at': None, 'error': 'object unavailable', 'observation': None, 'verdict': None, 'pending': [], 'seen': [], 'notified': []}]}
    (d / 'contributions.json').write_text(json.dumps(record))
    input_path = h / 'input.json'
    input_path.write_text(json.dumps({'tasks': [], 'backlog': {'present': True, 'records': [{'id': 'proof', 'structured': True, 'links': [url]}]}}))
    log = ['Real fm-contributions.sh local retire and snapshot commands on disposable saved records; no forge polling or forge substitution. This proves the local retirement contract only.']
    extra = {'FM_HOME': str(h)}
    cli = ['/bin/bash', 'bin/fm-contributions.sh']
    before = json.loads(run(cli + ['snapshot', str(input_path), '--all'], extra=extra, log=log))
    assert before['known'] == 1 and before['checked'] == 0
    for task, actor, reason in (('proof', 'fleet', 'gone'), ('proof', 'captain', '  '), ('unknown', 'captain', 'gone')):
        run(cli + ['retire', task, url, actor, reason], extra=extra, expect=1, log=log)
        assert 'retired' not in json.loads((d / 'contributions.json').read_text())['records'][0]
    record['records'][0]['pending'] = [{'token': 'comment:proof', 'type': 'comment'}]
    (d / 'contributions.json').write_text(json.dumps(record))
    run(cli + ['retire', 'proof', url, 'captain', 'gone'], extra=extra, expect=1, log=log)
    record['records'][0]['pending'] = []
    (d / 'contributions.json').write_text(json.dumps(record))
    run(cli + ['retire', 'proof', url, 'captain', 'repository permanently removed'], extra=extra, log=log)
    saved = (d / 'contributions.json').read_text()
    assert json.loads(saved)['records'][0]['retired']['reason'] == 'repository permanently removed'
    run(cli + ['retire', 'proof', url, 'captain', 'replacement reason'], extra=extra, log=log)
    assert (d / 'contributions.json').read_text() == saved
    after = json.loads(run(cli + ['snapshot', str(input_path), '--all'], extra=extra, log=log))
    log.append('Saved retirement provenance:\n' + saved)
    save('retirement-product-transcript.txt', log)
    assert after['known'] == 0 and after['complete'] is True, after

    log = ['Real fm-timeout-lib.sh with /bin/bash 3.2, actual Perl watchdog and child processes. No command substitutions or fake services.']
    for invocation in ('fm_exec_timed 5 1 /bin/sh -c', '(fm_exec_timed 5 1 /bin/sh -c'):
        for child, expected in (("'echo complete; exit 7'", 7), ("'kill -TERM $$'", 143), ("'kill -KILL $$'", 137)):
            line = invocation + ' ' + child + (')' if invocation.startswith('(') else '')
            run(['/bin/bash', '-c', '. "$1/bin/fm-timeout-lib.sh"; ' + line, '_', str(root)], expect=expected, log=log)
    start = time.monotonic()
    run(['/bin/bash', '-c', '. "$1/bin/fm-timeout-lib.sh"; fm_exec_timed 1 1 /bin/sh -c \'trap "" TERM; echo ignoring-TERM; exec sleep 30\'', '_', str(root)], expect=124, log=log)
    elapsed = time.monotonic() - start
    assert elapsed < 8
    log.append(f'TERM-ignoring child stopped after {elapsed:.3f}s (bound=1s, grace=1s; exit 124).')
    save('timeout-product-transcript.txt', log)
finally:
    shutil.rmtree(lab)

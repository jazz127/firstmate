import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
evidence = Path(__file__).parent
lab = Path(tempfile.mkdtemp(prefix='live-capacity-', dir=root / '.gate-validation'))
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'GIT_CONFIG_COUNT'):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1')
results = []
producer = None

def run(argv, home=None, check=True):
    local = dict(env)
    if home:
        local.update(FM_HOME=str(home), FM_SPAWN_NO_GUARD='1', TMUX=str(lab / 'unused-private-socket') + ',1,0')
    result = subprocess.run([str(a) for a in argv], cwd=root, env=local, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode:
        raise RuntimeError(f'{argv}: {result.returncode}\n{result.stdout}')
    return result

def make_home(name):
    home = lab / name
    run([root / 'bin/fm-lab-home.sh', 'create', home])
    (home / 'config/crew-harness').write_text('codex\n')
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    (home / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (home / 'data/new-worker').mkdir()
    (home / 'data/new-worker/brief.md').write_text('# Task\n## Captain\'s intent\n{TASK}\n\n## Firstmate spec\nDisposable capacity boundary check.\n\n# Definition of done\nDelivery contract: mode=local-only\n')
    run(['tasks-axi', 'add', 'new-worker', 'Disposable queued worker', '--kind', 'ship', '--file', home / 'data/backlog.md'])
    return home

def binding(child, parent):
    (child / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')

def registry(parent, children):
    (parent / 'data/secondmates.md').write_text(''.join(f'- {name} - local lab (home: {home}; scope: work; projects: project; added 2026-10-08)\n' for name, home in children))

def spawn(name, home, project, expected_code, expected_text):
    before = (home / 'data/backlog.md').read_bytes()
    inventory = run(['git', '-C', project, 'worktree', 'list', '--porcelain']).stdout
    result = run([root / 'bin/fm-spawn.sh', 'new-worker', project, '--backend', 'tmux', '--harness', 'codex', '--mode', 'local-only', '--yolo', 'off'], home, check=False)
    untouched = (before == (home / 'data/backlog.md').read_bytes()
                 and not (home / 'state/new-worker.meta').exists()
                 and not (home / 'data/new-worker/launch-brief.md').exists()
                 and inventory == run(['git', '-C', project, 'worktree', 'list', '--porcelain']).stdout)
    row = {'scenario': name, 'driver': 'real bin/fm-spawn.sh; real Git and tasks-axi; no substitutes; stops before terminal/worktree launch', 'exit': result.returncode, 'output': result.stdout, 'backlog_records_and_worktrees_unchanged': untouched}
    results.append(row)
    print(json.dumps(row), flush=True)
    assert result.returncode == expected_code, row
    assert expected_text in result.stdout, row
    assert untouched, row

try:
    main = make_home('root')
    a, b, c = [make_home(name) for name in ('a', 'b', 'c')]
    binding(a, main)
    binding(b, main)
    binding(c, a)
    registry(main, [('a', a), ('b', b)])
    registry(a, [('c', c)])
    registry(b, [])
    project = lab / 'project'
    origin = lab / 'origin.git'
    run(['git', 'init', '-q', '-b', 'main', project])
    run(['git', '-C', project, '-c', 'user.name=Gate Test', '-c', 'user.email=gate@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-q', '--allow-empty', '-m', 'Disposable project'])
    run(['git', 'clone', '-q', '--bare', project, origin])
    run(['git', '-C', project, 'remote', 'add', 'origin', origin])
    bproject = b / 'projects/project'
    run(['git', 'clone', '-q', origin, bproject])
    capacity = main / 'config/project-capacity'
    capacity.write_text('project 1\n')
    holder = c / 'state/holder.meta'
    holder.write_text(f'project={project}\nkind=ship\nharness=codex\nspawn_gen=old\n')
    spawn('Nested root/A/B/C holder defers a fresh spawn', main, project, 75, f'holder in {c}')
    spawn('Sibling home reads the root limit for a same-origin clone', b, bproject, 75, f'holder in {c}')
    aregistry = a / 'data/secondmates.md'
    aregistry.chmod(0)
    try:
        spawn('Unreadable A registry refuses admission despite later readable B', main, project, 1, f'registry cannot be read at {aregistry}')
    finally:
        aregistry.chmod(0o600)
    capacity.write_text('project 0\n')
    spawn('Malformed declaration refuses a fresh spawn', main, project, 1, 'project capacity declaration is unreadable')
    capacity.write_text('project 1\n')
    holder.write_text(f'project={project}\nkind=ship\nharness=codex\nspawn_gen=old\npr=https://example.invalid/ready/1\n')
    # Use the actual process-owned admission producer, then consume its persisted
    # reservation through the real spawn entrypoint in another local home.
    producer_script = r'''
set -eu
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-project-capacity-lib.sh"
lock=$(fm_treehouse_project_lock_path "$3")
fm_lock_try_acquire "$lock"
fm_project_capacity_reserve "$lock" "$2/state" holder new-generation
trap 'fm_project_capacity_release "$FM_PROJECT_CAPACITY_RESERVATION"' EXIT
fm_lock_release "$lock"
touch "$4/producer-ready"
while [ ! -f "$4/producer-stop" ]; do sleep 0.05; done
'''
    producer_env = dict(env, FM_HOME=str(c))
    producer = subprocess.Popen(['/bin/bash', '-c', producer_script, '_', str(root), str(c), str(project), str(lab)], cwd=root, env=producer_env)
    import time
    for _ in range(200):
        if (lab / 'producer-ready').exists():
            break
        assert producer.poll() is None, 'admission producer exited'
        time.sleep(0.05)
    assert (lab / 'producer-ready').exists()
    spawn('Fresh reservation counts while old PR-ready generation survives', b, bproject, 75, '(pending)')
    holder.write_text(f'project={project}\nkind=ship\nharness=codex\nspawn_gen=new-generation\n')
    spawn('Matching publication and reservation count one occupant', b, bproject, 75, '1 already hold a place')
    holder.write_text(f'project={project}\nkind=ship\nharness=codex\nspawn_gen=new-generation\npr=https://example.invalid/ready/2\n')
    spawn('Current-generation PR handoff frees the place before retirement', b, bproject, 1, 'still contains {TASK}')
    (lab / 'producer-stop').touch()
    assert producer.wait(timeout=10) == 0
    producer = None
    holder.unlink()
    spawn('Removing the holder leaves capacity available', main, project, 1, 'still contains {TASK}')
finally:
    if producer:
        (lab / 'producer-stop').touch()
        try:
            producer.wait(timeout=10)
        except subprocess.TimeoutExpired:
            producer.terminate()
            producer.wait(timeout=10)
    (evidence / 'live-capacity.json').write_text(json.dumps(results, indent=2) + '\n')
    shutil.rmtree(lab)

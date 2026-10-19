import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tomllib

root = Path.cwd()
lab = root / '.test-runtime' / 'local'
evidence = Path(sys.argv[1])
lab.mkdir(parents=True)
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(lab / 'home'), XDG_CONFIG_HOME=str(lab / 'xdg'))
records = []

def run(args, expected=0):
    p = subprocess.run(args, env=env, text=True, capture_output=True)
    records.append(dict(command=args, exit=p.returncode, stdout=p.stdout, stderr=p.stderr))
    assert p.returncode == expected, records[-1]
    return p.stdout

state = lab / 'home' / 'state'
state.mkdir(parents=True)
event = str(root / 'bin/fm-busy-event.sh')
gen = run(['bash', event, 'arm', str(state), 'task']).strip()
run(['bash', event, 'apply', str(state), 'task', 'busy', '--gen', gen,
     '--source', 'polytoken-hook', '--event', 'pre-user-prompt'])
before = (state / 'task.busy-state').read_bytes()
run(['bash', event, 'apply', str(state), 'task', 'idle', '--gen', gen,
     '--if-seq', '1', '--source', 'fm-interrupt', '--event', 'interrupt', '--turn-ended'], 1)
assert (state / 'task.busy-state').read_bytes() == before
assert not (state / 'task.turn-ended').exists()
start = int(time.time())
run(['bash', event, 'apply', str(state), 'task', 'idle', '--gen', gen,
     '--if-seq', '2', '--source', 'fm-interrupt', '--event', 'interrupt', '--turn-ended'])
closed = (state / 'task.busy-state').read_text()
fields = closed.split()
assert fields[0] == 'v1', closed
record = dict(field.split('=', 1) for field in fields[1:])
assert record['gen'] == gen and record['seq'] == '3' and record['state'] == 'idle', closed
assert record['source'] == 'fm-interrupt' and record['event'] == 'interrupt', closed
assert start <= int(record['ts']) <= int(time.time()), closed
assert (state / 'task.turn-ended').exists()
new_gen = run(['bash', event, 'arm', str(state), 'task']).strip()
assert new_gen != gen
new_record = (state / 'task.busy-state').read_bytes()
run(['bash', event, 'apply', str(state), 'task', 'idle', '--gen', gen,
     '--if-seq', '1', '--source', 'fm-interrupt', '--event', 'interrupt'], 1)
assert (state / 'task.busy-state').read_bytes() == new_record
records.append(dict(scenario='Conditional close preserves newer sequence and generation; matching close advances sequence and house timestamp', before=before.decode(), closed=closed, rearmed=new_record.decode()))

cfg = lab / 'xdg' / 'polytoken'
cfg.mkdir(parents=True)
base = 'version: 4\nproviders:\n  fixture:\n    api_key: disposable-config-value\n'
for name, policy, expected in [('anchored', 'default_permission_matcher: &policy bypass_plus\n', 'bypass_plus'),
                               ('alias', 'policy: &policy bypass_plus\ndefault_permission_matcher: *policy\n', 'bypass_plus'),
                               ('prompt', 'default_permission_matcher: prompt\n', 'bypass')]:
    original = base + policy
    (cfg / 'config.yaml').write_text(original)
    output = lab / name
    run(['bash', '-c', '. "$1"; fm_polytoken_write_config "$2"', '_',
         str(root / 'bin/fm-polytoken-lib.sh'), str(output)])
    parsed = json.loads(run(['ruby', '-ryaml', '-rjson', '-e',
                             'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))',
                             str(output / 'config.yaml')]))
    assert parsed['default_permission_matcher'] == expected
    assert parsed['providers']['fixture']['api_key'] == 'disposable-config-value'
    assert (output / 'config.yaml').stat().st_mode & 0o777 == 0o600
    if expected == 'bypass_plus':
        assert (output / 'config.yaml').read_text() == original
    records.append(dict(scenario='Mirror permission policy and provider configuration', case=name, generated=parsed))

sidebar = lab / 'herdr-config.toml'
original = b'[ui]\nagent_panel_sort = "spaces"\n'
sidebar.write_bytes(original)
groups = str(root / 'bin/fm-herdr-groups.sh')
run(['bash', groups, 'sidebar-config', '--apply', str(sidebar)])
parsed = tomllib.loads(sidebar.read_text())
assert parsed['ui']['agent_panel_sort'] == 'spaces'
# Independent oracle: docs/herdr-backend.md, "Sidebar rows".
assert parsed['ui']['sidebar']['spaces']['rows'] == [
    ['state_icon', 'workspace'], [{'token': '$fm_group', 'bold': True}, '$fm_state']]
assert parsed['ui']['sidebar']['agents']['rows'] == [
    ['state_icon', {'token': '$fm_group', 'bold': True}, '$fm_state', '$fm_task']]
backups = list(lab.glob('herdr-config.toml.bak-*'))
assert len(backups) == 1 and backups[0].read_bytes() == original
before = sidebar.read_bytes()
run(['bash', groups, 'sidebar-config', '--apply', str(sidebar)], 1)
assert sidebar.read_bytes() == before
records.append(dict(scenario='Apply sidebar configuration once, preserving exact backup bytes', generated=parsed))

config_dir = lab / 'home' / 'config'
config_dir.mkdir(parents=True)
for task, project, status in [('shop-run', 'storefront', 'working: go'),
                              ('shop-ask', 'storefront', 'needs-decision [key=choice]: choose'),
                              ('api-done', 'api', 'done: shipped'),
                              ('other-fail', 'misc', 'failed: broken')]:
    (state / (task + '.meta')).write_text(
        f'window=lab:w:{task}\nproject=/disposable/{project}\nkind=ship\n'
        f'backend=herdr\nherdr_session=fm-lab-offline\nherdr_workspace_id=w\n'
        f'herdr_pane_id={task}\n')
    (state / (task + '.status')).write_text(status + '\n')
assert run(['bash', groups, 'plan']) == ''
(config_dir / 'herdr-project-groups').write_text('Web task:shop repo:api\nOther *\n')
plan = run(['bash', groups, 'plan'])
rows = {row[0]: row for row in (line.split('\t') for line in plan.splitlines())}
assert rows['shop-ask'][1:3] == ['Web', 'needs-captain']
assert rows['shop-run'][1:3] == ['Web', 'running']
assert rows['api-done'][1:3] == ['Web', 'done']
assert rows['other-fail'][1:3] == ['Other', 'problem']
ordered = [row[0] for row in sorted(rows.values(), key=lambda row: row[3])]
assert ordered == ['shop-ask', 'shop-run', 'api-done', 'other-fail']
records.append(dict(scenario='Opt-in group plan sorts decisions before running and completed tasks, preserving rule order', plan=plan))

project = lab / 'project'
facet = project / '.polytoken' / 'facets' / 'firstmate-worker.md'
facet.parent.mkdir(parents=True)
original_facet = b'project-owned facet\n\n'
facet.write_bytes(original_facet)
run(['bash', '-c', '. "$1"; fm_polytoken_write_facet "$2" "$3"', '_',
     str(root / 'bin/fm-polytoken-lib.sh'), str(project), str(state / 'task.inbox')], 1)
assert facet.read_bytes() == original_facet
target = lab / 'project-owned.md'
target.write_bytes(original_facet)
facet.unlink()
facet.symlink_to(target)
run(['bash', '-c', '. "$1"; fm_polytoken_write_facet "$2" "$3"', '_',
     str(root / 'bin/fm-polytoken-lib.sh'), str(project), str(state / 'task.inbox')], 1)
assert facet.is_symlink() and target.read_bytes() == original_facet
records.append(dict(scenario='Facet writer refuses existing files and symlinks while preserving exact project-owned bytes', bytes=original_facet.decode()))
evidence.write_text(json.dumps(records, indent=2) + '\n')
print('Local product checks completed; transcript: ' + str(evidence))

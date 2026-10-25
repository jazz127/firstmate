import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M5SEVNGRN2MRFNS682WZY649')
lab = Path(tempfile.mkdtemp(prefix='portable-paths-', dir=ROOT / '.phase-test-tmp'))
log = []
results = []
base_env = dict(os.environ)
for key in list(base_env):
    if key.startswith('FM_') or key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR'):
        base_env.pop(key)
base_env.update(FM_HOME=str(lab / 'home'), HOME=str(lab / 'user-home'),
                TMPDIR=str(lab), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                GIT_AUTHOR_NAME='Path validation', GIT_AUTHOR_EMAIL='validation@example.invalid',
                GIT_COMMITTER_NAME='Path validation', GIT_COMMITTER_EMAIL='validation@example.invalid')
wt = lab / 'repo'
scratch = lab / 'task-output'
for directory in (wt, scratch, lab / 'home/config', lab / 'user-home', lab / 'outside'):
    directory.mkdir(parents=True, exist_ok=True)
draft = scratch / 'draft.md'
(wt / 'proof.txt').write_text('Captured portable evidence: sha256 and count remain unchanged.\n')
(scratch / 'proof.txt').write_text('Task capture: 3 records\n')
(lab / 'outside/proof.txt').write_text('Other task: forbidden\n')

def run(argv, env=None):
    return subprocess.run([str(a) for a in argv], cwd=ROOT, env=env or base_env,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def git(*args):
    result = run(['git', *args])
    if result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()

def body(artifact='proof.txt', command='cat proof.txt'):
    return ('External validation passed.\n'
            f'evidence-artifact: {artifact}\nevidence-command: {command}\n'
            'evidence-captured: 2026-10-26T00:00:00Z\n')

def check(name, text, expected=0, message=None, worktree=None, mode='cli', project='', env=None):
    draft.write_text(text)
    before = draft.read_bytes()
    active_wt = worktree or wt
    if mode == 'cli':
        argv = [ROOT / 'bin/fm-pr-body-preflight.sh', draft, active_wt, scratch]
    else:
        # The production shared validator is also a shell-callable interface.
        # No PR URL is supplied: no forge read or publication is claimed here.
        argv = ['bash', '-c', '. "$1/bin/fm-dod-lib.sh"; text=$(cat "$2"); '
                'if [ "$5" = private ]; then '
                'fm_dod_validate_intent_evidence "$text" "$3" "$4"; '
                'else fm_dod_validate_published_intent "$text" "$3" "$4" "" "" "$5" "$6"; fi',
                '_', ROOT, draft, active_wt, scratch, mode, project]
    result = run(argv, env)
    ok = result.returncode == expected and (message is None or message in result.stdout)
    ok = ok and before == draft.read_bytes()
    results.append(dict(name=name, passed=ok, expected_exit=expected, exit=result.returncode))
    log.extend([f'### {name}', '', 'Input body:', '```text', text.rstrip(), '```',
                'Command: `' + ' '.join(str(a) for a in argv) + '`', '',
                f'Exit: {result.returncode}; expected: {expected}; body unchanged: {before == draft.read_bytes()}',
                '```text', result.stdout.rstrip() or '(no output)', '```', ''])
    if not ok:
        raise AssertionError(f'{name}: {result.returncode}: {result.stdout}')

try:
    git('-C', wt, 'init', '-q', '-b', 'main')
    git('-C', wt, 'add', 'proof.txt')
    git('-C', wt, 'commit', '-q', '-m', 'Disposable evidence')
    for artifact in ('proof.txt', '<task-output>/proof.txt', '<firstmate-home>/../task-output/proof.txt'):
        check(f'Portable artifact resolves: {artifact}', body(artifact, f'cat {artifact}'))
    (scratch / 'home/firstmate').mkdir(parents=True)
    (scratch / 'home/firstmate/proof.txt').write_text('Portable suffix\n')
    check('Descriptor suffix remains portable', body('<task-output>~/proof.txt'))
    for command in ("rg -g '**/home/**'", "rg -g '**/Users/**'", "rg -g '**/tmp/fm-*/**'",
                    '`cat fixtures/home/firstmate/proof.txt`', 'cat <task-output>~/proof.txt',
                    'cat %2Fhome%2Ffirstmate/config', 'cat file:///%2568ome/firstmate/config'):
        check(f'Portable command is accepted: {command}', body(command=command))
    forbidden = [
        '/tmp/fm-task/proof.txt', '~/proof.txt', '~', '~',
        '**~/**', '**/tmp/fm-task/**',
        '**~/proof.txt *contains output***',
        '***~/proof.txt** contains output*',
        '**/tmp/fm-task/proof.txt\ncontains output**',
        '@~/headers', 'tar -czf/tmp/fm-task/proof.tgz result.json',
        'cc -isystem/home/firstmate/include main.c', 'file:///%68ome/firstmate/config',
        f'"{lab}~"', str(wt / 'proof.txt'), str(scratch / 'proof.txt'),
        str(lab / 'user-home/config'), 'evidence-artifact:/tmp/fm-task/proof.txt']
    for raw in forbidden:
        check(f'Refuse worker path in prose: {raw}', f'Output: {raw}\n', 1, 'worker-local absolute path')
    for field in ('evidence-artifact', 'evidence-command'):
        for raw in ('~', '~', '@~/headers',
                    'tar -czf/tmp/fm-task/proof.tgz result.json', '**/tmp/fm-task/**'):
            check(f'Refuse {field} worker path: {raw}', f'{field}: {raw}\n', 1, 'worker-local absolute path')
    space_home = lab / 'Firstmate Home'
    space_home.mkdir()
    special_env = dict(base_env, FM_HOME=str(space_home) + '/')
    check('Refuse shell-escaped configured home with spaces',
          'Output: cat ' + str(space_home).replace(' ', '\\ ') + '/proof.txt\n',
          1, 'worker-local absolute path', env=special_env)
    for artifact, message in (
        ('<task-output>/missing.txt', 'missing or unreadable'),
        ('<task-output>/../outside/proof.txt', 'outside the worker worktree or task temp directory'),
        ('<firstmate-home>/config/proof.txt', 'outside the worker worktree or task temp directory'),
        ('<unknown>/proof.txt', 'unknown artifact descriptor')):
        check(f'Artifact guard: {artifact}', body(artifact), 1, message)
    (scratch / 'escape.txt').symlink_to(lab / 'outside/proof.txt')
    (scratch / 'nested').symlink_to(lab / 'outside', target_is_directory=True)
    for artifact in ('<task-output>/escape.txt', '<task-output>/nested/proof.txt'):
        check(f'Symlink guard: {artifact}', body(artifact), 1, 'resolved artifact is outside the allowed roots')
    check('Evidence claim still requires provenance', 'External validation passed.\n', 1, 'missing evidence-artifact')
    policy = lab / 'home/config/published-path-prefixes'
    common = wt / '.git'
    check('Home documentation requires an opt-in', 'Host config: ~/host_config/private\n', 1,
          'worker-local absolute path')
    policy.write_text(f'{common} ~/host_config {scratch}\n')
    for text in ('~/host_config', '~/host_config/private',
                 '~/host%5fconfig/private'):
        check(f'Exact configured prefix is accepted: {text}', f'Host config: {text}\n')
    for text in ('~/hostconfig/private', '~/host_config_other/private',
                 '~/host_config/../secret', '/tmp/fm-task/proof.txt', str(scratch / 'proof.txt')):
        check(f'Override does not permit: {text}', f'Host config: {text}\n', 1, 'worker-local absolute path')
    other = lab / 'other-project'
    other.mkdir()
    git('-C', other, 'init', '-q', '-b', 'main')
    check('Override does not apply to another project', 'Host config: ~/host_config/private\n',
          1, 'worker-local absolute path', worktree=other)
    linked = lab / 'linked'
    git('-C', wt, 'worktree', 'add', '-q', '-b', 'linked', linked)
    check('Linked worktree shares project override', 'Host config: ~/host_config/private\n', worktree=linked)
    check('Override does not broaden artifact containment', body('~/host_config/private'), 1,
          'outside the worker worktree or task temp directory')
    git('-C', wt, 'worktree', 'remove', linked)
    check('Retired validation uses recorded project after worktree removal',
          'Host config: ~/host_config/private\n', mode='retired', worktree=linked, project=wt)
    check('Retired validation still rejects leaked home paths',
          'Output: ~\n', 1, 'worker-local absolute path',
          mode='retired', worktree=linked, project=wt)
    check('Private intent retains real artifact path', body(str(scratch / 'proof.txt')), mode='private')
    check('Publication rejects the same private path', body(str(scratch / 'proof.txt')), 1,
          'worker-local absolute path', mode='publish')
    log.extend(['Evidence payload SHA256 (unchanged): `' + hashlib.sha256((wt / 'proof.txt').read_bytes()).hexdigest() + '`', ''])
finally:
    shutil.rmtree(lab)
    (EVIDENCE / 'portable-paths-product-transcript.md').write_text(
        '# Portable evidence paths: local product CLI transcript\n\n'
        'Oracle: accepted portable-path intent and recorded R8/R9 decisions. '
        'Driver: real bin/fm-pr-body-preflight.sh and shell-callable published/private validators. '
        'Isolated Git projects and captured files are disposable data; no tool or upstream service was substituted. '
        'No forge publication/readback is claimed. Every draft is checked for byte preservation.\n\n' + '\n'.join(log))
    (EVIDENCE / 'portable-paths-product-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(f'Completed {len(results)} local product checks; disposable lab removed.')

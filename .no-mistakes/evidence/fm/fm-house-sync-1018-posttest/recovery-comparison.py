import os
import shlex
import subprocess
from pathlib import Path

root = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M5A3J0Z19TY21ZHBQEYSDSAM')
subject = 'tests/fm-spawn-dispatch-profile.test.sh'
fixture_import = '. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"'
entrypoint = '\ntest_launch_preserves_inherited_git_config\n'
env = os.environ.copy()
env.pop('TMPDIR', None)
with (evidence / 'recovery-comparison.log').open('w') as log:
    for label, revision, expected in [
        ('before fixture repair', '350afd57916bd3a14d9935da178d8a95f3385da5', 1),
        ('after fixture repair', '23e127c1c130c72a4ffbc960ef6c68b8df9f0d2b', 0),
    ]:
        source = subprocess.check_output(['git', 'show', f'{revision}:{subject}'], text=True)
        # Load the unchanged helper definitions and select only the recovery
        # case; the subprocess still executes real fm-spawn against its fakes.
        definitions, _ = source.split(entrypoint, 1)
        driver = definitions.replace(fixture_import, '. ' + shlex.quote(str(root / 'tests/fixtures.sh')))
        driver += '\ntest_local_secondmate_recovery_keeps_seat\n'
        driver += '\nprintf "Persisted recovered metadata:\\n"\n'
        driver += 'cat "$HOME_DIR/state/profile-local-seat-recovery-z4c.meta"\n'
        driver += 'printf "Recovered launch command (synthetic credentials):\\n"\n'
        driver += 'cat "$LAUNCH_LOG"\n'
        log.write(f'=== {label}: {revision} (fake tmux and fake Codex login) ===\n')
        log.flush()
        result = subprocess.run(['bash', '-c', driver], env=env, stdout=log, stderr=subprocess.STDOUT)
        log.write(f'actual exit={result.returncode}; expected exit={expected}\n')
        log.flush()
        if result.returncode != expected:
            raise SystemExit(f'unexpected recovery result for {revision}: {result.returncode}')

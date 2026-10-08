"""Focused behavioral probes; these library calls are offline, not live product validation.
Oracle: author requires whole qualifier words, with the existing provenance contract retained.
Run from the gate worktree after archiving baseline bin/ into .test-evidence-guard-tmp/baseline/.
"""
import datetime
import json
import pathlib
import subprocess

root = pathlib.Path.cwd()
tmp = root / '.test-evidence-guard-tmp'
evidence = pathlib.Path(__file__).parent
libs = {'baseline': tmp / 'baseline/bin/fm-dod-lib.sh', 'changed': root / 'bin/fm-dod-lib.sh'}
near = [
    'existing project delivery and merge rules',
    'delivery test passed', 'deliverable validation was confirmed',
    'olive scenario passed', 'realm test passed', 'realise validation passed',
    'unverified test passed', 'verifiedness test passed', 'externality test passed',
    'externalized test passed', 'independentlyconfirmed test passed',
    'independentness test passed',
    'live2 test passed', '2live test passed', 'live_test passed',
    'the live_status test passed', 'foo_verified test passed',
    '1 of 1 delivery scenarios', 'delivery evidence: passed',
    'validation was unverified', 'validation was unreal',
    'scenario with delivery passed', 'evidence of delivery was confirmed',
]
qualifiers = ['live', 'verified', 'real-account', 'real account', 'real', 'independent', 'independently', 'external', 'externally confirmed']
claims = [f'{word} test passed' for word in qualifiers]
claims += [f'the test was {word}' for word in qualifiers]
claims += [f'{word} passed test' for word in qualifiers]
claims += [f'scenario with {word} passed' for word in qualifiers if word != 'real']
claims += ['real-accounting test passed', '[live] test passed', '`live` test passed', 'LIVE-test passed',
           'validation was (verified)', '1 of 1 scenarios driven live',
           'live evidence: passed',
           'live\ntest\npassed', 'independently confirmed test passed']
records = []

def call(version, phase, text):
    command = ['bash', '-c', '. "$1"; fm_dod_validate_intent_evidence "$2" "$3" "$4" "$5"',
               '_', str(libs[version]), text, str(root), str(tmp), phase]
    result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    return result

for phase in ['preflight', 'publish']:
    for text, accept in [(s, True) for s in near] + [(s, False) for s in claims]:
        result = call('changed', phase, text)
        ok = result.returncode == 0 if accept else result.returncode == 1 and 'missing evidence-artifact' in result.stderr
        records.append({'phase': phase, 'intent': text, 'expected': 'accept ordinary prose' if accept else 'refuse unsupported claim',
                        'exit': result.returncode, 'stderr': result.stderr.strip(), 'matches_contract': ok})
        assert ok, records[-1]

regressions = []
for text in ['delivery test passed', 'deliverable validation was confirmed', 'olive scenario passed', 'realm test passed', 'realise validation passed',
             'unverified test passed', 'externality test passed', 'independentness test passed']:
    old = call('baseline', 'preflight', text)
    new = call('changed', 'preflight', text)
    regressions.append({'intent': text, 'baseline_exit': old.returncode, 'baseline_stderr': old.stderr.strip(),
                        'changed_exit': new.returncode, 'changed_stderr': new.stderr.strip()})
    assert old.returncode == 1 and new.returncode == 0, regressions[-1]

artifact = tmp / 'matrix-proof.txt'
produced = subprocess.run(['printf', '%s\n', 'captured boundary-validation output'], capture_output=True, text=True, check=True)
artifact.write_text(produced.stdout)
intent = ('live test passed\n' + f'evidence-artifact: {artifact}\n' +
          "evidence-command: printf '%s\\n' 'captured boundary-validation output'\n" +
          'evidence-captured: ' + datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds') + '\n')
for phase in ['preflight', 'publish']:
    result = call('changed', phase, intent)
    assert result.returncode == 0, result.stderr
    records.append({'phase': phase, 'intent': intent, 'expected': 'accept claim with readable in-scope provenance',
                    'exit': result.returncode, 'stderr': result.stderr.strip(), 'matches_contract': True})
artifact.unlink()
result = call('changed', 'publish', intent)
assert result.returncode == 1 and 'missing or unreadable' in result.stderr
records.append({'phase': 'publish', 'intent': intent, 'expected': 'refuse missing published artifact',
                'exit': result.returncode, 'stderr': result.stderr.strip(), 'matches_contract': True})
(evidence / 'guard-boundary-matrix.json').write_text(json.dumps({'classification': 'offline library probes, not live',
    'oracle': 'author whole-word requirement and existing provenance contract', 'cases': records, 'before_after': regressions}, indent=2))
print('Behavioral matrix matched the author whole-word contract in both preflight and publication.')
for record in regressions:
    print(json.dumps(record))

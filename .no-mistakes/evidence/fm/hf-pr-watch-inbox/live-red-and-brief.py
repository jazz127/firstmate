import os,pathlib,subprocess,shutil,json
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M5S58Y2CVNE3BFDC2CQ72Z4J')
lab=ROOT/'.test-feedback-red'
env=dict(os.environ,FM_HOME=str(lab))
for key in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS'):
    env.pop(key,None)
log=[]
def run(args):
    p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=120)
    if p.returncode: raise RuntimeError(p.stderr+p.stdout)
    return p.stdout
try:
    run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(lab)])
    cli=str(ROOT/'bin/fm-pr-feedback.sh')
    run([cli,'arm'])
    state=lab/'state'
    (state/'red.meta').write_text('kind=ship\nmode=direct-PR\npr=https://github.com/openai/codex/pull/56276\n')
    log.append('First public red-CI sweep:\n'+run([cli,'poll']))
    records=list((state/'red.inbox').glob('*.msg'))
    assert len(records)==1
    body=records[0].read_text()
    assert 'state=red' in body and 'state=green' not in body,body
    (E/'red-ci-inbox.msg').write_text(body)
    log.append(body)
    assert run([cli,'poll'])==''
    log.append('Repeated unchanged red result: silent; one pending durable record retained.')
    (state/'red.meta').unlink()
    (state/'gitlab.meta').write_text('kind=ship\nmode=direct-PR\npr=https://gitlab.example/isolated/project/-/merge_requests/1\n')
    assert run([cli,'poll'])==''
    assert not (state/'gitlab.inbox').exists()
    log.append('Unsupported GitLab task: no feedback or CI event and no inbox created.')
    brief=str(ROOT/'bin/fm-brief.sh')
    run([brief,'armed','public-example','--mode','no-mistakes'])
    emitted=(lab/'data/armed/brief.md').read_text()
    (E/'armed-worker-brief.md').write_text(emitted)
    assert "Use the following event wait only when this run's PR URL is on https://github.com/" in emitted
    gitlab=emitted.split('For GitLab and any other PR forge, or until a GitHub PR URL is known, use this drive contract:',1)[1]
    assert 'reattach at once' in gitlab
    run([brief,'gerrit','public-example','--mode','no-mistakes','--forge','gerrit'])
    (E/'gerrit-worker-brief.md').write_text((lab/'data/gerrit/brief.md').read_text())
    run([cli,'disarm'])
    run([brief,'unarmed','public-example','--mode','no-mistakes'])
    (E/'unarmed-worker-brief.md').write_text((lab/'data/unarmed/brief.md').read_text())
    log.append('Generated worker brief contract: GitHub event wait is conditional on URL; GitLab retains drive; Gerrit keeps pipeline wait; unarmed brief retains drive. Model interpretation was not tested.')
finally:
    if lab.exists(): shutil.rmtree(lab)
    log.append('Disposable home removed. Only GET requests were sent to GitHub; no GitLab endpoint was polled.')
    (E/'live-red-and-brief.log').write_text('\n\n'.join(log))

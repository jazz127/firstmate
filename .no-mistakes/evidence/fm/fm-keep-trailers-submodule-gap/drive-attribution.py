# Behavioral oracle: author intent requires t27sol attribution; the recorded user decision requires strip/legacy-keep for unknown owners.
# Rejects launch-owner leakage, lookalike owners/hosts, new attribution for unknown origins, stale shared fields, lost human trailers, and skipped repository hooks.
import os, pathlib, subprocess, tempfile, shutil, uuid, json
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M67KMZ5QNNAD8XZMBJPAR9ZV')
work = pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT / '.test-attribution-tmp'))
env = os.environ.copy()
for key in list(env):
    if key.startswith('GIT_CONFIG_') or key in ('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR'):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Attribution Tester', GIT_AUTHOR_EMAIL='test@example.invalid',
           GIT_COMMITTER_NAME='Attribution Tester', GIT_COMMITTER_EMAIL='test@example.invalid',
           TMPDIR=str(work))
sid = env.get('CODEX_THREAD_ID', '')
uuid.UUID(sid) # Use this real running Codex session, not a fabricated identity.
log=[]
results=[]
def run(*args, cwd=None, extra=None, input=None):
    result=subprocess.run([str(a) for a in args], cwd=cwd, env=env | (extra or {}),
                          input=input, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{args}: exit={result.returncode}\n{result.stdout}\n{result.stderr}')
    return result.stdout.strip()
def git(repo,*args,**kw): return run('git','-C',repo,*args,**kw)
def init(repo):
    repo.mkdir()
    git(repo,'init','-q','-b','main')
    git(repo,'commit','-q','--allow-empty','-m','Initial disposable data')
def add_hook(repo):
    hookdir=repo/'.local-hooks'
    hookdir.mkdir()
    hook=hookdir/'commit-msg'
    hook.write_text('#!/bin/sh\ngit interpret-trailers --in-place --trailer "Reviewed-by: Repository hook <hook@example.invalid>" "$1"\n')
    hook.chmod(0o700)
    git(repo,'config','core.hooksPath',str(hookdir))
message = '''fix: exercise commit repository attribution

Body example: Co-authored-by: Claude <noreply@anthropic.com>

Co-authored-by: Claude <noreply@anthropic.com>
Co-authored-by: Jane Doe <jane@example.invalid>
Agent-System: old-system
Agent-Platform: old-platform
Agent-Session: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
'''
def commit(repo,hooks,label,policy):
    # Use the public pane environment emitter, then let ordinary Git invoke hooks.
    overlay=work/'git-env'
    run(ROOT/'bin/fm-git-strip-ai-trailers.sh','env-file',hooks,overlay)
    run('bash','-c','. "$1"; git -C "$2" commit -q --allow-empty -F -',
        '_',overlay,repo,input=message)
    body=git(repo,'log','-1','--format=%B')
    trailers=run('git','interpret-trailers','--parse',cwd=repo,input=body).splitlines()
    assert 'Body example: Co-authored-by: Claude <noreply@anthropic.com>' in body
    assert 'Co-authored-by: Jane Doe <jane@example.invalid>' in trailers
    assert 'Reviewed-by: Repository hook <hook@example.invalid>' in trailers
    if policy=='add':
        for required in ['Co-authored-by: codex <noreply@firstmate.invalid>',
                         'Co-authored-by: Claude <noreply@anthropic.com>',
                         'Agent-System: fac:firstmate','Agent-Platform: codex',f'Agent-Session: {sid}']:
            assert trailers.count(required)==1,(label,required,trailers)
        assert not any('old-' in t or 'aaaaaaaa-' in t for t in trailers)
    elif policy=='strip':
        assert not any(t.startswith(('Agent-','Co-authored-by: codex','Co-authored-by: Claude')) for t in trailers), (label,trailers)
    else:
        for t in message.split('\n\n')[-1].splitlines():
            assert t in trailers,(label,t,trailers)
        assert not any(t.startswith('Co-authored-by: codex') or t=='Agent-System: fac:firstmate' for t in trailers)
    sha=git(repo,'rev-parse','HEAD')
    log.append(f'CASE {label}\nExpected: {policy}\nCommit: {sha}\n{body}\n')
    results.append({'name':label,'policy':policy,'commit':sha,'result':'pass'})
try:
    source=work/'source'
    init(source)
    for owner in ['another-owner','t27sol']:
        for keep in [False,True]:
            label=f'{owner}-keep-{keep}'
            parent=work/label
            init(parent)
            git(parent,'remote','add','origin',f'git@github.com:{owner}/parent.git')
            for child in ['t27sol','other','unknown']:
                git(parent,'-c','protocol.file.allow=always','submodule','add','-q',source,child)
                repo=parent/child
                if child=='t27sol': git(repo,'remote','set-url','origin','ssh://git@github.com/T27SOL/child.git')
                elif child=='other': git(repo,'remote','set-url','origin','https://github.com/t27sol-other/child.git')
                else: git(repo,'remote','remove','origin')
                assert (repo/'.git').is_file(), 'Not a real Git submodule'
                add_hook(repo)
            add_hook(parent)
            flag=work/f'flag-{label}'
            if keep: flag.touch()
            hooks=work/f'hooks-{label}'
            run(ROOT/'bin/fm-git-strip-ai-trailers.sh','install','--scoped-attribution',flag,
                work/'no-meta','codex','default',hooks,parent)
            # Prove install-time flag capture even if config changes during a launch.
            if keep: flag.unlink()
            else: flag.touch()
            commit(parent,hooks,f'{label}/parent','add' if owner=='t27sol' else ('keep' if keep else 'strip'))
            for child in ['t27sol','other','unknown']:
                commit(parent/child,hooks,f'{label}/{child}', 'add' if child=='t27sol' else ('keep' if keep else 'strip'))
            for name,url in [('empty',''),('malformed','https://[github.com/t27sol/child.git'),
                             ('hostless','https:///t27sol/child.git'),('lookalike-host','https://github.com.evil.invalid/t27sol/child.git'),
                             ('file',str(source)),('relative','../source')]:
                git(parent/'other','remote','set-url','origin',url)
                commit(parent/'other',hooks,f'{label}/{name}', 'keep' if keep else 'strip')
    # Reproduce the original gap using the base commit's actual strip implementation.
    baseline=work/'baseline-bin'
    baseline.mkdir()
    for name in ['fm-git-strip-ai-trailers.sh','fm-git-attribution.py']:
        path=baseline/name
        path.write_text(run('git','show',f'4390df5fa01bf64d80f6ac7f1ae4145b9c67c3c5:bin/{name}'))
        path.chmod(0o700)
    oldhooks=work/'baseline-hooks'
    parent=work/'another-owner-keep-False'
    run(baseline/'fm-git-strip-ai-trailers.sh','install',oldhooks,parent)
    child=parent/'t27sol'
    git(child,'-c',f'core.hooksPath={oldhooks}','commit','-q','--allow-empty','-m','Original submodule gap',
        '--trailer','Co-authored-by: Claude <noreply@anthropic.com>')
    body=git(child,'log','-1','--format=%B')
    assert 'Co-authored-by:' not in body and 'Agent-' not in body
    log.append(f'BASELINE: other-owner launch strip removes attribution inside t27sol submodule\n{body}\n')
    print(f'{len(results)} ordinary Git commits validated; original failure reproduced on base commit.')
    (EVIDENCE/'commit-transcript.txt').write_text('\n'.join(log))
    (EVIDENCE/'commit-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    for directory,_,_ in os.walk(work):
        pathlib.Path(directory).chmod(0o700)
    shutil.rmtree(work)

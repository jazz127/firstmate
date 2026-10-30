import json, os, shutil, subprocess, tempfile
from pathlib import Path
ROOT=Path.cwd()
EVIDENCE=Path('~/.no-mistakes/evidence/01M6798HVS551VQK499W9X9MQQ')
strip=ROOT/'bin/fm-git-strip-ai-trailers.sh'
env=dict(os.environ)
for k in list(env):
    if k.startswith('GIT_') or k in ('CODEX_THREAD_ID','OPENCODE_SESSION_ID'):
        del env[k]
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Attribution Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Attribution Validation',GIT_COMMITTER_EMAIL='validation@example.invalid')
lab=Path(tempfile.mkdtemp(prefix='commits-',dir=ROOT/'.local-test-attribution'))
repo=lab/'repo'
records=[]
def run(*args,check=True,extra=None,input=None):
    p=subprocess.run([str(a) for a in args],cwd=repo if repo.exists() else ROOT,env={**env,**(extra or {})},input=input,text=True,capture_output=True)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.stderr}')
    return p

def install(runtime='codex',model='gpt-6.1-sol',kind='add'):
    hooks=lab/'hooks'
    args=['install']
    if kind=='add': args+=['--attribution',lab/'worker.meta',runtime,model]
    if kind=='keep': args+=['--no-strip']
    run(strip,*args,hooks,repo)
    exports=lab/'env'
    run(strip,'env-file',hooks,exports)
    # Consume the installed, public export file in bash exactly as a worker does.
    return {'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'core.hooksPath','GIT_CONFIG_VALUE_0':str(hooks)}

def commit(label,message,hookenv,amend=False,refuse=False):
    before=run('git','rev-parse','HEAD',check=False).stdout.strip()
    args=['git','commit','--quiet','--allow-empty','-F','-']
    if amend: args+=['--amend']
    p=run(*args,input=message,extra=hookenv,check=False)
    if refuse:
        assert p.returncode!=0 and run('git','rev-parse','HEAD').stdout.strip()==before
        records.append({'scenario':label,'exit':p.returncode,'error':p.stderr.strip(),'HEAD_unchanged':True})
        return
    assert p.returncode==0,p.stderr
    body=run('git','log','-1','--format=%B').stdout
    parsed=run('git','interpret-trailers','--parse',input=body).stdout
    records.append({'scenario':label,'commit':run('git','rev-parse','HEAD').stdout.strip(),'message':body,'git_parsed_trailers':parsed})
    return body,parsed
try:
    run('git','init','-q',repo)
    run('git','remote','add','origin','https://github.com/t27sol/validation.git/')
    sid='11111111-2222-3333-4444-555555555555'
    he=install();he['CODEX_THREAD_ID']=sid
    body,parsed=commit('t27sol default policy adds Codex coauthor, platform and available session','fix: trace worker changes\n\nCo-authored-by: Jane Doe <jane@example.com>\n',he)
    expected='Co-authored-by: Jane Doe <jane@example.com>\nCo-authored-by: codex <noreply@firstmate.invalid>\nAgent-System: fac:firstmate\nAgent-Platform: codex/gpt-6.1-sol\nAgent-Session: '+sid+'\n'
    assert parsed==expected
    _,parsed=commit('amend retains one copy of attribution',body,he,amend=True);assert parsed==expected
    native='fix: native Claude attribution\n\nCo-authored-by: Claude <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_test123\n'
    for model in ('sonnet[1m]','claude-sonnet-4-5@20250929[1m]'):
        he=install('claude',model)
        _,parsed=commit('Claude model omitted: '+model,native,he)
        assert parsed=='Co-authored-by: Claude <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_test123\nAgent-System: fac:firstmate\nAgent-Platform: claude\n'
    for runtime in ('opencode','polytoken'):
        he=install(runtime,'openai/gpt-6.1-sol#high' if runtime=='opencode' else 'default')
        if runtime=='opencode': sid='ses_validation123';he['OPENCODE_SESSION_ID']=sid
        else: sid='validation-session-123';(lab/'worker.meta').write_text('polytoken_session='+sid+'\n')
        _,parsed=commit(runtime+' consumes existing session context','fix: recorded session\n',he)
        assert 'Agent-Session: '+sid+'\n' in parsed
    for selector in ('openai/gpt-6.1-sol#high','vertex/claude-sonnet-4-5@20250929[1m]#high'):
        he=install('opencode',selector)
        _,parsed=commit('OpenCode selector: '+selector,'fix: preserve selector\n',he)
        assert 'Agent-Platform: opencode/'+selector+'\n' in parsed
    for selector in ('model\nAgent-System: injected','model\x01variant','https://private.invalid/model','/private/model','provider/../../private'):
        he=install('opencode',selector)
        commit('reject unsafe model '+repr(selector),'fix: reject unsafe selector\n',he,refuse=True)
    he=install('codex','default')
    examples='fix: document attribution\n\nAgent-Platform: codex/example\nAgent-Session: example\nCo-authored-by: pi <noreply@firstmate.invalid>\nCo-authored-by: Jane Doe <jane@example.com>\nThese are body examples followed by explanatory prose.\n'
    footer='\nSigned-off-by: Jane Doe <jane@example.com>\nCo-authored-by: Claude <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_test123\nCo-authored-by: Jane Doe <jane@example.com>\nAgent-Platform: stale\nAgent-System: stale\nAgent-Session: stale\n'
    run('git','remote','set-url','origin','https://github.com/t27sol-other/validation.git/')
    body,parsed=commit('out-of-owner fallback strips AI and native session, preserves body and human trailers',examples+footer,he)
    assert body.startswith(examples)
    assert parsed=='Signed-off-by: Jane Doe <jane@example.com>\nCo-authored-by: Jane Doe <jane@example.com>\n'
    he=install(kind='keep')
    _,parsed=commit('legacy keep preserves native attribution outside t27sol',native,he)
    assert parsed=='Co-authored-by: Claude <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_test123\n'
    he=install(kind='strip')
    body,parsed=commit('strip selection preserves body examples and human coauthors',examples+footer,he)
    assert body.startswith(examples) and parsed=='Signed-off-by: Jane Doe <jane@example.com>\nCo-authored-by: Jane Doe <jane@example.com>\n'
    for item in records:
        print('\n$ git commit / git log -1 --format=%B / git interpret-trailers --parse')
        print(item['scenario'])
        print(item.get('message',item.get('error')))
        if 'git_parsed_trailers' in item: print('Git parsed trailers:\n'+item['git_parsed_trailers'])
    (EVIDENCE/'commit-results.json').write_text(json.dumps(records,indent=2)+'\n')
finally:
    for current,dirs,files in os.walk(lab):
        os.chmod(current,0o700)
    shutil.rmtree(lab)

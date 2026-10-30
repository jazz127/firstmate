import json, os, pathlib, subprocess
ROOT=pathlib.Path.cwd()
LAB=ROOT/'.test-live/manual'
LAB.mkdir(parents=True,exist_ok=True)
ENV={k:v for k,v in os.environ.items() if not k.startswith(('GIT_', 'CODEX_THREAD_ID', 'OPENCODE_SESSION_ID'))}
ENV.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation User',GIT_AUTHOR_EMAIL='user@example.invalid',GIT_COMMITTER_NAME='Validation User',GIT_COMMITTER_EMAIL='user@example.invalid')
records=[]
def run(args,cwd=ROOT,env=None,check=True,input=None):
 return subprocess.run(list(map(str,args)),cwd=cwd,env=env or ENV,text=True,input=input,capture_output=True,check=check)
def setup(name,runtime,model,origin='https://github.com/t27sol/sample.git',meta=None,strip=False):
 repo=LAB/name; repo.mkdir()
 run(['git','init','-q',repo]); run(['git','remote','add','origin',origin],repo)
 hooks=LAB/(name+'-hooks')
 args=['bash',ROOT/'bin/fm-git-strip-ai-trailers.sh','install']
 if not strip: args+=['--attribution',meta or LAB/'absent.meta',runtime,model]
 run(args+[hooks,repo])
 env={**ENV,'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'core.hooksPath','GIT_CONFIG_VALUE_0':str(hooks)}
 return repo,env
def commit(label,repo,env,message,amend=False,success=True):
 args=['git','commit','-q','--allow-empty','-F','-']
 if amend: args+=['--amend']
 result=run(args,repo,env,check=False,input=message)
 rec={'scenario':label,'exit_code':result.returncode,'stderr':result.stderr}
 if success:
  assert result.returncode==0,rec
  body=run(['git','log','-1','--format=%B'],repo).stdout
  parsed=run(['git','interpret-trailers','--parse'],repo,input=body).stdout.splitlines()
  rec.update(commit=run(['git','rev-parse','HEAD'],repo).stdout.strip(),message=body,parsed_trailers=parsed)
 else:
  assert result.returncode!=0,rec
 records.append(rec)
 return rec
sid='11111111-2222-4333-8444-555555555555'
r,e=setup('codex','codex','gpt-6.1-sol',origin='ssh://git@github.com/t27sol/sample.git/')
e['CODEX_THREAD_ID']=sid
msg='fix: record worker attribution\n\nCo-authored-by: Human <human@example.invalid>\nSigned-off-by: Human <human@example.invalid>\n'
a=commit('Codex commit in t27sol without config',r,e,msg)
assert a['parsed_trailers']==['Co-authored-by: Human <human@example.invalid>','Signed-off-by: Human <human@example.invalid>','Co-authored-by: codex <noreply@firstmate.invalid>','Agent-System: fac:firstmate','Agent-Platform: codex/gpt-6.1-sol',f'Agent-Session: {sid}']
b=commit('Amend remains semantically identical',r,e,a['message'],amend=True)
assert a['parsed_trailers']==b['parsed_trailers']
r,e=setup('claude','claude','sonnet[1m]')
a=commit('Native Claude session remains in native position with no duplicate',r,e,f'fix: preserve native session\n\nCo-authored-by: Claude <noreply@anthropic.com>\nClaude-Session: {sid}\nSigned-off-by: Human <human@example.invalid>\n')
assert a['parsed_trailers']==['Co-authored-by: Claude <noreply@anthropic.com>',f'Claude-Session: {sid}','Signed-off-by: Human <human@example.invalid>','Agent-System: fac:firstmate','Agent-Platform: claude']
meta=LAB/'polytoken.meta'; meta.write_text('polytoken_session=validation-recorded-session\npolytoken_credential=/private/not-publishable\n')
r,e=setup('polytoken','polytoken','zai/glm-5.3-flash',meta=meta)
a=commit('Polytoken uses existing task session record only',r,e,'fix: recorded session\n')
assert 'Agent-Session: validation-recorded-session' in a['parsed_trailers'] and 'credential' not in a['message']
prose='fix: document examples\n\nAgent-System: body-example\nAgent-Platform: codex/body-example\nAgent-Session: body-session\nClaude-Session: body-native-session\nCo-authored-by: pi <noreply@firstmate.invalid>\nThese are ordinary examples followed by prose.\n'
r,e=setup('strip','codex','default',origin='https://github.com/t27sol-other/sample.git/',strip=True)
a=commit('Outside t27sol strips AI and native sessions but preserves body and human',r,e,prose+f'\nCo-authored-by: Claude <noreply@anthropic.com>\nClaude-Session: {sid}\nAgent-System: fac:firstmate\nAgent-Platform: claude\nAgent-Session: {sid}\nCo-authored-by: Human <human@example.invalid>\nSigned-off-by: Human <human@example.invalid>\n')
assert prose in a['message']
assert a['parsed_trailers']==['Co-authored-by: Human <human@example.invalid>','Signed-off-by: Human <human@example.invalid>']
r,e=setup('variant','opencode','openai/gpt-6.1-sol#high')
a=commit('OpenCode variant reaches Git parsed platform',r,e,'fix: variant selector\n')
assert 'Agent-Platform: opencode/openai/gpt-6.1-sol#high' in a['parsed_trailers']
for i,model in enumerate(['bad\nAgent-Session: injected','bad\x01selector','/private/secret','https://private.invalid/model']):
 r,e=setup('unsafe-'+str(i),'opencode',model)
 a=commit('Reject unsafe model '+repr(model),r,e,'fix: unsafe selector\n',success=False)
 assert 'unsafe model' in a['stderr']
 assert run(['git','rev-parse','--verify','HEAD'],r,check=False).returncode!=0
out=pathlib.Path('~/.no-mistakes/evidence/01M6798HVS551VQK499W9X9MQQ/commit-objects.json')
out.write_text(json.dumps({'driver':'installed commit-msg hooks via git commit; git interpret-trailers --parse','oracle':'AGT-006 and recorded operator decisions; no forge or model-service calls required','records':records},indent=2)+'\n')
print(out)

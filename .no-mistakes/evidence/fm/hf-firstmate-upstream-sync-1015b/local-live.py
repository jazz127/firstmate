import pathlib,subprocess,os,json,shlex
root=pathlib.Path.cwd();tmp=root/'.validation-tmp/local';tmp.mkdir();ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4YFDQR9GTFBYVCE7QQNKRPE');log=open(ev/'local-cli-transcript.log','w');env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('GIT_') or k in ['NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(k,None)
env.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='fixture@example.invalid')
def run(args,extra=None,expected=0):
 e=env.copy();e.update(extra or {});p=subprocess.run(args,env=e,text=True,capture_output=True);log.write('$ '+shlex.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n');log.flush();assert p.returncode==expected,(args,p.returncode,p.stdout,p.stderr);return p.stdout
repo=tmp/'house';home=tmp/'home';home.mkdir();(home/'config').mkdir();(home/'state').mkdir();(home/'data').mkdir()
run(['git','init','-q',str(repo)]);run(['git','-C',str(repo),'commit','-q','--allow-empty','-m','fixture']);run(['git','-C',str(repo),'remote','add','origin','https://github.com/jazz127/firstmate.git']);run(['git','-C',str(repo),'remote','add','upstream','https://github.com/kunchenguid/firstmate.git'])
ctx={'FM_HOME':str(home),'FM_ROOT_OVERRIDE':str(repo)}
run(['bin/fm-role.sh','report'],ctx)
run(['bin/fm-role.sh','check',str(repo)],ctx,1)
run(['bin/fm-role.sh','check',str(repo),'upstream-consent','github.com/kunchenguid/firstmate'],ctx,1)
run(['bin/fm-role.sh','check',str(repo),'upstream-consent','github.com/jazz127/firstmate'],ctx)
assert not (home/'config/firstmate-role').exists()
(home/'config/firstmate-role').write_text('maintainer github.com/jazz127/firstmate\n');run(['bin/fm-role.sh','check',str(repo)],ctx)
(home/'config/firstmate-role').write_text('maintainer github.com/kunchenguid/firstmate\n');run(['bin/fm-role.sh','check',str(repo)],ctx,1)
# Scaffold is intentional generated output; the delivered Forgejo command was driven separately against the real service.
ctx={'FM_HOME':str(home)}
brief=run(['bin/fm-brief.sh','generated-fj','fixture-repo','--mode','no-mistakes','--forge','forgejo'],ctx);(ev/'forgejo-generated-brief.md').write_text((home/'data/generated-fj/brief.md').read_text())
# Git's real commit consumer must retain inherited config for the project's pre-commit and strip only the AI trailer.
hooks=tmp/'hooks';run(['bin/fm-git-strip-ai-trailers.sh','install',str(hooks),str(repo)])
pre=repo/'.git/hooks/pre-commit';pre.write_text('#!/bin/bash\ngit config --get-all credential.helper > '+shlex.quote(str(tmp/'inherited-config'))+'\n');pre.chmod(0o700)
config={'GIT_CONFIG_COUNT':'3','GIT_CONFIG_KEY_0':'credential.helper','GIT_CONFIG_VALUE_0':'','GIT_CONFIG_KEY_1':'credential.helper','GIT_CONFIG_VALUE_1':'!fixture-helper-not-executed','GIT_CONFIG_KEY_2':'core.hooksPath','GIT_CONFIG_VALUE_2':str(hooks)}
run(['git','-C',str(repo),'commit','-q','--allow-empty','-m','Preserve inherited Git configuration','--trailer','Co-authored-by: Cursor <cursoragent@cursor.com>','--trailer','Co-authored-by: Human <human@example.invalid>'],config)
body=run(['git','-C',str(repo),'log','-1','--format=%B']);assert 'cursoragent' not in body and 'Human <human@example.invalid>' in body
assert (tmp/'inherited-config').read_text()=='\n!fixture-helper-not-executed\n';log.write('Actual repository pre-commit observed inherited credential.helper values: '+repr((tmp/'inherited-config').read_text())+'\n')
log.close()

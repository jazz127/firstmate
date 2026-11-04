import os, subprocess, json, shlex
from pathlib import Path
root=Path.cwd(); evidence=Path('~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV'); scratch=root/'.phase-tmp'/'cli-world';scratch.mkdir()
env=os.environ.copy()
for key in list(env):
 if key.startswith('FM_') or key.startswith('HERDR_') or key.startswith('TASKS_AXI_'):env.pop(key)
env.update(GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='validation@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='validation@example.invalid',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
log=(evidence/'cli-live.log').open('w')
def run(args,extra=None,ok=(0,),show=True):
 e=env.copy();e.update(extra or {})
 p=subprocess.run(list(map(str,args)),cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if show:log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit: '+str(p.returncode)+'\n');log.flush()
 if p.returncode not in ok:raise RuntimeError(f'{args}: {p.returncode}: {p.stdout}')
 return p
results=[]
home=scratch/'home';run(['bin/fm-lab-home.sh','create',home]);isolated={'FM_HOME':str(home),'FM_ROOT_OVERRIDE':str(root),'TMUX':str(home/'absent.sock')+',0,0'}
state=home/'state'
g1=run(['bin/fm-busy-event.sh','arm',state,'worker']).stdout.strip()
run(['bin/fm-busy-event.sh','apply',state,'worker','idle','--gen',g1,'--source','live-driver','--event','turn-end','--turn-ended'])
assert (state/'worker.turn-ended').exists()
g2=run(['bin/fm-busy-event.sh','arm',state,'worker']).stdout.strip();before=(state/'worker.busy-state').read_bytes(); (state/'worker.turn-ended').unlink(missing_ok=True)
run(['bin/fm-busy-event.sh','apply',state,'worker','idle','--gen',g1,'--source','late-hook','--event','turn-end','--turn-ended'],ok=(1,))
assert before==(state/'worker.busy-state').read_bytes() and not (state/'worker.turn-ended').exists()
log.write('replacement record after rejected stale event:\n'+(state/'worker.busy-state').read_text()+'\n')
results.append({'scenario':'generation-safe busy events','result':'pass'})
(state/'t1.meta').write_text('window=unavailable:fm-t1\nbackend=tmux\nharness=codex\nkind=ship\n')
(state/'t1.status').write_text('needs-decision [key=api-shape]: choose REST or RPC\nworking: another stream\n')
r=run(['bin/fm-send.sh','t1','--resolve-key','wrong-key','Choose REST & retain this exact message'],isolated,ok=(1,2,3,75))
assert any(shlex.split(line)[-1]=='Choose REST & retain this exact message' for line in r.stdout.splitlines() if line.strip().startswith('FM_HOME=')) and not list((state/'t1.inbox').glob('*.msg'))
r=run(['bin/fm-send.sh','t1','--resolve-key','api-shape','Choose REST & retain this exact message'],isolated)
records=list((state/'t1.inbox').glob('*.msg'));assert len(records)==1 and 'Choose REST & retain this exact message' in records[0].read_text()
log.write('persisted inbox contract:\n'+records[0].read_text()+'\nresolved status contract:\n'+(state/'t1.status').read_text()+'\n')
assert 'resolved' in (state/'t1.status').read_text()
results.append({'scenario':'decision refusal preserves answer and durable delivery closes correct key','result':'pass'})
for command in [f'cd "{root}"',f'cd "{scratch}"',f'(cd "{scratch}" && pwd)']:
 run(['node','bin/fm-cd-command-policy.mjs','--home',root,'--command',command])
run(['bin/fm-pr-merge.sh','--help'],isolated)
results.append({'scenario':'home cd policy and PR merge help','result':'pass'})
origin=scratch/'origin.git';seed=scratch/'seed';live=scratch/'running';upstream=scratch/'upstream.git'
run(['git','init','--bare','--initial-branch=house',origin],show=False)
run(['git','init','--bare','--initial-branch=rolling',upstream],show=False)
run(['git','init','-b','house',seed],show=False);(seed/'README.md').write_text('version one\n')
run(['git','-C',seed,'add','README.md'],show=False);run(['git','-C',seed,'commit','-m','base'],show=False)
run(['git','-C',seed,'remote','add','origin',origin],show=False);run(['git','-C',seed,'push','origin','house'],show=False)
run(['git','clone',origin,live],show=False);run(['git','-C',live,'remote','add','upstream',upstream],show=False)
(seed/'README.md').write_text('version two from configured upstream\n');run(['git','-C',seed,'commit','-am','second'],show=False);run(['git','-C',seed,'push',upstream,'HEAD:rolling'],show=False)
(home/'config'/'self-update-source').write_text('upstream rolling\n');updateenv={'FM_HOME':str(home),'FM_ROOT_OVERRIDE':str(live),'TMUX':str(home/'absent.sock')+',0,0'}
# Retire the delivery fixture before checking the independent update scenario.
(state/'t1.meta').unlink();run(['bin/fm-update.sh'],updateenv)
assert (live/'README.md').read_text()=='version two from configured upstream\n'
head=run(['git','-C',live,'rev-parse','HEAD']).stdout
(seed/'README.md').write_text('version three\n');run(['git','-C',seed,'commit','-am','third'],show=False);run(['git','-C',seed,'push',upstream,'HEAD:rolling'],show=False)
(live/'README.md').write_text('uncommitted operator work\n');run(['bin/fm-update.sh'],updateenv)
assert (live/'README.md').read_text()=='uncommitted operator work\n' and run(['git','-C',live,'rev-parse','HEAD']).stdout==head
(home/'config'/'self-update-source').write_text('unknown rolling\n');run(['bin/fm-update.sh'],updateenv,ok=(1,))
assert run(['git','-C',live,'rev-parse','HEAD']).stdout==head
log.write('preserved dirty file:\n'+(live/'README.md').read_text());log.close()
results.append({'scenario':'configured self-update fast-forwards and preserves dirty work; invalid source refuses','result':'pass'})
(evidence/'cli-live-results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results))

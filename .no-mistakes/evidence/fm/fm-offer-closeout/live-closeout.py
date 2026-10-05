from pathlib import Path
import os, subprocess, tempfile, json, shutil, datetime
ROOT=Path.cwd()
EV=Path('/Users/jarad/.no-mistakes/evidence/01M46XS3FHE09Z71KNW1MME0W5')
BASE={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TREEHOUSE_ROOT','TREEHOUSE_WORKTREE_PATH'))}
BASE.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1')
LAB=Path(tempfile.mkdtemp(prefix='.live-closeout-',dir=ROOT))
ENV={**BASE,'FM_HOME':str(LAB),'TREEHOUSE_ROOT':str(LAB/'pool')}
LOG=(EV/'live-closeout.log').open('w',buffering=1)
def say(s):
 print(s,flush=True); LOG.write(s+'\n')
def run(args,env=ENV,cwd=ROOT,ok=True,show=True):
 say('$ '+ ' '.join(str(a) for a in args))
 p=subprocess.run([str(a) for a in args],env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 if show: say(p.stdout.rstrip() or '(no output)')
 if ok and p.returncode: raise RuntimeError('command exit '+str(p.returncode))
 return p
URL='https://github.com/kunchenguid/quota-axi/pull/292'
def poll(label,clock=None):
 say('SCENARIO: '+label)
 env=ENV.copy()
 if clock: env['FM_CONTRIBUTIONS_NOW']=clock
 p=run([ROOT/'bin/fm-contributions.sh','poll'],env=env)
 rec=json.loads((LAB/'data/offer/contributions.json').read_text())['records'][0]
 summary={k:rec.get(k) for k in ['url','checked_at','error','closeout_head','closeout_since','closeout_notice']}
 o=rec.get('observation') or {}
 summary.update(permission=o.get('viewer_permission'),state=o.get('state'),checks=o.get('checks'),absent_checks=o.get('absent_checks'),pending=[{'token':e['token'],'source':e['source'],'type':e['type']} for e in rec.get('pending',[])])
 say(json.dumps(summary,indent=2)); return p,rec
def ack_all(rec):
 for e in rec.get('pending',[]): run([ROOT/'bin/fm-contributions.sh','ack','offer',URL,e['token']])
try:
 run([ROOT/'bin/fm-lab-home.sh','create',LAB])
 (LAB/'data/backlog.md').write_text('# Backlog\n\n## Queued\n- [ ] offer - disposable offer validation (repo: quota-axi) (kind: ship)\n')
 (LAB/'data/projects.md').write_text('- quota-axi [no-mistakes] - Registered third-party clone (added 2026-10-06)\n')
 PROJ=LAB/'projects/quota-axi'
 run(['git','clone','--quiet','--depth','1','https://github.com/kunchenguid/quota-axi.git',PROJ])
 run(['git','-C',PROJ,'fetch','--quiet','--depth','1','origin','refs/pull/292/head:refs/remotes/fork/offer'])
 run(['git','-C',PROJ,'branch','offer','refs/remotes/fork/offer'])
 wt=Path(run(['treehouse','get','--lease','--no-fetch','--base','offer','--branch','fm-lab-offer'],cwd=PROJ).stdout.strip().splitlines()[-1])
 assert wt.is_relative_to(LAB)
 (LAB/'state/offer.meta').write_text('worktree='+str(wt)+'\nproject='+str(PROJ)+'\nkind=ship\nmode=no-mistakes\nbackend=tmux\n')
 (LAB/'state/offer.meta').chmod(0o600)
 run([ROOT/'bin/fm-pr-check.sh','offer',URL])
 p,rec=poll('real outside PR and initial feedback discovery')
 assert rec['error'] is None and rec['observation']['viewer_permission']=='READ'
 ack_all(rec)
 since=datetime.datetime.fromisoformat(rec['closeout_since'].replace('Z','+00:00'))
 clock=lambda n:(since+datetime.timedelta(seconds=n)).strftime('%Y-%m-%dT%H:%M:%SZ')
 p,rec=poll('default two-hour window holds at 1h59m59s',clock(7199)); assert 'contributions closeout' not in p.stdout and rec.get('closeout_notice') is None
 p,rec=poll('default two-hour window expires at exactly two hours',clock(7200)); assert 'state=ready' in p.stdout
 p,rec=poll('unchanged closeout does not repeat wake',clock(7201)); assert 'contributions closeout' not in p.stdout
 (LAB/'config/outside-pr-review-window-hours').write_text('4\n')
 p,rec=poll('configured four-hour window holds at two hours',clock(7200)); assert 'contributions closeout' not in p.stdout and rec.get('closeout_notice') is None
 p,rec=poll('configured four-hour window expires',clock(14400)); assert 'state=ready' in p.stdout
 (LAB/'config/outside-pr-review-window-hours').write_text('two\n')
 p,rec=poll('invalid configuration disables closeout'); assert 'invalid config/' in p.stdout and 'contributions closeout' not in p.stdout
 p,rec=poll('invalid configuration reports only once'); assert 'invalid config/' not in p.stdout
 (LAB/'config/outside-pr-review-window-hours').write_text('0\n')
 # Clear an earlier ready notice by holding again; zero then represents a new condition episode.
 (LAB/'config/outside-pr-review-window-hours').write_text('87600\n'); poll('long window holds existing offer')
 (LAB/'config/outside-pr-review-window-hours').write_text('0\n')
 p,rec=poll('zero-hour window immediately releases acknowledged green offer'); assert 'state=ready' in p.stdout
 dirty=wt/'live-uncommitted.txt'; dirty.write_text('Disposable uncommitted work\n')
 p,rec=poll('untracked changes hold expired offer'); assert 'state=workspace' in p.stdout
 p=run([ROOT/'bin/fm-teardown.sh','offer'],ok=False); assert p.returncode!=0 and (LAB/'state/offer.meta').exists() and dirty.exists()
 dirty.unlink()
 (wt/'unpushed-validation.txt').write_text('Disposable unpushed change\n')
 run(['git','-C',wt,'add','unpushed-validation.txt'])
 run(['git','-C',wt,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-m','Disposable unpushed validation commit'])
 p=run([ROOT/'bin/fm-teardown.sh','offer'],ok=False); assert p.returncode!=0 and (LAB/'state/offer.meta').exists()
 run(['git','-C',wt,'reset','--hard','refs/remotes/fork/offer'])
 p,rec=poll('clean pushed offer returns to ready'); assert 'state=ready' in p.stdout
 # Ensure the teardown global orphan sweep has no outside candidate.
 probe=run([ROOT/'bin/fm-remote-job-reap-orphans.sh','--dry-run'])
 assert not probe.stdout.strip(), 'global sweep candidates would violate isolated test boundary'
 p=run([ROOT/'bin/fm-teardown.sh','offer']); assert 'teardown offer complete' in p.stdout and not (LAB/'state/offer.meta').exists()
 assert (LAB/'data/offer/contributions.json').exists()
 say('Persisted backlog after guarded teardown:')
 say((LAB/'data/backlog.md').read_text())
 # Rediscover current real feedback on a retired task from its durable PR link.
 saved=json.loads((LAB/'data/offer/contributions.json').read_text())
 saved['records'][0]['seen']=[]; saved['records'][0]['notified']=[]; saved['records'][0]['pending']=[]
 (LAB/'data/offer/contributions.json').write_text(json.dumps(saved))
 p,rec=poll('retired task still observes real maintainer feedback'); assert rec['error'] is None and len(rec['pending'])>0 and 'contributions closeout' not in p.stdout
 say('PASS: all driven outside-offer observer and guarded teardown scenarios')
finally:
 shutil.rmtree(LAB)
 say('Disposable local home, clone and Treehouse pool removed.')
 LOG.close()

from pathlib import Path
import os, subprocess, tempfile, json, shutil
ROOT=Path.cwd(); EV=Path('/Users/jarad/.no-mistakes/evidence/01M46XS3FHE09Z71KNW1MME0W5')
BASE={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'))}
BASE.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1')
LAB=Path(tempfile.mkdtemp(prefix='.live-boundaries-',dir=ROOT)); LOG=(EV/'round2-live-boundaries.log').open('w',buffering=1)
def say(s): print(s,flush=True); LOG.write(s+'\n')
def run(args,env,cwd=ROOT):
 say('$ '+' '.join(str(a) for a in args))
 p=subprocess.run([str(a) for a in args],env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=50)
 say(p.stdout.rstrip() or '(no output)')
 assert p.returncode==0, p.returncode
 return p
try:
 for label,url,expected in [
  ('owned repository remains merge-based','https://github.com/jazz127/firstmate/pull/23',None),
  ('red CI holds expired outside offer','https://github.com/kunchenguid/quota-axi/pull/295','ci'),
  ('write scope keeps upstream-named project merge-based','https://github.com/sthi-1005/fm-quarterdeck/pull/12',None),
  ('no CI verdict holds expired outside offer','https://github.com/octocat/Hello-World/pull/11462','ci'),
  ('supported metadata tails permit closeout','https://github.com/kunchenguid/quota-axi/pull/297','ready'),
  ('stale retained PR cannot close out replacement','https://github.com/kunchenguid/quota-axi/pull/297',None),
  ('failed authenticated forge read refuses closeout','https://github.com/kunchenguid/quota-axi/pull/297','unavailable')]:
  home=LAB/str(len(list(LAB.iterdir()))); env={**BASE,'FM_HOME':str(home)}
  run([ROOT/'bin/fm-lab-home.sh','create',home],env)
  wt=home/'projects/local-checkout'; wt.mkdir()
  run(['git','init','--quiet',wt],env)
  run(['git','-C',wt,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','--quiet','-m','Disposable local state'],env)
  (home/'config/outside-pr-review-window-hours').write_text('0\n')
  (home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n- [ ] offer - isolated boundary '+url+' (repo: local-checkout) (kind: ship)\n')
  current='https://github.com/kunchenguid/quota-axi/pull/292' if label.startswith('stale') else url
  (home/'state/offer.meta').write_text('worktree='+str(wt)+'\nproject='+str(wt)+'\nkind=ship\npr='+current+'\ncontrol_relaunch_tx=lab-relaunch\ntraceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n')
  (home/'state/offer.meta').chmod(0o600)
  if expected=='unavailable': env['GH_TOKEN']='invalid-disposable-live-validation-token'
  say('SCENARIO: '+label)
  p=run([ROOT/'bin/fm-contributions.sh','poll'],env)
  records=json.loads((home/'data/offer/contributions.json').read_text())['records']
  rec=next(r for r in records if r['url']==url)
  # Acknowledge genuine maintainer feedback only in disposable observer state.
  if expected not in ('unavailable',None):
   for e in rec.get('pending',[]): run([ROOT/'bin/fm-contributions.sh','ack','offer',url,e['token']],env)
   p=run([ROOT/'bin/fm-contributions.sh','poll'],env)
   rec=next(r for r in json.loads((home/'data/offer/contributions.json').read_text())['records'] if r['url']==url)
  o=rec.get('observation') or {}
  say(json.dumps({'url':url,'error':rec.get('error'),'permission':o.get('viewer_permission'),'checks':o.get('checks'),'closeout_notice':rec.get('closeout_notice'),'metadata_retained':(home/'state/offer.meta').exists()},indent=2))
  assert (home/'state/offer.meta').exists()
  if expected=='unavailable':
   assert rec['error'] is not None and 'observation unavailable' in p.stdout and 'contributions closeout' not in p.stdout
   p=run([ROOT/'bin/fm-contributions.sh','poll'],env); assert 'observation unavailable' not in p.stdout
  elif expected is None:
   assert rec['error'] is None and rec.get('closeout_notice') is None
   if label.startswith('owned'): assert o['viewer_permission']=='ADMIN'
   if label.startswith('stale'): assert not any(url+' head=' in line and 'contributions closeout' in line for line in p.stdout.splitlines())
  else:
   assert rec['error'] is None and rec['closeout_notice'].endswith(':'+expected)
  say('PASS: '+label)
finally:
 shutil.rmtree(LAB); say('All disposable boundary homes and local repositories removed.'); LOG.close()

from pathlib import Path
import os, subprocess, tempfile, json, shutil, datetime
ROOT=Path.cwd()
EV=Path('/Users/jarad/.no-mistakes/evidence/01M46XS3FHE09Z71KNW1MME0W5')
BASE={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TREEHOUSE_ROOT','TREEHOUSE_WORKTREE_PATH'))}
BASE.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1')
LAB=ROOT/'.p'
assert not LAB.exists()
LAB.mkdir()
ENV={**BASE,'FM_HOME':str(LAB),'TREEHOUSE_ROOT':str(LAB/'pool')}
LOG=(EV/'live-primary.log').open('w',buffering=1)
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
 (LAB/'config/outside-pr-review-window-hours').write_text('0\n')
 p,rec=poll('prepare actual ready closeout wake for primary')
 ack_all(rec)
 p,rec=poll('ready wake after real feedback acknowledgement')
 assert 'state=ready' in p.stdout
 # The primary must have a real non-zero terminal grid and its own socket.
 (LAB/'tmux').mkdir()
 tenv=ENV.copy(); tenv['TMUX_TMPDIR']=str(LAB/'tmux')
 for name in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
  tenv.pop(name,None)
 run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(LAB),'codex','--disable','hooks'],env=tenv)
 import time
 time.sleep(3)
 p=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],env=tenv)
 prompt='This is an isolated live validation primary with FM_HOME='+str(LAB)+'. Source and task data writes must stay inside this worktree and this marked lab home. Do not change any global config, credentials, or real fleet. Do not merge, push, comment on GitHub, delegate, or invoke pipeline control. There is a real contributions closeout offer wake in this lab state/.wake-queue for '+URL+'. Read the ship-landing skill and handle the ready wake under its normal checks and guarded teardown contract; report the observed outcome. Do not perform other fleet startup or recovery work. The lab has a real clone and private Treehouse pool; lifecycle scripts must use this FM_HOME and TREEHOUSE_ROOT from your environment. Stop after this one scenario.'
 if 'Do you trust' in p.stdout or 'Sign in' in p.stdout or 'Login' in p.stdout or 'Hooks need review' in p.stdout:
  say('PRIMARY BLOCKER: trust/login/hook dialog; cannot change user-level settings or credentials in this phase.')
 else:
  run(['tmux','-L','fm-lab','send-keys','-t','primary','-l',prompt],env=tenv)
  run(['tmux','-L','fm-lab','send-keys','-t','primary','Enter'],env=tenv)
  time.sleep(1.5)
  run(['tmux','-L','fm-lab','send-keys','-t','primary','Enter'],env=tenv)
  for i in range(36):
   time.sleep(5)
   p=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],env=tenv)
   if not (LAB/'state/offer.meta').exists():
    say('PASS: real primary removed task metadata after processing ready closeout.')
    say((LAB/'data/backlog.md').read_text())
    time.sleep(3)
    run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary','-S','-150'],env=tenv)
    break
  else:
   say('PRIMARY BLOCKER: no closeout completed within the observed window; see pane transcript.')
finally:
 if (LAB/'tmux').exists():
  subprocess.run(['tmux','-L','fm-lab','kill-server'],env={**BASE,'TMUX_TMPDIR':str(LAB/'tmux')},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 shutil.rmtree(LAB)
 say('Private lab tmux server stopped; disposable primary home, clone and pool removed.')
 LOG.close()

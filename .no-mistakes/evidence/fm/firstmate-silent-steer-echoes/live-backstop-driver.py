import os, pathlib, subprocess, json, tempfile, shutil
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M430Z5J1AEWBPWVCK94A26ET')
env=os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TEST_HARNESS','FM_SUPERVISION_ACTOR','FM_BRANCH_REPORT_TURN']:
 env.pop(key,None)
log=[]
for mode in ['drain','silent-append','visible-append']:
 lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.validation-temp'))
 try:
  subprocess.run([root/'bin/fm-lab-home.sh','create',lab],check=True,capture_output=True)
  state=lab/'state'; (lab/'config/supervision-host-off').touch(); env['FM_HOME']=str(lab)
  def cli(script,*args,check=True):
   return subprocess.run([str(root/'bin'/script),*args],env=env,text=True,capture_output=True,check=check)
  def append(task,verdict,summary,silent=False):
   return cli('fm-branch-outcome.sh','append','--task',task,'--verdict',verdict,'--summary',summary,'--silent',str(silent).lower())
  (state/'visible.status').write_text('done: visible completion already delivered\n')
  (state/'mixed.status').write_text('done: earlier mixed completion delivered\n')
  append('visible','captain','Visible completion handled')
  append('mixed','captain','Earlier mixed completion handled')
  with (state/'mixed.status').open('a') as f: f.write('failed: later failure only echoed silently\n')
  (state/'silent-done.status').write_text('done: completion only echoed silently\n')
  (state/'silent-failed.status').write_text('failed: failure only echoed silently\n')
  for task in ['mixed','silent-done','silent-failed']: append(task,'routine','Unchanged status echo',True)
  before=(state/'branch-outcomes.jsonl').read_text()
  rows=[json.loads(x) for x in before.splitlines()]
  for row in rows:
   (state/f".{row['task']}.branch-outcome-index").write_text(f"fm-branch-outcome-index-v1\t{row['seq']}\t{row['statusEndpoint']}\t{row['statusIdent']}\n")
  (state/'.branch-outcome-index-ready').write_text('5\n')
  cli('fm-branch-outcome.sh','mark-read','--through','5')
  log.append(f'Upgrade path: {mode}\nExisting readiness: 5\nExisting index rows include silent-only done/failed statuses.\n')
  if mode != 'drain': append('fleet','routine','Fleet unchanged' if mode=='silent-append' else 'Unrelated visible result',mode=='silent-append')
  first=cli('fm-wake-drain.sh').stdout
  log.append('$ bin/fm-wake-drain.sh\n'+first)
  for line in ['silent-done done: completion only echoed silently','silent-failed failed: failure only echoed silently','mixed failed: later failure only echoed silently']: assert line in first, (mode,line,first)
  assert 'visible done:' not in first
  assert not (state/'.silent-done.branch-outcome-index').exists()
  assert not (state/'.silent-failed.branch-outcome-index').exists()
  mixed=(state/'.mixed.branch-outcome-index').read_text(); assert mixed.split('\t')[1]=='2'
  ready=(state/'.branch-outcome-index-ready').read_text().strip(); assert ready==f'visible-only-v1:{5 if mode=="drain" else 6}'
  assert (state/'branch-outcomes.jsonl').read_text().startswith(before)
  second=cli('fm-wake-drain.sh').stdout; assert second==''
  assert (state/'.branch-outcome-index-ready').read_text().strip()==ready
  log.append(f'Persisted readiness: {ready}\nMixed coverage restored to visible sequence: {mixed}Second main drain: {len(second.encode())} output bytes\nPrior append-only outcome rows unchanged.\n')
  bad=append('adversary','captain','Captain verdict must render',True) if False else cli('fm-branch-outcome.sh','append','--task','adversary','--verdict','captain','--summary','Captain verdict must render','--silent','true',check=False)
  assert bad.returncode!=0
  assert not any(json.loads(x)['task']=='adversary' for x in (state/'branch-outcomes.jsonl').read_text().splitlines())
  log.append('$ bin/fm-branch-outcome.sh append --task adversary --verdict captain --summary "Captain verdict must render" --silent true\n'+bad.stdout+bad.stderr+f'Exit status: {bad.returncode}; no adversarial row persisted.\n')
 finally: shutil.rmtree(lab)
(ev/'live-upgrade-backstop.txt').write_text('\n'.join(log))
print('Live upgrade recovery and silent-captain refusal verified through actual product CLIs in three disposed lab homes.')

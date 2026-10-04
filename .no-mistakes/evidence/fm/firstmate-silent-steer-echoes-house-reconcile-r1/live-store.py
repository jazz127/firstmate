import os, json, subprocess, pathlib, shutil
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q')
log=[]
def run(home,cmd,ok=True):
 env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
 env.update(FM_HOME=str(home),TMPDIR=str(root/'.gate-test-tmp'))
 p=subprocess.run(cmd,cwd=root,env=env,text=True,capture_output=True,timeout=45)
 log.append('$ '+' '.join(cmd)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
 if ok: assert p.returncode==0,p.stderr
 return p
try:
 for mode in ['append','rebuild','upgrade-drain','upgrade-append']:
  home=root/'.gate-test-tmp'/('live-'+mode)
  run(home,['bin/fm-lab-home.sh','create',str(home)])
  (home/'config/supervision-host-off').touch()
  state=home/'state'
  def append(task,summary,silent=False):
   return run(home,['bin/fm-branch-outcome.sh','append','--task',task,'--verdict','routine','--summary',summary,'--silent',str(silent).lower()])
  (state/'raced.status').write_text('working: building the fix\n')
  append('raced','Earlier progress reviewed')
  index=(state/'.raced.branch-outcome-index').read_bytes()
  with (state/'raced.status').open('a') as f:f.write('done: The fix completed before the unchanged pause report\n')
  (state/'silent-only.status').write_text('failed: The worker failed before the unchanged hold report\n')
  append('raced','The registered pause is unchanged',True)
  append('silent-only','The captain hold remains unchanged',True)
  assert (state/'.raced.branch-outcome-index').read_bytes()==index
  assert not (state/'.silent-only.branch-outcome-index').exists()
  (state/'covered.status').write_text('done: Previously handled completion\n')
  append('covered','The completion is already handled')
  rows=[json.loads(x) for x in run(home,['bin/fm-branch-outcome.sh','list','--recent','10']).stdout.splitlines()]
  if mode!='append':
   for row in rows:
    if row['silent']:
     (state/('.'+row['task']+'.branch-outcome-index')).write_text('\t'.join(map(str,['fm-branch-outcome-index-v1',row['seq'],row['statusEndpoint'],row['statusIdent']]))+'\n')
   if mode=='rebuild':run(home,['bin/fm-branch-outcome.sh','processed-init'])
   else:
    (state/'.branch-outcome-index-visible-only').unlink()
    if mode=='upgrade-append':append('unrelated','Another task progressed')
  output=run(home,['bin/fm-wake-drain.sh']).stdout
  assert 'raced done: The fix completed before the unchanged pause report' in output,output
  assert 'silent-only failed: The worker failed before the unchanged hold report' in output,output
  assert 'covered done:' not in output,output
  assert (state/'.raced.branch-outcome-index').read_bytes()==index
  assert not (state/'.silent-only.branch-outcome-index').exists()
  second=run(home,['bin/fm-wake-drain.sh']).stdout
  assert 'STATUS OUTCOME BACKSTOP (' not in second,second
  before=(state/'branch-outcomes.jsonl').read_bytes()
  p=run(home,['bin/fm-branch-outcome.sh','append','--task','guard','--verdict','captain','--summary','A new failure needs attention','--silent','true'],False)
  assert p.returncode!=0
  assert (state/'branch-outcomes.jsonl').read_bytes()==before
  log.append('Verified '+mode+': completion and failure surfaced exactly once; visible coverage preserved; silent captain outcome rejected.\n')
  shutil.copyfile(state/'branch-outcomes.jsonl',evidence/('live-'+mode+'-outcomes.jsonl'))
  shutil.rmtree(home)
finally:
 (evidence/'live-store-and-drain.txt').write_text('\n'.join(log))
 for home in (root/'.gate-test-tmp').glob('live-*'):
  if home.is_dir():shutil.rmtree(home)
print('Live outcome-store and drain scenarios completed.')

import pathlib, tempfile, subprocess, os, shutil, json
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M430Z5J1AEWBPWVCK94A26ET')
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.validation-temp'))
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TEST_HARNESS','FM_SUPERVISION_ACTOR','FM_BRANCH_REPORT_TURN']: env.pop(k,None)
env['FM_HOME']=str(lab)
try:
 subprocess.run([root/'bin/fm-lab-home.sh','create',lab],check=True,capture_output=True)
 (lab/'state/task-replay.status').write_text('paused: deployment window\n')
 def cli(*a): return subprocess.run([root/'bin/fm-branch-outcome.sh',*a],env=env,text=True,capture_output=True,check=True).stdout
 for summary in ['Pause record echoed','Scheduled pause recheck unchanged','Declared pause still holds']:
  cli('append','--task','task-replay','--verdict','routine','--summary',summary,'--silent','true')
 assert not (lab/'state/.task-replay.branch-outcome-index').exists()
 cli('append','--task','task-replay','--verdict','routine','--summary','Pause cleared and worker resumed')
 index=(lab/'state/.task-replay.branch-outcome-index').read_text()
 cli('append','--task','task-replay','--verdict','routine','--summary','Existing working status echoed','--silent','true')
 assert (lab/'state/.task-replay.branch-outcome-index').read_text()==index
 before=(lab/'state/branch-outcomes.jsonl').read_text()
 first=cli('startup-replay'); assert 'Pause cleared and worker resumed' in first
 for text in ['Pause record echoed','Scheduled pause recheck unchanged','Declared pause still holds','Existing working status echoed']: assert text not in first
 assert (lab/'state/.branch-outcomes-cursor').read_text().strip()=='5'
 assert cli('unread')==''
 second=cli('startup-replay'); assert second==''
 assert (lab/'state/branch-outcomes.jsonl').read_text()==before
 cli('processed-init'); assert (lab/'state/.task-replay.branch-outcome-index').read_text()==index
 (ev/'live-startup-replay.txt').write_text('Persisted outcome rows before replay:\n'+before+'\n$ bin/fm-branch-outcome.sh startup-replay\n'+first+'\nPersisted read cursor: 5\nSecond startup replay: 0 output bytes\nAppend-only rows unchanged; status coverage remains visible sequence 4 after a later silent row and processed-init.\n')
 print('Live startup replay preserves silence, visible delivery, cursor advancement and visible-only coverage.')
finally: shutil.rmtree(lab)

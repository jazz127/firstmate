import pathlib,subprocess,os,time,json,shlex
r=pathlib.Path.cwd(); h=r/'.lab/h'; e=pathlib.Path('<operator-home>/.no-mistakes/evidence/01M4SDKM6WTX0CEK2C5DQ3RE1K'); env=os.environ.copy()
for k in list(env):
    if k=='FM_GATE_REFUSE_BYPASS' or k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k,None)
env.update(FM_HOME=str(h),FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',TMUX_TMPDIR='.lab/h/tmux',TMPDIR=str(r/'.test-tmp'),TREEHOUSE_ROOT=str(h/'projects/pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
socket=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env,text=True).strip(); env['TMUX']=socket+',501,0'
log=[]; result={}; id='test-raw-'+str(os.getpid())
def run(args,timeout=90):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout); log.append('$ '+shlex.join(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n'); return p
try:
    run(['tmux','-L','fm-lab','set-environment','-g','TREEHOUSE_ROOT',str(h/'projects/pool')])
    run(['tmux','-L','fm-lab','set-environment','-g','TMPDIR',str(r/'.test-tmp')])
    (h/'config/crew-harness').write_text('codex\n')
    run([str(r/'bin/fm-brief.sh'),id,'demo','--scout'])
    b=h/'data'/id/'brief.md'; b.write_text(b.read_text().replace('{TASK}','Run a disposable raw process to verify spend admission.').replace('{FIRSTMATE_SPEC}','Do not edit any source.'))
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    run(['tasks-axi','add',id,'Run a disposable raw process','--file',str(h/'data/backlog.md')])
    run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'])
    p=run([str(r/'bin/fm-spawn.sh'),id,str(h/'projects/demo'),'sleep 25','--scout']); assert p.returncode==0,p.stdout
    p=run([str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')]); assert p.stdout.strip()=='1',p.stdout
    p=run([str(r/'bin/fm-spawn.sh'),'next',str(h/'absent-project'),'--scout']); assert p.returncode==1 and 'caps concurrent workers' in p.stdout,p.stdout
    p=run([str(r/'bin/fm-afk-return.sh'),'check']); assert '1 task(s) live at return.' in p.stdout,p.stdout
    time.sleep(26)
    p=run([str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')]); assert p.returncode==0 and p.stdout.strip()=='0',p.stdout
    (h/'data'/id/'report.md').write_text('Disposable raw process ran and stopped; no source changes.\n')
    p=run([str(r/'bin/fm-teardown.sh'),id]); assert p.returncode==0,p.stdout
    result={'name':'A fresh raw-command scout launches through real Treehouse, fills the cap while running, and releases it on exit','result':'pass'}
finally:
    (e/'live-fresh-transcript.log').write_text(''.join(log)); (e/'live-fresh-result.json').write_text(json.dumps(result,indent=2))

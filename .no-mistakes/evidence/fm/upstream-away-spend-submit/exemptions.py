import pathlib,subprocess,os,shlex,json
r=pathlib.Path.cwd(); h=r/'.lab/h'; e=pathlib.Path('<operator-home>/.no-mistakes/evidence/01M4SDKM6WTX0CEK2C5DQ3RE1K'); env=os.environ.copy()
for k in list(env):
    if k=='FM_GATE_REFUSE_BYPASS' or k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k,None)
env.update(FM_HOME=str(h),FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',TMUX_TMPDIR='.lab/h/tmux',TMPDIR=str(r/'.test-tmp'))
socket=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env,text=True).strip(); env['TMUX']=socket+',501,0'
log=[]
def run(args):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30); log.append('$ '+shlex.join(args)+'\n'+p.stdout+f'[exit {p.returncode}]\n'); return p
run([str(r/'bin/fm-afk-return.sh'),'check'])
(h/'state/reserved.meta').write_text('backend=unrecognized\nwindow=unknown:worker\nkind=scout\n')
run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'])
p=run([str(r/'bin/fm-spawn.sh'),'absent','--relaunch']); assert p.returncode!=0 and 'needs an existing task record' in p.stdout and 'caps concurrent workers' not in p.stdout,p.stdout
p=run([str(r/'bin/fm-spawn.sh'),'mate',str(h/'absent-home'),'--secondmate']); assert p.returncode!=0 and 'caps concurrent workers' not in p.stdout,p.stdout
run([str(r/'bin/fm-afk-contract.sh'),'archive']); env['FM_AFK_MODE']='quiet'; run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'])
p=run([str(r/'bin/fm-spawn.sh'),'fresh',str(h/'absent-project'),'--scout']); assert p.returncode!=0 and 'caps concurrent workers' not in p.stdout and 'No such file or directory' in p.stdout,p.stdout
(h/'state/reserved.meta').unlink()
(e/'live-exemptions-transcript.log').write_text(''.join(log)); (e/'live-exemptions-result.json').write_text(json.dumps({'name':'Relaunch and secondmate requests bypass the full away cap; quiet mode does not impose it','result':'pass'},indent=2))
print('Exemption requests reached their own validation boundaries without spend-cap rejection.')

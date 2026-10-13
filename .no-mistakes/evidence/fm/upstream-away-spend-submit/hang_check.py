import pathlib,subprocess,os,signal,time,json,shlex
r=pathlib.Path.cwd(); h=r/'.lab/h'; e=pathlib.Path('<operator-home>/.no-mistakes/evidence/01M4SDKM6WTX0CEK2C5DQ3RE1K'); env=os.environ.copy()
for k in list(env):
    if k=='FM_GATE_REFUSE_BYPASS' or k.startswith('FM_') and k.endswith('_OVERRIDE'): env.pop(k,None)
env.update(FM_HOME=str(h),FM_CREW_STATE_NO_FORGE='1',FM_SUPERVISION_ACTOR='main',TMUX_TMPDIR='.lab/h/tmux',TMPDIR=str(r/'.test-tmp'))
socket=subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path}'],env=env,text=True).strip(); env['TMUX']=socket+',501,0'
pid=int(subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{pid}'],env=env,text=True))
log=['Private lab tmux socket: '+socket+'\n']; result={}
try:
    subprocess.run([str(r/'bin/fm-afk-contract.sh'),'enter','--spend','1'],env=env,check=True,stdout=subprocess.PIPE)
    os.kill(pid,signal.SIGSTOP)
    log.append('Suspended only the private lab tmux server; real tmux reads now hang.\n')
    for args in [[str(r/'bin/fm-afk-spend-count.sh'),str(h/'state')],[str(r/'bin/fm-spawn.sh'),'candidate',str(h/'absent-project'),'--scout']]:
        started=time.monotonic(); p=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=15); elapsed=time.monotonic()-started
        log.append('$ '+shlex.join(args)+'\n'+p.stdout+f'[exit {p.returncode}, elapsed {elapsed:.3f}s]\n')
        assert 4<elapsed<12,(elapsed,p.stdout)
        if 'spend-count' in args[0]: assert p.returncode==0 and p.stdout.strip()=='1',p.stdout
        else: assert p.returncode==1 and 'caps concurrent workers' in p.stdout,p.stdout
    result={'name':'A hung real tmux presence read is bounded and retains the worker in fresh admission','result':'pass'}
finally:
    os.kill(pid,signal.SIGCONT)
    log.append('Resumed the private tmux server.\n')
    (e/'live-timeout-transcript.log').write_text(''.join(log)); (e/'live-timeout-result.json').write_text(json.dumps(result,indent=2))

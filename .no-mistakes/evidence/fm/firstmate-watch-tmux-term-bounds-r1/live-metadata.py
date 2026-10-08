import os,pathlib,subprocess as sp,signal,time,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4BYXMSQ45VRM1V0Y30Z00VR'); L=R/'.nm-metadata'; S=E/'s'
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('TMUX','NO_MISTAKES_GATE'): env.pop(k,None)
env.update(FM_HOME=str(L),TMUX_TMPDIR=str(S))
def run(a):
 p=sp.run(a,env=env,text=True,capture_output=True,timeout=10)
 if p.returncode: raise RuntimeError(p.stdout+p.stderr)
 return p.stdout.strip()
def tm(*args): return run(['tmux','-L','fm-lab',*args])
server=None
try:
 run(['bash','bin/fm-lab-home.sh','create',str(L)]); S.mkdir(); S.chmod(0o700)
 tm('new-session','-d','-s','primary','-x','120','-y','40','sleep 60'); server=int(tm('display-message','-p','#{pid}'))
 env['TMUX']=tm('display-message','-p','#{socket_path}')+','+str(server)+',0'
 (L/'state'/'sample.meta').write_text('window=primary:fm-sample\nkind=ship\nharness=codex\n')
 os.kill(server,signal.SIGSTOP); start=time.monotonic()
 result=run(['bash','-c','. bin/fm-watch.sh; printf "backend=%s harness=%s kind=%s\\n" "$(window_backend primary:fm-sample)" "$(window_harness primary:fm-sample)" "$(window_kind primary:fm-sample)"'])
 assert result=='backend=tmux harness=codex kind=ship',result
 print('Real tmux server suspended; local metadata returned:',result,'in',round(time.monotonic()-start,3),'seconds')
 os.kill(server,signal.SIGCONT)
 # Actual spawn guard, using a marked lab and genuine child directory inside this worktree.
 child=R/'.nm-child'; child.mkdir();
 for directory in ('state','data','config','projects'): (child/directory).mkdir()
 (child/'.fm-secondmate-home').write_text('sample\n'); (child/'AGENTS.md').symlink_to(R/'AGENTS.md'); (child/'bin').symlink_to(R/'bin'); (child/'data'/'charter.md').write_text('Isolated validation only.\n')
 sp.run(['git','-C',str(child),'init','-q','-b','main'],env=env,check=True)
 env['FM_SPAWN_NO_GUARD']='1'
 p=sp.run(['bash','bin/fm-spawn.sh','sample',str(child),'--secondmate','--harness','codex'],env=env,text=True,capture_output=True,timeout=30)
 print('Actual recovery guard exit:',p.returncode,'output:',p.stdout+p.stderr)
 assert p.returncode and 'secondmate home cannot be inside the firstmate repo' in p.stderr+p.stdout
finally:
 if server:
  try: os.kill(server,signal.SIGCONT)
  except ProcessLookupError: pass
 sp.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True,timeout=10)
 for p in (L,R/'.nm-child',S): shutil.rmtree(p,ignore_errors=True)
 print('Lab cleaned up')

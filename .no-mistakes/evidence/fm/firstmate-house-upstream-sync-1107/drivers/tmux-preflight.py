import os,pathlib,tempfile,subprocess,shutil
root=pathlib.Path.cwd()
scratch=root/'.test-sync-validation'
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=scratch))
out=pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK/tmux-preflight.log')
env=os.environ.copy()
for key in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_BACKEND','TMUX'):
    env.pop(key,None)
env['TMUX_TMPDIR']=str(lab/'tmux')
try:
    with out.open('w') as log:
        p=subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],stdout=log,stderr=subprocess.STDOUT)
        assert p.returncode==0
        (lab/'tmux').mkdir()
        p=subprocess.run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e',f'FM_HOME={lab}','claude'],env=env,stdout=log,stderr=subprocess.STDOUT)
        log.write(f'Private 120x40 tmux launch exit={p.returncode}\n'); log.flush()
        socket=lab/'tmux'/f'tmux-{os.getuid()}'/'fm-lab'
        if socket.exists():
            q=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stdout=log,stderr=subprocess.STDOUT)
            assert q.returncode==0
        log.write('No running lab server remains.\n')
finally:
    assert lab.parent==scratch
    shutil.rmtree(lab)

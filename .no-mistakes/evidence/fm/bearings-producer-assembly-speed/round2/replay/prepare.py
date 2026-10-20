import os, pathlib, json, subprocess, tarfile, io, shutil, time
R=pathlib.Path.cwd(); T=R/'.gate-test'; E=pathlib.Path('~/.no-mistakes/evidence/01M5CVZDD40VPEDMN80Z4GV4J8/round2')
base=T/'base';base.mkdir(exist_ok=True)
subprocess.run(['git','archive','3e1049d02c1be14bbf1649c1ac2ca97e7244645c','bin'],stdout=open(T/'base.tar','wb'),check=True)
with tarfile.open(T/'base.tar') as f:f.extractall(base,filter='data')
remote=T/'remote-root';remote.mkdir(exist_ok=True)
shutil.copytree(R/'bin',remote/'bin',dirs_exist_ok=True)
shutil.copy(R/'AGENTS.md',remote/'AGENTS.md')
gitenv=dict(os.environ,GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
for k in ['GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE']:gitenv.pop(k,None)
subprocess.run(['git','init','-q',str(remote)],env=gitenv,check=True)
subprocess.run(['git','-C',str(remote),'add','bin','AGENTS.md'],env=gitenv,check=True)
parent=T/'fleet'
for home in [parent]+[T/f'mate-{i}' for i in range(1,10)]:
 for name in ['config','data','state','projects','bin']:(home/name).mkdir(parents=True,exist_ok=True)
 (home/'AGENTS.md').write_text('# Disposable Firstmate home\n')
 (home/'.fm-secondmate-home').write_text(home.name+'\n')
 (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 1000\n')
 (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
for i in range(1,814):
 name=f'contribution-{i:04d}'; d=parent/'data'/name; d.mkdir(exist_ok=True)
 (d/'report.md').write_text(f'# Investigation {i}\nCompleted report {i}.\n')
 record={'schema':'fm-contributions.v1','task':name,'records':[{'url':f'https://github.com/example/disposable/pull/{i}','kind':'pr','pending':[],'seen':[],'checked_at':'2026-10-21T00:00:00Z','error':None,'observation':None,'verdict':None}]}
 (d/'contributions.json').write_text(json.dumps(record))
with (parent/'data/backlog.md').open('a') as f:
 for i in range(1,814):f.write(f'- [x] contribution-{i:04d} - Completed investigation {i} data/contribution-{i:04d}/report.md (repo: sample) (kind: scout) (done 2026-10-20)\n')
for i in range(1,10):
 mate=T/f'mate-{i}'
 lines=[f'kind=secondmate',f'mode=secondmate','harness=codex',f'home={mate}',f'worktree={mate}',f'project={mate}','backend=tmux',f'window=unstarted:mate-{i}']
 if i>6:lines += ['remote_host=fm-gate-remote','remote_root=/opt/firstmate']
 (parent/f'state/mate-{i}.meta').write_text('\n'.join(lines)+'\n')
 status=''.join(f'working [key=phase-{n}]: completed café step {n}\nresolved [key=phase-{n}]: resolved\n' for n in range(40))
 status+='needs-decision [key=keep]: preserve this choice\nneeds-decision: [key=close] close only this choice\nresolved [key=close]: answer\ndone: unrelated secondmate task\n'
 (parent/f'state/mate-{i}.status').write_text(status)
 (mate/'data/backlog.md').write_text(f'## In flight\n\n## Queued\n\n## Done\n- [x] landed-{i} - Domain {i} investigation data/landed-{i}/report.md (repo: sample) (kind: scout) (done 2026-10-20)\n')
with (parent/'data/secondmates.md').open('w') as f:
 for i in range(1,10):
  mate=T/f'mate-{i}'; route=f'home: {mate}' if i<=6 else f'host: fm-gate-remote; root: /opt/firstmate; home: {mate}'
  f.write(f'- mate-{i} - Disposable domain ({route}; scope: test; projects: sample; added 2026-10-21)\n')
for key in ['host','client']:
 subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(T/f'{key}_key')],check=True)
(T/'ssh-account').mkdir(exist_ok=True)
(T/'authorized_keys').write_text((T/'client_key.pub').read_text())
(T/'sshd_config').write_text('Port 22\nListenAddress 0.0.0.0\nHostKey /lab/host_key\nPidFile /lab/sshd.pid\nAuthorizedKeysFile /lab/authorized_keys\nPermitRootLogin yes\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nLogLevel VERBOSE\nSetEnv PATH=/opt/firstmate/bin:/usr/local/bin:/usr/bin:/bin\n')
(E/'dataset.json').write_text(json.dumps({'homes':9,'local_secondmates':6,'remote_secondmates':3,'owned_contribution_records':813,'report_pointers':813,'parent_status_lines':9*84,'data':'disposable records generated in worktree; no operator fleet read','remote_transport':'OpenSSH in disposable Linux Docker container'},indent=2))
print('Prepared 9 homes, 813 saved contribution records and reports, 756 parent status lines.')

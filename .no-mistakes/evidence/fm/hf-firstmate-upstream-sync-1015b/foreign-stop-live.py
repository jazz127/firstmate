import pathlib,subprocess,json,os
root=pathlib.Path.cwd();temp=root/'.validation-tmp';ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4YFDQR9GTFBYVCE7QQNKRPE');home=temp/'foreign-stop-home';parent=temp/'foreign-stop-parent'
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True);(home/'bin').symlink_to(root/'bin',target_is_directory=True);(home/'AGENTS.md').write_text('# Disposable test home\n');(home/'.fm-secondmate-home').write_text('foreign-stop\n');(parent/'state').mkdir(parents=True)
gen=subprocess.check_output(['bin/fm-busy-event.sh','arm',str(parent/'state'),'foreign-stop'],text=True).strip();pointer=home/'.fm-busy-stop';pointer.write_text(f'writer={root}/bin/fm-busy-event.sh\nstate={parent}/state\nid=foreign-stop\ngen={gen}\n')
old=temp/'before-r6/bin';old.mkdir(parents=True)
for p in (root/'bin').iterdir():
 if p.name!='fm-turnend-guard.sh':(old/p.name).symlink_to(p,target_is_directory=p.is_dir())
hook=old/'fm-turnend-guard.sh';hook.write_bytes(subprocess.check_output(['git','show','ee503bf3:bin/fm-turnend-guard.sh']));hook.chmod(0o700)
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_'):env.pop(k,None)
env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home))
payload=json.dumps({'session_id':'foreign-compatibility-session','stop_hook_active':False,'cursor_version':'compatibility-event'})
record=parent/'state/foreign-stop.busy-state';before=record.read_text();oldresult=subprocess.run([str(hook),'--claude'],input=payload,text=True,env=env,capture_output=True);oldstate=record.read_text();assert 'state=idle' in oldstate,oldstate
subprocess.run(['bin/fm-busy-event.sh','apply',str(parent/'state'),'foreign-stop','busy','--gen',gen,'--source','live-test','--event','active-generation'],check=True,capture_output=True)
before=record.read_text();result=subprocess.run(['bin/fm-turnend-guard.sh','--claude'],input=payload,text=True,env=env,capture_output=True);after=record.read_text();assert result.returncode==0 and before==after
(ev/'foreign-stop-regression.json').write_text(json.dumps({'public_interface':'fm-turnend-guard.sh --claude, stdin JSON compatibility event','oracle':'R6: ignored foreign-host events cannot change an active generation record','before_fix':{'exit':oldresult.returncode,'record':oldstate},'after_fix':{'exit':result.returncode,'record_before':before,'record_after':after}},indent=2))
print('Prior Stop guard cleared the busy record for a compatibility event; current real guard leaves it byte-identical.')

import pathlib,subprocess,os,json
root=pathlib.Path.cwd();temp=root/'.validation-tmp';home=temp/'contribution-home';ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4YFDQR9GTFBYVCE7QQNKRPE')
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True)
(home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n');(home/'config/backlog-backend').write_text('manual\n')
url='https://gitlab.com/fixture/fixture-repo/-/merge_requests/2';(home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n- [ ] unsupported - Filed '+url+' (repo: sample) (kind: ship)\n')
record={'schema':'fm-contributions.v1','task':'unsupported','records':[{'url':url,'kind':'pr','checked_at':'2026-09-16T08:00:00Z','error':'forge observation unavailable or changed during read','observation':None,'verdict':None,'seen':[],'pending':[],'notified':[],'provenance':'retained ownership'}]}
(home/'data/unsupported').mkdir();file=home/'data/unsupported/contributions.json';file.write_text(json.dumps(record))
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(k,None)
env['FM_HOME']=str(home);env['TMPDIR']=str(temp/'tmp')
p=subprocess.run(['bin/fm-contributions.sh','poll'],env=env,capture_output=True,text=True);assert p.returncode==0,p.stderr;assert p.stdout==p.stderr=='',(p.stdout,p.stderr)
actual=json.loads(file.read_text());record['records'][0]['error']=None;assert actual==record;assert not (home/'state/.wake-queue').exists() or not (home/'state/.wake-queue').read_text()
snapshot=subprocess.run(['bin/fm-fleet-snapshot.sh','--contribution-input'],env=env,capture_output=True,text=True);assert snapshot.returncode==0,snapshot.stderr
inp=temp/'contributions-input.json';inp.write_text(snapshot.stdout)
p=subprocess.run(['bin/fm-contributions.sh','snapshot',str(inp),'--all'],env=env,capture_output=True,text=True);assert p.returncode==0,p.stderr
projection=json.loads(p.stdout);assert projection['unmeasured']==1 and projection['counts']['fleet']==0,projection
(ev/'contribution-reporting.json').write_text(json.dumps({'poll':{'exit':0,'stdout':'','stderr':'','wake_created':False},'persisted_record':actual,'snapshot':projection},indent=2))
print('Real contribution poll cleared only the unsupported URL legacy error; snapshot retained unmeasured coverage without fleet work or notifications.')

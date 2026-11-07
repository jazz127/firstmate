import json,subprocess,pathlib,re,os
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK')
observations=[]
for command,endpoint,field in [('npm','https://registry.npmjs.org/npm/latest','version'),('gh','https://api.github.com/repos/cli/cli/releases/latest','tag_name')]:
    release=json.loads(subprocess.check_output(['curl','-q','-fSs','--max-time','15','--url',endpoint]))[field]
    versions=[]
    for directory in os.environ['PATH'].split(':'):
        path=pathlib.Path(directory)/command
        if path.is_file() and os.access(path,os.X_OK):
            output=subprocess.check_output([str(path),'--version'],text=True)
            version=re.search(r'\d+(?:\.\d+)+',output).group()
            versions.append(version)
    def v(x):
        parts=[int(n) for n in x.lstrip('v').split('.')]
        return tuple(parts+[0]*(4-len(parts)))
    installed=max(versions,key=v)
    expected=v(release)>v(installed)
    item={'command':command,'endpoint':endpoint,'published':release,'installed_versions':versions,'update_expected':expected}
    observations.append(item); print(json.dumps(item))
log=(evidence/'releases-live.log').read_text()
for item in observations:
    label='npm' if item['command']=='npm' else 'gh-cli'
    if item['update_expected']:
        assert f'{label} update available:' in log,(item,log)
        assert item['published'].lstrip('v') in log
    else:
        assert f'{label} update available:' not in log
home=root/'.test-sync-validation/release-home'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(home),FM_TOOL_UPDATE_INTERVAL='0',FM_TOOL_UPDATE_PROBE_SECS='15',FM_TOOL_UPDATE_BUDGET_SECS='60',FM_CHECK_TIMEOUT='65')
p=subprocess.run([str(root/'bin/fm-tool-update-check.sh'),'check'],env=env,text=True,capture_output=True,timeout=65)
assert p.returncode==0 and p.stdout=='',p
print('Repeated unchanged findings suppressed: exit=0, stdout empty')
(evidence/'release-oracle.json').write_text(json.dumps(observations,indent=2)+'\n')
(evidence/'release-record.json').write_bytes((home/'state/.tool-updates').read_bytes())

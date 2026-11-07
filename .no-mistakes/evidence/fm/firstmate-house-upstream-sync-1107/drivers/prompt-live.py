import os,pathlib,subprocess,json
root=pathlib.Path.cwd();home=root/'.test-sync-validation/prompt-home';(home/'config').mkdir(parents=True)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')};env['FM_HOME']=str(home)
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK');results=[]
def generate(label,expected=0):
    p=subprocess.run(['bin/fm-branch-prompt.sh'],env=env,capture_output=True,text=True,timeout=15)
    results.append({'case':label,'exit':p.returncode,'output_bytes':len(p.stdout.encode()),'stderr':p.stderr})
    assert p.returncode==expected
    return p.stdout
try:
    baseline=generate('absent include')
    include=home/'config/branch-prompt-include.md';include.write_text(' \n\t\n')
    assert generate('blank include')==baseline
    sentinel='Disposable home rule: keep validation work under the declared workspace.'
    include.write_text(sentinel+'\n')
    output=generate('local include')
    assert output.startswith(baseline) and output.rstrip().endswith(sentinel)
    assert output[len(baseline):].count(sentinel)==1
    assert output==generate('unchanged include repeated')
    (evidence/'generated-prompt.txt').write_text(output)
    include.unlink();include.mkdir()
    assert generate('non-file include refuses before partial output',1)==''
    print(json.dumps(results,indent=2))
    print('Absent/blank includes leave output unchanged; local rule is appended once after tracked prompt; unusable include returns no partial prompt.')
finally:
    (evidence/'prompt-live.json').write_text(json.dumps(results,indent=2)+'\n')

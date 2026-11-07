import os,subprocess,pathlib,hashlib,json
root=pathlib.Path.cwd();home=root/'.test-sync-validation/inherit-home-retry'
for d in ('config','state','data'): (home/d).mkdir(parents=True,exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env['FM_HOME']=str(home)
cli=str(root/'bin/fm-remote-inherit.sh');results=[]
def run(args,body=b'',expected=0):
    p=subprocess.run([cli]+args,input=body,capture_output=True,env=env,timeout=20)
    item={'arguments':args,'exit':p.returncode,'stdout':p.stdout.decode(),'stderr':p.stderr.decode()};results.append(item);print(json.dumps(item),flush=True)
    assert p.returncode==expected,item
    return p.stdout
try:
    assert run(['generation'])==b'0\n'
    def put(generation,body,expected=0):
        return run(['put','config/crew-harness',str(len(body)),hashlib.sha256(body).hexdigest(),str(generation)],body,expected)
    put(40,b'codex\n')
    assert run(['generation'])==b'40\n'
    put(39,b'claude\n',1)
    assert (home/'config/crew-harness').read_bytes()==b'codex\n'
    put(40,b'claude\n',1)
    assert (home/'config/crew-harness').read_bytes()==b'codex\n'
    put(41,b'claude\n')
    assert (home/'config/crew-harness').read_bytes()==b'claude\n'
    assert run(['generation'])==b'41\n'
    run(['absent','config/crew-harness','0',hashlib.sha256(b'').hexdigest(),'42'])
    assert not (home/'config/crew-harness').exists()
    assert run(['generation'])==b'42\n'
    (home/'config/.fm-inherit-crew-harness.generation').write_text('broken\n')
    run(['generation'],expected=1)
    print('Receiver generation recovery contract passed; stale and conflicting updates preserved receiver bytes, and corrupt state was refused.',flush=True)
finally:
    pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK/inheritance-live.json').write_text(json.dumps(results,indent=2)+'\n')

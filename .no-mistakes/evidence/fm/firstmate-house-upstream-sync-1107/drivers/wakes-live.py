import os,pathlib,subprocess,json,re
root=pathlib.Path.cwd();home=root/'.test-sync-validation/wake-home'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))}
env.update(FM_HOME=str(home),TMPDIR=str(root/'.test-sync-validation/tmp'))
results=[]
def run(args):
    p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=40)
    item={'argv':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr};results.append(item);print(json.dumps(item),flush=True)
    assert p.returncode==0,item
    return p.stdout+p.stderr
try:
    run(['bin/fm-lab-home.sh','create',str(home)])
    producer='. "$1/bin/fm-wake-lib.sh"; fm_wake_append check custom-check "check: custom-check: alpha"; fm_wake_append check custom-check "check: custom-check: beta"; fm_wake_append check custom-check "check: custom-check: alpha"'
    run(['bash','-c',producer,'producer',str(root)])
    queue=home/'state/.wake-queue'
    assert len(queue.read_text().splitlines())==3
    output=run(['bin/fm-wake-drain.sh'])
    assert output.count('check: custom-check: alpha')==1,output
    assert output.count('check: custom-check: beta')==1,output
    assert len(queue.read_text().splitlines())==3,'Presentation must retain rows until acknowledgement'
    ack=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',output)
    assert ack,output
    run(['bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]])
    assert not queue.exists() or not queue.read_text().strip()
    print('Both distinct custom-check events were visible before acknowledging all three queued rows; the identical duplicate displayed once.\n')
finally:
    pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK/wakes-live.json').write_text(json.dumps(results,indent=2)+'\n')

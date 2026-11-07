import pathlib,subprocess,os,json,shutil
results=[]
p=subprocess.Popen(['sleep','60'])
try:
    q=subprocess.run(['bin/fm-procinfo.py',str(p.pid)],capture_output=True,text=True,timeout=10)
    results.append({'pid':p.pid,'exit':q.returncode,'kernel_facts':q.stdout,'stderr':q.stderr})
    assert q.returncode==0
    parent,comm,args=q.stdout.rstrip('\n').split('\t',2)
    assert int(parent)==os.getpid()
    ps_comm=subprocess.check_output(['ps','-p',str(p.pid),'-o','comm='],text=True).strip()
    ps_args=subprocess.check_output(['ps','-p',str(p.pid),'-o','args='],text=True).strip()
    assert comm==ps_comm and args==ps_args,(comm,args,ps_comm,ps_args)
    results[-1].update(ps_comm=ps_comm,ps_args=ps_args,expected_parent=os.getpid())
    q=subprocess.run(['bin/fm-procinfo.py','99999999'],capture_output=True,text=True,timeout=10)
    results.append({'pid':99999999,'exit':q.returncode,'stdout':q.stdout,'stderr':q.stderr})
    assert q.returncode==1 and q.stdout==''
    print(json.dumps(results,indent=2))
    print('Kernel process identity matches ps and the known parent; absent PID refuses without partial facts.')
finally:
    p.terminate();p.wait(timeout=5)
    pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK/process-live.json').write_text(json.dumps(results,indent=2)+'\n')

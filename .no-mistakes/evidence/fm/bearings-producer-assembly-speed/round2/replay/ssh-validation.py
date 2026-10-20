from drive import *
name="fm-bearings-gate-round2"
started=False
try:
 p=subprocess.run(["docker","run","-d","--name",name,"-p","127.0.0.1:22942:22","-v",str(T)+":/lab","-v",str(T)+":"+str(T),"-v",str(T/"remote-root")+":/opt/firstmate:ro","-v",str(T/"ssh-account")+":/root","fm-bearings-gate-round2"],capture_output=True,text=True,check=True)
 started=True
 (E/"ssh-container-id.log").write_text(p.stdout)
 for attempt in range(30):
  p=subprocess.run([str(T/"ssh-real"),"fm-gate-remote","printf ready"],capture_output=True,text=True)
  if p.returncode==0:break
  time.sleep(0.2)
 assert p.returncode==0,p.stderr
 (E/"ssh-preflight.log").write_text(p.stdout+p.stderr)
 for i in [7,8,9]:
  run("remote-preflight-"+str(i),[R/"bin/fm-on.sh","mate-"+str(i),"fm-remote-file.sh","get","state/home-summary.json"],T/"fleet")
 for script in ["remote-live.py","final-benchmark.py"]:
  if script=="final-benchmark.py":
   while not (T/"tests-complete").exists():time.sleep(1)
  with (E/(script+".log")).open("w") as out:
   subprocess.run(["python3",str(E/"replay"/script)],stdout=out,stderr=subprocess.STDOUT,check=True)
 p=subprocess.run(["ps","-axo","pid,ppid,command"],capture_output=True,text=True,check=True)
 collectors=[line for line in p.stdout.splitlines() if str(T/"ssh-real") in line or ("ssh -F "+str(T/"ssh_config")) in line]
 assert not collectors,collectors
 (E/"collector-cleanup.json").write_text(json.dumps({"remaining_ssh_collectors":collectors}))
finally:
 if started:
  p=subprocess.run(["docker","logs",name],capture_output=True,text=True)
  (E/"real-ssh-server.log").write_text(p.stdout+p.stderr)
  p=subprocess.run(["docker","rm","-f",name],capture_output=True,text=True)
  (E/"ssh-container-cleanup.log").write_text(p.stdout+p.stderr)
  assert p.returncode==0

import os,time,subprocess
from pathlib import Path
home=Path(os.environ['FM_HOME'])
meta=home/'state/trace-live-rollback-a7.meta'
for _ in range(18000):
    if meta.exists() and 'traceparent=' in meta.read_text():
        result=subprocess.run(['tmux','kill-window','-t','primary:fm-trace-live-rollback-a7'],capture_output=True,text=True)
        print('Removed lab endpoint after trace-carrier publication:',result.returncode,result.stderr,flush=True)
        break
    time.sleep(.005)
else:
    raise SystemExit('Timed out waiting for trace-carrier publication')

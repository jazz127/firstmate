import os, pathlib, subprocess, time, json, shutil, re
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M639H6QD1WK1K19WXV59CK32')
lab=root/'.gate-test-tmp/watcher-live'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env.update(FM_HOME=str(lab),FM_STATE_OVERRIDE=str(lab/'state'),FM_CONFIG_OVERRIDE=str(lab/'config'),FM_DATA_OVERRIDE=str(lab/'data'),TMPDIR=str(root/'.gate-test-tmp'),PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',FM_POLL='1',FM_OPEN_DECISION_OVERDUE_SECS='1',FM_OPEN_DECISION_BACKOFF_MAX_SECS='30',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
child=None
def run_watcher(label,expect_exit):
    global child
    with open(evidence/f'watcher-{label}.txt','w') as out:
        child=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            if expect_exit:
                rc=child.wait(timeout=20)
                assert rc==0,(label,rc)
            else:
                time.sleep(3)
                assert child.poll() is None, (label,'watcher unexpectedly exited')
                child.terminate()
                rc=child.wait(timeout=10)
            print(label, 'exit',rc)
        finally:
            if child.poll() is None:
                child.terminate(); child.wait(timeout=10)
            child=None
def queue():
    path=lab/'state/.wake-queue'
    return path.read_text() if path.exists() else ''
try:
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],env=env,check=True)
    (lab/'state/home-summary.json').touch()
    stamp=int(time.time())-120
    status=lab/'state/worker.status'
    status.write_text(f'needs-decision [at={stamp}] [key=api]: choose an interface\n')
    run_watcher('default-off',False)
    assert queue()==''
    assert not (lab/'state/.open-decision-reminders').exists()
    # Give the next scenario a fresh runtime, rather than stopping and rearming one watcher.
    shutil.rmtree(lab)
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],env=env,check=True)
    (lab/'state/home-summary.json').touch()
    status.write_text(f'needs-decision [at={stamp}] [key=api]: choose an interface\n')
    (lab/'config/open-decision-reminders').touch()
    # An incomplete resolution is not a completed ledger event.
    with status.open('a') as f: f.write('resolved [key=')
    run_watcher('partial-resolution',True)
    text=queue()
    assert 'open decision overdue: worker key=api' in text,text
    assert len(text.splitlines())==1,text
    print(text)
    (evidence/'watcher-reminder-receipt.txt').write_text(text+(lab/'state/.open-decision-reminders').read_text())
    with status.open('a') as f: f.write('api]: use the documented interface\n')
    # Consume and acknowledge the observed wake through the real protocol before rearming.
    drained=subprocess.run(['bash','bin/fm-wake-drain.sh'],env=env,capture_output=True,text=True,check=True)
    (evidence/'watcher-drain.txt').write_text(drained.stdout+drained.stderr)
    match=re.search(r'--ack-through (\d+) --recovery-generation (\S+)',drained.stderr)
    assert match,drained.stderr
    ack=subprocess.run(['bash','bin/fm-wake-drain.sh','--ack-through',match[1],'--recovery-generation',match[2]],env=env,capture_output=True,text=True,check=True)
    with (evidence/'watcher-drain.txt').open('a') as f: f.write(ack.stdout+ack.stderr)
    run_watcher('complete-resolution',False)
    assert queue()==''
    assert (lab/'state/.open-decision-reminders').read_text()==''
    print('Resolution consumed only after newline; reminder state retired; no further wake.')
finally:
    if child is not None and child.poll() is None:
        child.terminate(); child.wait(timeout=10)
    shutil.rmtree(lab)

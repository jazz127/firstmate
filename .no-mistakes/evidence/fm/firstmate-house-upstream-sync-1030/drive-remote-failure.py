import json, os, pathlib, shutil, subprocess, tempfile, time, re
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M64Z9JEQBNE8HSXVPR6KM05B')
lab=pathlib.Path(tempfile.mkdtemp(prefix='live-', dir=ROOT/'.validation-tmp'))
children=[]
log=[]
def note(s):
    log.append(s); (E/'remote-failure-transcript.txt').write_text('\n'.join(log)+'\n')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('HERDR_') or k.startswith('TASKS_AXI_') or k in ['TMUX','NO_MISTAKES_GATE','CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID'])}
env.update(FM_HOME=str(lab), PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR=str(lab/'tmp'), FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='1', FM_HEARTBEAT='999999', FM_STALE='999999', FM_SKIP_SECONDMATE_INHERIT='1')
def run(args, expected=0, timeout=45, inp=None):
    note('$ '+' '.join(map(str,args)))
    p=subprocess.run(list(map(str,args)),env=env,cwd=ROOT,text=True,input=inp,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    note(p.stdout.rstrip()+f'\n[exit {p.returncode}]')
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
import socket, shlex
port_reservation=socket.socket();port_reservation.bind(('127.0.0.1',0));port=port_reservation.getsockname()[1]
try:
    run(['bin/fm-lab-home.sh','create',lab]);(lab/'tmp').mkdir();(lab/'claims').mkdir()
    note('SCENARIO: a real OpenSSH connection failure emits no reply payload, advances no cursor, and creates no malformed capture.')
    (lab/'data/secondmates.md').write_text('- remote - disposable remote (host: fm-lab-remote; root: '+str(ROOT)+'; home: '+str(lab/'remote-home')+'; scope: validation; projects: example; added 2026-10-30)\n')
    config=lab/'ssh-config'
    config.write_text('Host fm-lab-remote\n HostName 127.0.0.1\n Port '+str(port)+'\n IdentityFile none\n IdentityAgent none\n IdentitiesOnly yes\n GlobalKnownHostsFile /dev/null\n UserKnownHostsFile /dev/null\n StrictHostKeyChecking yes\n ConnectTimeout 2\n')
    wrapper=lab/'real-ssh'
    wrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+shlex.quote(str(config))+' "$@"\n');wrapper.chmod(0o700)
    env['FM_SSH_BIN']=str(wrapper)
    cursor_dir=lab/'state/remote-replies';cursor_dir.mkdir()
    (cursor_dir/'remote.cursor').write_text('schema=fm-remote-reply-cursor.v1\noffset=7\nprefix_sha256='+'a'*64+'\n')
    run(['bin/fm-procevent-remote-reply.sh','arm','remote'])
    cursor_files=[p for p in (lab/'state').rglob('*') if p.is_file() and 'cursor' in p.name]
    cursors={str(p):p.read_bytes() for p in cursor_files}
    p=subprocess.run(['bin/fm-procevent-remote-reply.sh','source','remote'],env=env,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
    note('$ bin/fm-procevent-remote-reply.sh source remote\nstdout bytes: '+str(len(p.stdout))+'\nstderr: '+p.stderr.decode(errors='replace')+'[exit '+str(p.returncode)+']')
    assert p.returncode==255 and p.stdout==b''
    assert all(pathlib.Path(p).read_bytes()==b for p,b in cursors.items())
    note('Unchanged cursor files: '+str(len(cursors)))
    sid=run(['bin/fm-procevent-remote-reply.sh','source-id','remote']).strip()
    p=subprocess.run(['bin/fm-procevent.sh','start',sid],env=env,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
    note('$ bin/fm-procevent.sh start '+sid+'\n'+p.stdout.decode(errors='replace')+'[exit '+str(p.returncode)+']')
    results=list((lab/'state/procevent-inbox').rglob('*.result')) if (lab/'state/procevent-inbox').exists() else []
    assert p.returncode==0 and b'no-result:' in p.stdout and not results
    assert (lab/'state/procevent'/str(sid+'.source')).exists()
    note('No result captures; source registration retained for retry. Real OpenSSH to a local TCP port refusing connections; no fake SSH or remote response.')
finally:
    port_reservation.close()
    if (lab/'state').exists():
        try:run(['bin/fm-procevent.sh','sweep-home'],timeout=25)
        except Exception as ex:note('Cleanup diagnostic: '+str(ex))
    shutil.rmtree(lab);note('Disposable home removed.')

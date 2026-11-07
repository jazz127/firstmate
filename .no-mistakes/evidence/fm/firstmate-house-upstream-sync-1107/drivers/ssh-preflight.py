import pathlib,subprocess,socket,os,pwd,time,json,signal,shutil
root=pathlib.Path.cwd();home=root/'.test-sync-validation/ssh-lab';home.mkdir()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6SJECW2CQ53X47S7V6WK7EK')
for key in ('host','client'):
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(home/key)],check=True,capture_output=True)
port_socket=socket.socket();port_socket.bind(('127.0.0.1',0));port=port_socket.getsockname()[1];port_socket.close()
username=pwd.getpwuid(os.getuid()).pw_name
config=f'Port {port}\nListenAddress 127.0.0.1\nHostKey {home}/host\nPidFile {home}/sshd.pid\nAuthorizedKeysFile {home}/client.pub\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nPubkeyAuthentication yes\nAllowUsers {username}\nSetEnv ZDOTDIR={home}\nLogLevel VERBOSE\n'
(home/'sshd.conf').write_text(config)
client=f'Host validation\n HostName 127.0.0.1\n Port {port}\n User {username}\n IdentityFile {home}/client\n IdentitiesOnly yes\n IdentityAgent none\n UserKnownHostsFile {home}/known-hosts\n StrictHostKeyChecking accept-new\n BatchMode yes\n ConnectTimeout 3\n'
(home/'ssh.conf').write_text(client)
server=None
with (evidence/'ssh-preflight.log').open('w') as log:
    try:
        server=subprocess.Popen([shutil.which('sshd'),'-D','-e','-f',str(home/'sshd.conf')],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        time.sleep(.3)
        if server.poll() is None:
            p=subprocess.run(['ssh','-F',str(home/'ssh.conf'),'validation','printf validation-ready'],capture_output=True,text=True,timeout=8)
            log.write(json.dumps({'client_exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})+'\n')
        else:log.write(f'Isolated sshd exited before connection: {server.returncode}\n')
    finally:
        if server and server.poll() is None:server.terminate()
        if server:
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(server.pid,signal.SIGKILL);server.wait()
        log.write('Isolated SSH server stopped; keys and config remain only in disposable worktree scratch until cleanup.\n')

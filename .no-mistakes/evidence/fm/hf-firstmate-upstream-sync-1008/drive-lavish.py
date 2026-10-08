import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

root = Path.cwd()
evidence = Path(__file__).parent
lab = Path(tempfile.mkdtemp(prefix='live-lavish-', dir=root / '.gate-validation'))
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'LAVISH_AXI_', 'CHROME_DEVTOOLS_AXI_')):
        env.pop(key)
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
env.update(FM_HOME=str(lab), LAVISH_AXI_STATE_DIR=str(lab / 'lavish-state'), LAVISH_AXI_PORT=str(port), LAVISH_AXI_HOST='127.0.0.1', LAVISH_AXI_NO_OPEN='1', CHROME_DEVTOOLS_AXI_SESSION=f'fm-gate-lavish-{os.getpid()}', CHROME_DEVTOOLS_AXI_USER_DATA_DIR=str(lab / 'chrome-profile'), CHROME_DEVTOOLS_AXI_HEADED='0', CHROME_DEVTOOLS_AXI_BRIDGE_TIMEOUT_MS='60000')
server = None
poll = None
browser_attempted = False
records = []

def call(argv, timeout=75, check=True):
    result = subprocess.run([str(x) for x in argv], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    records.append({'command': [str(x) for x in argv], 'exit': result.returncode, 'output': result.stdout})
    print(json.dumps(records[-1]), flush=True)
    if check and result.returncode:
        raise RuntimeError(f'Command failed: {argv}\n{result.stdout}')
    return result.stdout

try:
    call([root / 'bin/fm-lab-home.sh', 'create', lab])
    artifact = lab / 'review.html'
    artifact.write_text('<!doctype html><html><head><title>Disposable feedback test</title></head><body style="font:20px sans-serif;background:#fff;color:#222;margin:40px"><h1>Disposable feedback test</h1><p>Testing open and ended message labels.</p></body></html>')
    serverlog = open(evidence / 'lavish-server.log', 'w')
    server = subprocess.Popen(['lavish-axi', 'server', '--port', str(port)], cwd=root, env=env, stdout=serverlog, stderr=subprocess.STDOUT)
    for _ in range(100):
        assert server.poll() is None, 'isolated Lavish server exited during startup'
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=.3).close()
            break
        except Exception:
            time.sleep(.1)
    else:
        raise RuntimeError('isolated Lavish server did not become healthy')
    output = call(['lavish-axi', artifact, '--no-open'])
    match = re.search(r'url:\s*["\']?(http://[^\s"\']+)', output)
    assert match, 'Lavish open returned no session URL'
    url = match.group(1)
    browser_attempted = True
    call(['chrome-devtools-axi', 'open', url])
    call(['chrome-devtools-axi', 'snapshot'])
    for ended in (False, True):
        capture = evidence / ('lavish-ended-capture.txt' if ended else 'lavish-open-capture.txt')
        capture_handle = open(capture, 'w')
        poll = subprocess.Popen([str(root / 'bin/fm-procevent-lavish.sh'), 'poll', str(artifact)], cwd=root, env=env, stdout=capture_handle, stderr=subprocess.STDOUT)
        time.sleep(.5)
        message = 'Ended board comment' if ended else 'Open board comment'
        button = '#sendAndEnd' if ended else '#send'
        javascript = f'''(() => {{ const input = document.querySelector('#chatInput'); if (!input) throw new Error('composer missing'); input.value = {json.dumps(message)}; input.dispatchEvent(new Event('input', {{bubbles:true}})); const button = document.querySelector({json.dumps(button)}); if (!button || button.disabled) throw new Error('send button unavailable'); button.click(); return {{message:{json.dumps(message)}, button:{json.dumps(button)}}}; }})()'''
        call(['chrome-devtools-axi', 'eval', javascript])
        assert poll.wait(timeout=20) == 0, 'real Lavish feedback poll failed'
        poll = None
        capture_handle.close()
        print(capture.read_text(), flush=True)
        output = call([root / 'bin/fm-procevent-lavish.sh', 'read', capture])
        count = 'session_ending_message_count' if ended else 'captain_message_count'
        other = 'captain_message_count' if ended else 'session_ending_message_count'
        assert f'{count}: 1' in output, output
        assert f'{other}:' not in output, output
        assert message in output, output
        call(['chrome-devtools-axi', 'screenshot', evidence / ('lavish-ended.png' if ended else 'lavish-open.png')])
finally:
    if poll:
        poll.terminate()
        poll.wait(timeout=10)
    if browser_attempted:
        try:
            call(['chrome-devtools-axi', 'stop'], timeout=20, check=False)
        except Exception as error:
            print(f'Browser cleanup error: {error}', flush=True)
    if server:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=10)
    (evidence / 'lavish-driver.json').write_text(json.dumps(records, indent=2) + '\n')
    shutil.rmtree(lab)

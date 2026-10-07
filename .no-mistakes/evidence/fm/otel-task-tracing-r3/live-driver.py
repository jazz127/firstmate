import json, os, pathlib, re, shlex, shutil, socket, subprocess, time, urllib.request

ROOT = pathlib.Path.cwd()
WORK = ROOT / '.live-pr-validation'
EVIDENCE = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4ADJEBW8JDB3406JC90E69V')
transcript = (EVIDENCE / 'live-pr-transcript.log').open('w')
processes = []
homes = []

def log(text):
    print(text, flush=True)
    transcript.write(text + '\n'); transcript.flush()

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]

env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_') or key in ['TMUX', 'NO_MISTAKES_GATE', 'HERDR_SESSION', 'HERDR_PANE']:
        env.pop(key)
env['TMPDIR'] = str(WORK / 'tmp')

def run(args, local_env=None, expected=0, timeout=40):
    log('$ ' + shlex.join(str(a) for a in args))
    result = subprocess.run(args, cwd=ROOT, env=local_env or env, text=True, capture_output=True, timeout=timeout)
    log(f'exit={result.returncode}\n{result.stdout}{result.stderr}')
    assert result.returncode == expected, result.stderr
    return result.stdout

http_port, metrics_port = port(), port()
config = WORK / 'collector.yaml'
config.write_text(f'''extensions:
  bearertokenauth:
    scheme: Bearer
    token: disposable-lab-token
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:{http_port}
        auth:
          authenticator: bearertokenauth
connectors:
  spanmetrics:
    metrics_flush_interval: 100ms
exporters:
  file:
    path: {EVIDENCE / 'collector-spans.jsonl'}
    flush_interval: 100ms
  prometheus:
    endpoint: 127.0.0.1:{metrics_port}
service:
  extensions: [bearertokenauth]
  telemetry:
    logs:
      level: warn
    metrics:
      level: none
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [file, spanmetrics]
    metrics:
      receivers: [spanmetrics]
      exporters: [prometheus]
''')

def spans():
    time.sleep(.25)
    path = EVIDENCE / 'collector-spans.jsonl'
    result = []
    if path.exists():
        for line in path.read_text().splitlines():
            for resource in json.loads(line)['resourceSpans']:
                for scope in resource['scopeSpans']:
                    for span in scope['spans']:
                        result.append((resource['resource'], span))
    return result

def count(name):
    return sum(s['name'] == name for _, s in spans())

def home(name):
    path = WORK / name
    run(['bin/fm-lab-home.sh', 'create', str(path)])
    homes.append(path)
    e = dict(env, FM_HOME=str(path), FM_CHECK_INTERVAL='0', FM_POLL='0.1', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0')
    # A private, nonexistent tmux socket prevents all fallback reads from reaching the operator's server.
    e['TMUX'] = f'{path}/private-socket,1,0'
    (path / 'state/.lock').write_text(str(os.getpid()) + '\n')
    (path / 'config/trace-context').touch()
    run(['bash', '-c', '. bin/fm-trace-context-lib.sh; fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"'], e)
    carrier = run(['bash', '-c', '. bin/fm-trace-context-lib.sh; fm_trace_context_mint'], e).strip()
    def meta(task):
        (path / f'state/{task}.meta').write_text(f'kind=ship\nmode=no-mistakes\nworktree={ROOT}\nproject={path}/projects/disposable-project\nharness=codex\nmodel=lab-model\neffort=low\ntraceparent={carrier}\n')
        (path / f'state/{task}.meta').chmod(0o600)
    return path, e, meta, carrier

def enable(path):
    header = path / 'config/trace-auth'
    header.write_text('Authorization: Bearer disposable-lab-token\n'); header.chmod(0o600)
    (path / 'config/trace-export.json').write_text(json.dumps({'enabled': True, 'endpoint': f'http://127.0.0.1:{http_port}/v1/traces', 'auth-header-file': str(header)}))

def check(e, task, url, expected=0):
    return run(['bin/fm-pr-check.sh', task, url], e, expected)

def watch(e, path, task, expected_merge):
    # A stopped watcher creates a recovery episode. Consume it through the
    # public acknowledgement interface before asking a successor to poll.
    drained = subprocess.run(['bin/fm-wake-drain.sh'], cwd=ROOT, env=e, text=True, capture_output=True, timeout=30)
    log('$ bin/fm-wake-drain.sh (before watcher)\n' + drained.stdout + drained.stderr)
    assert drained.returncode == 0
    ack = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', drained.stderr)
    if ack:
        run(['bin/fm-wake-drain.sh', '--ack-through', ack[1], '--recovery-generation', ack[2]], e)
    outpath = EVIDENCE / f'watch-{task}-{time.time_ns()}.log'
    with outpath.open('w') as out:
        p = subprocess.Popen(['bin/fm-watch.sh'], cwd=ROOT, env=e, stdout=out, stderr=subprocess.STDOUT)
        processes.append(p)
        deadline = time.monotonic() + 35
        while p.poll() is None and time.monotonic() < deadline:
            if not (path / f'state/{task}.check.sh').exists():
                time.sleep(.5)
                if p.poll() is None:
                    p.terminate()
                break
            time.sleep(.1)
        if p.poll() is None:
            p.terminate()
        p.wait(timeout=5)
    output = outpath.read_text()
    log('$ bin/fm-watch.sh (isolated home; stop after poll retirement)\n' + output)
    assert not (path / f'state/{task}.check.sh').exists(), output
    if expected_merge:
        assert 'merged' in output, output
    return output

try:
    (EVIDENCE / 'collector-spans.jsonl').unlink(missing_ok=True)
    out = (EVIDENCE / 'collector.log').open('w')
    collector = subprocess.Popen([str(WORK / 'otelcol-contrib'), '--config', str(config)], stdout=out, stderr=subprocess.STDOUT)
    processes.append(collector)
    for _ in range(100):
        assert collector.poll() is None, (EVIDENCE / 'collector.log').read_text()
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{metrics_port}/metrics', timeout=.2); break
        except Exception:
            time.sleep(.1)
    log('Actual upstreams: GitHub API via installed gh; OpenTelemetry Collector Contrib 0.162.0 authenticated OTLP/HTTP receiver and spanmetrics connector.')
    ready_url = 'https://github.com/jazz127/firstmate/pull/23'
    merged_url = 'https://github.com/jazz127/firstmate/pull/205'
    draft_url = 'https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/51829'
    run(['gh', 'pr', 'view', ready_url, '--json', 'state,isDraft,headRefOid'])
    run(['gh', 'pr', 'view', merged_url, '--json', 'state,isDraft,headRefOid'])
    run(['gh', 'pr', 'view', draft_url, '--json', 'state,isDraft'])
    path, e, meta, carrier = home('enabled-home'); enable(path)
    meta('ready-task'); check(e, 'ready-task', ready_url); check(e, 'ready-task', ready_url)
    assert count('firstmate.pr.ready') == 2
    log('PASS: two successful ready registrations produce two ready observations.')
    meta('draft-task'); check(e, 'draft-task', draft_url, expected=1)
    assert not (path / 'state/draft-task.check.sh').exists()
    meta('reject-task'); (path / 'state/reject-task.check.sh').mkdir()
    check(e, 'reject-task', ready_url, expected=1)
    assert count('firstmate.pr.ready') == 2
    log('PASS: a real draft PR and unsafe poll destination produce no ready observations.')
    meta('merge-task'); merge_env = dict(e, FM_PR_CHECK_MERGE='1')
    check(merge_env, 'merge-task', merged_url)
    assert count('firstmate.pr.ready') == 2
    watch(e, path, 'merge-task', True)
    assert count('firstmate.pr.merged') == 1
    queue = (path / 'state/.wake-queue').read_text()
    log('Persisted wake contract:\n' + queue)
    assert len(queue.splitlines()) == 1 and merged_url in queue.split('\t')[4]
    # Use the actual presentation/acknowledgement contract before rearming.
    drained = subprocess.run(['bin/fm-wake-drain.sh'], cwd=ROOT, env=e, text=True, capture_output=True, timeout=30)
    log('$ bin/fm-wake-drain.sh\n' + drained.stdout + drained.stderr)
    assert drained.returncode == 0
    ack = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', drained.stderr)
    assert ack, drained.stderr
    run(['bin/fm-wake-drain.sh', '--ack-through', ack[1], '--recovery-generation', ack[2]], e)
    (path / 'state/.last-check').unlink(missing_ok=True)
    check(merge_env, 'merge-task', merged_url)
    watch(e, path, 'merge-task', False)
    assert count('firstmate.pr.merged') == 1
    log('PASS: actual GitHub merged state produces one merged observation; re-registration and polling do not duplicate it; merge-time registration emits no ready observation.')
    all_spans = spans()
    for resource, span in all_spans:
        assert not span.get('attributes'), span
        assert span['traceId'].lower() == carrier[3:35], span
        assert span['parentSpanId'].lower() == carrier[36:52], span
        keys = {a['key'] for a in resource['attributes']}
        assert keys == {'service.name','firstmate.task.id','firstmate.task.kind','firstmate.project','firstmate.harness','firstmate.model','firstmate.effort'}, keys
    log('PASS: Collector accepts valid child spans with existing resource dimensions and zero PR-specific attributes.')
    disabled, de, dm, _ = home('default-off-home')
    dm('off-task'); check(de, 'off-task', ready_url)
    check(dict(de, FM_PR_CHECK_MERGE='1'), 'off-task', merged_url)
    watch(de, disabled, 'off-task', True)
    assert len(spans()) == 3
    log('PASS: default-off home still registers and detects merge, without exporting either observation.')
    meta('kill-task'); check(dict(e, FM_TRACE_EXPORT='off'), 'kill-task', ready_url)
    check(dict(e, FM_TRACE_EXPORT='off', FM_PR_CHECK_MERGE='1'), 'kill-task', merged_url)
    watch(dict(e, FM_TRACE_EXPORT='off'), path, 'kill-task', True)
    assert len(spans()) == 3
    log('PASS: FM_TRACE_EXPORT=off suppresses both outcomes in an enabled home.')
    time.sleep(.4)
    metrics = urllib.request.urlopen(f'http://127.0.0.1:{metrics_port}/metrics').read().decode()
    (EVIDENCE / 'fleet-metrics.prom').write_text(metrics)
    log('Collector aggregate metrics:\n' + '\n'.join(x for x in metrics.splitlines() if 'calls_total' in x))
    assert 'span_name="firstmate.pr.ready"' in metrics and 'span_name="firstmate.pr.merged"' in metrics
    collector.terminate(); collector.wait(timeout=5)
    meta('unreachable-task'); before = time.monotonic(); check(e, 'unreachable-task', ready_url)
    check(merge_env, 'unreachable-task', merged_url)
    watch(e, path, 'unreachable-task', True)
    assert len(spans()) == 3
    log(f'PASS: stopped collector leaves registration and durable confirmed-merge notification successful (whole sequence {time.monotonic()-before:.2f}s).')
    (EVIDENCE / 'live-results.json').write_text(json.dumps({'ready_observations':2,'merged_observations':1,'privacy':'no PR-specific attributes','default_off':'pass','off_switch':'pass','collector_failure':'pass'}, indent=2)+'\n')
finally:
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
    for path in homes:
        shutil.rmtree(path)
    log('Disposable homes removed; Collector and watcher processes stopped.')
    transcript.close()

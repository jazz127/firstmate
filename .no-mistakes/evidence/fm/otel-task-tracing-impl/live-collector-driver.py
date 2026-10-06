#!/usr/bin/env python3
"""Drive the public Bash emitter into an official authenticated OTLP Collector.

Oracle: W3C traceparent constants and OTLP/JSON plus documented Firstmate
configuration/caller contracts. The TCP tap forwards to the actual collector;
it never synthesizes an HTTP response. Delay is a transport fault injection.
"""
import concurrent.futures
import json
import os
import pathlib
import secrets
import shutil
import socket
import socketserver
import subprocess
import threading
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path.cwd()
WORK = ROOT / '.tmp-otel-validation'
EVIDENCE = pathlib.Path(__file__).parent
HOME = WORK / 'home'
STATE = HOME / 'state'
CONFIG = HOME / 'config'
TRACE = '4bf92f3577b34da6a3ce929d0e0e4736'
PARENT = '00f067aa0ba902b7'
CARRIER = f'00-{TRACE}-{PARENT}-01'
TOKEN = secrets.token_urlsafe(36)
REQUESTS = []
OBS = []
TAPS = []
COLLECTOR = None
LEGACY_COLLECTOR = None


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def record(case, **values):
    OBS.append({'case': case, **values})
    print(json.dumps(OBS[-1], ensure_ascii=False), flush=True)


class Tap(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Forward(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(6)
        data = b''
        while b'\r\n\r\n' not in data:
            part = self.request.recv(65536)
            if not part:
                return
            data += part
        headers, body = data.split(b'\r\n\r\n', 1)
        lines = headers.decode('iso-8859-1').split('\r\n')
        fields = dict(line.split(': ', 1) for line in lines[1:] if ': ' in line)
        length = int(fields.get('Content-Length', 0))
        while len(body) < length:
            body += self.request.recv(65536)
        entry = {
            'request_line': lines[0],
            'content_type': fields.get('Content-Type'),
            'bearer_header_present': fields.get('Authorization', '').startswith('Bearer '),
            'bearer_header_matches_collector': fields.get('Authorization') == 'Bearer ' + TOKEN,
            'body': json.loads(body),
            'delay_seconds': self.server.delay,
        }
        REQUESTS.append(entry)
        time.sleep(self.server.delay)
        try:
            with socket.create_connection(('127.0.0.1', self.server.upstream), timeout=5) as upstream:
                upstream.sendall(headers + b'\r\n\r\n' + body)
                response = b''
                while b'\r\n\r\n' not in response:
                    chunk = upstream.recv(65536)
                    if not chunk:
                        break
                    response += chunk
                response_headers, response_body = response.split(b'\r\n\r\n', 1)
                entry['actual_collector_response'] = response_headers.split(b'\r\n')[0].decode()
                response_fields = {}
                for line in response_headers.decode('iso-8859-1').split('\r\n')[1:]:
                    if ': ' in line:
                        key, value = line.split(': ', 1)
                        response_fields[key.lower()] = value
                response_length = int(response_fields.get('content-length', len(response_body)))
                while len(response_body) < response_length:
                    response_body += upstream.recv(65536)
                try:
                    self.request.sendall(response_headers + b'\r\n\r\n' + response_body)
                except OSError:
                    entry['caller_disconnected_after_timeout'] = True
        except Exception as error:
            entry['transport_error'] = str(error)


def tap(upstream, delay=0):
    server = Tap(('127.0.0.1', 0), Forward)
    server.upstream, server.delay = upstream, delay
    TAPS.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f'http://127.0.0.1:{server.server_address[1]}/v1/traces'


def config(endpoint, directory=CONFIG, **extra):
    directory.mkdir(parents=True, exist_ok=True)
    value = {'enabled': True, 'endpoint': endpoint, 'auth-header-file': str(WORK / 'header')}
    value.update(extra)
    (directory / 'trace-export.json').write_text(json.dumps(value))


def emit(name, start='1000', end='2500', options=('--root',), meta=None, env=None, traced=False):
    environment = os.environ.copy()
    for key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_TRACE_EXPORT', 'FM_TRACE_CONTEXT'):
        environment.pop(key, None)
    environment.update(FM_HOME=str(HOME), TMPDIR=str(WORK / 'tmp'))
    environment.update(env or {})
    for key in tuple(environment):
        if environment[key] is None:
            environment.pop(key)
    program = '''
set -euo pipefail
CDPATH=.
. "${FM_VALIDATION_LIBRARY:-bin/fm-trace-span-lib.sh}"
if [ "$1" = traced ]; then
  exec 9> "$2"
  BASH_XTRACEFD=9
  set -x
fi
shift 2
before=$-
fm_trace_span_emit "$@"
[ "$-" = "$before" ]
[ "$CDPATH" = . ]
printf 'caller continued; shell options preserved\\n'
'''
    command = ['bash', '-c', program, '_', 'traced' if traced else 'plain', str(WORK / 'xtrace'),
               str(meta or STATE / 'task.meta'), name, str(start), str(end), *options]
    started = time.monotonic()
    completed = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True, timeout=7)
    duration = time.monotonic() - started
    assert completed.returncode == 0, (name, completed.returncode, completed.stderr)
    assert completed.stdout == 'caller continued; shell options preserved\n', (name, completed.stdout)
    assert TOKEN not in completed.stdout + completed.stderr
    record(name, caller_exit=completed.returncode, caller_stdout=completed.stdout.strip(),
           caller_stderr=completed.stderr.strip(), elapsed_seconds=round(duration, 3))
    return completed, duration


def wait_response(index):
    for _ in range(100):
        if len(REQUESTS) > index and 'actual_collector_response' in REQUESTS[index]:
            return REQUESTS[index]
        time.sleep(.05)
    raise AssertionError(('no collector response', REQUESTS[index:]))


def exported(name, **kwargs):
    count = len(REQUESTS)
    emit(name, **kwargs)
    entry = wait_response(count)
    assert len(REQUESTS) == count + 1, name
    assert entry['actual_collector_response'] == 'HTTP/1.1 200 OK', entry
    assert entry['bearer_header_matches_collector']
    assert entry['content_type'] == 'application/json'
    return entry['body']['resourceSpans'][0]


def skipped(name, **kwargs):
    count = len(REQUESTS)
    completed, _ = emit(name, **kwargs)
    assert len(REQUESTS) == count, (name, 'unexpected HTTP request')
    record(name + ' observation', real_receiver_requests=0)
    return completed


def metrics(endpoint):
    return urllib.request.urlopen(endpoint, timeout=2).read().decode()


def main():
    global COLLECTOR, LEGACY_COLLECTOR
    (EVIDENCE / 'collector-spans.jsonl').unlink(missing_ok=True)
    for directory in (STATE, CONFIG, WORK / 'tmp'):
        directory.mkdir(parents=True, exist_ok=True)
    (STATE / '.lock').write_text(f'{os.getpid()}\n')
    (CONFIG / 'trace-context').touch()
    (STATE / 'task.meta').write_text(f'traceparent={CARRIER}\nkind=ship\nproject=/private/client-alpha\nharness=codex\nmodel=café 日本語 🐟\neffort=high\nendpoint_task_id=lab-task\nhome=/private/never-export\nspawn_gen=123\n')
    (STATE / 'minimal.meta').write_text(f'traceparent={CARRIER}\n')
    for filename, content in (('header', 'Authorization: Bearer ' + TOKEN + '\n'), ('collector-token', TOKEN)):
        file = WORK / filename
        file.write_text(content)
        file.chmod(0o600)
    receiver, rejected, prom, health = (port() for _ in range(4))
    cfg = f'''extensions:
  bearertokenauth:
    filename: {json.dumps(str(WORK / 'collector-token'))}
  health_check:
    endpoint: 127.0.0.1:{health}
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:{receiver}
        auth:
          authenticator: bearertokenauth
  otlp/reject:
    protocols:
      http:
        endpoint: 127.0.0.1:{rejected}
        auth:
          authenticator: bearertokenauth
processors:
  filter/reject:
    error_mode: propagate
    traces:
      span:
        - 'Int(name) > 0'
connectors:
  span_metrics:
    namespace: fleet
    metrics_flush_interval: 100ms
    histogram:
      unit: ms
    dimensions:
      - name: firstmate.project
      - name: firstmate.task.kind
    resource_metrics_key_attributes: [service.name]
    exclude_dimensions: [collector.instance.id]
exporters:
  file:
    path: {json.dumps(str(EVIDENCE / 'collector-spans.jsonl'))}
  prometheus:
    endpoint: 127.0.0.1:{prom}
service:
  extensions: [bearertokenauth, health_check]
  telemetry:
    metrics:
      level: none
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [file, span_metrics]
    traces/reject:
      receivers: [otlp/reject]
      processors: [filter/reject]
      exporters: [file]
    metrics:
      receivers: [span_metrics]
      exporters: [prometheus]
'''
    (EVIDENCE / 'collector-config.yaml').write_text(cfg)
    collector_log = (EVIDENCE / 'collector.log').open('w')
    COLLECTOR = subprocess.Popen([str(WORK / 'otelcol-contrib'), '--config', str(EVIDENCE / 'collector-config.yaml')], stdout=collector_log, stderr=subprocess.STDOUT)
    for _ in range(100):
        if COLLECTOR.poll() is not None:
            raise AssertionError('collector failed to start: see collector.log')
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{health}', timeout=.2).close()
            break
        except Exception:
            time.sleep(.05)
    else:
        raise AssertionError('collector readiness failed')
    endpoint = tap(receiver)
    rejected_endpoint = tap(rejected)
    slow_endpoint = tap(receiver, 2)
    record('official collector running', version='0.162.0', receiver=receiver, error_receiver=rejected,
           prometheus=prom, transparent_tcp_tap=endpoint, synthetic_responses=False)
    subprocess.run(['bash', '-c', '. bin/fm-trace-context-lib.sh; fm_trace_context_session_start "$1" "$2"', '_',
                    str(CONFIG), str(STATE / '.trace-context-effective')], cwd=ROOT, check=True)
    assert (STATE / '.trace-context-effective').read_text() == f'{os.getpid()} on\n'

    skipped('default off without configuration')
    config(endpoint, enabled=False)
    skipped('explicit disabled configuration')
    config(endpoint)
    skipped('process off override', env={'FM_TRACE_EXPORT': 'off'})
    special = 'root "quoted" \\ slash\ncontrol\x01 café 日本語 🐟'
    resource = exported(special, options=('--root', '--status', 'ok', 'detail=quote" \\ newline\n\x02'))
    span = resource['scopeSpans'][0]['spans'][0]
    assert resource['scopeSpans'][0]['scope']['name'] == 'firstmate'
    assert span['traceId'] == TRACE and span['spanId'] == PARENT and 'parentSpanId' not in span
    assert span['name'] == special and span['kind'] == 1 and span['status'] == {'code': 1}
    assert span['startTimeUnixNano'] == '1000000000' and span['endTimeUnixNano'] == '2500000000'
    assert span['attributes'] == [{'key': 'detail', 'value': {'stringValue': 'quote" \\ newline\n\x02'}}]
    attrs = {attr['key']: attr['value']['stringValue'] for attr in resource['resource']['attributes']}
    assert attrs == {'service.name': 'firstmate', 'firstmate.task.id': 'lab-task', 'firstmate.project': 'client-alpha',
                     'firstmate.task.kind': 'ship', 'firstmate.harness': 'codex', 'firstmate.model': 'café 日本語 🐟', 'firstmate.effort': 'high'}
    child_resource = exported('child clamped duration', start='09', end='08', options=('--status', 'error'))
    child = child_resource['scopeSpans'][0]['spans'][0]
    assert child['traceId'] == TRACE and child['parentSpanId'] == PARENT
    assert len(child['spanId']) == 16 and child['spanId'] != PARENT and int(child['spanId'], 16) != 0
    assert child['startTimeUnixNano'] == child['endTimeUnixNano'] == '9000000'
    assert child['status'] == {'code': 2}
    minimal = exported('minimal metadata', meta=STATE / 'minimal.meta', start='01000', end='02000')
    assert {attr['key'] for attr in minimal['resource']['attributes']} == {'service.name', 'firstmate.task.id'}
    assert 'status' not in minimal['scopeSpans'][0]['spans'][0]
    assert minimal['scopeSpans'][0]['spans'][0]['startTimeUnixNano'] == '1000000000'
    exported('xtrace credential secrecy', traced=True)
    xtrace = (WORK / 'xtrace').read_text()
    assert xtrace and TOKEN not in xtrace
    (EVIDENCE / 'xtrace.log').write_text(xtrace)
    record('wire and secret oracle', exact_w3c_identity=True, nanoseconds=True, negative_duration_zero=True,
           controls_and_unicode_preserved=True, project_basename_only=True, absent_metadata_omitted=True,
           token_absent_from_stdout_stderr_payload_and_dedicated_xtrace=True)

    original = (CONFIG / 'trace-export.json').read_text()
    for name, value in [('concatenated enabled objects', original + original), ('malformed config', '{bad json'),
                        ('empty config', ''), ('array config', '[' + original + ']'), ('null config', 'null')]:
        (CONFIG / 'trace-export.json').write_text(value)
        skipped(name)
    (CONFIG / 'trace-export.json').write_text(original)
    for name, carrier in [('invalid traceparent', 'invalid'), ('zero trace identity', '00-' + '0' * 32 + '-' + PARENT + '-01')]:
        (STATE / 'bad.meta').write_text('traceparent=' + carrier + '\n')
        skipped(name, meta=STATE / 'bad.meta')
    skipped('missing metadata', meta=STATE / 'missing.meta')
    (STATE / '.trace-context-effective').write_text(f'{os.getpid() + 1} on\n')
    skipped('stale session-bound state')
    (STATE / '.trace-context-effective').write_text(f'{os.getpid()} on\n')
    for options in [('--rot',), ('--status',), ('--status', 'invalid'), ('detail=value', '--root')]:
        skipped('invalid invocation ' + repr(options), options=options)
    header = WORK / 'header'
    header.chmod(0o644)
    completed = skipped('non-private bearer header')
    assert completed.stderr == 'firstmate: trace export skipped: invalid private bearer header file\n'
    header.chmod(0o600)
    header.write_text('Authorization: Bearer ' + TOKEN + '\nextra\n')
    skipped('header extra bytes')
    header.write_text('Authorization: Bearer ' + TOKEN + '\n')

    alternate_state = WORK / 'runtime' / 'state'
    alternate_config = WORK / 'alternate-config'
    alternate_state.mkdir(parents=True, exist_ok=True)
    for filename in ('.lock', '.trace-context-effective', 'task.meta'):
        shutil.copyfile(STATE / filename, alternate_state / filename)
    config(rejected_endpoint, directory=WORK / 'runtime' / 'config')
    exported('state override keeps home collector', meta=alternate_state / 'task.meta', env={'FM_STATE_OVERRIDE': str(alternate_state)})
    config(endpoint, directory=alternate_config)
    exported('explicit config and state override', meta=alternate_state / 'task.meta',
             env={'FM_STATE_OVERRIDE': str(alternate_state), 'FM_CONFIG_OVERRIDE': str(alternate_config)})
    exported('root override when home unset', env={'FM_HOME': None, 'FM_ROOT_OVERRIDE': str(HOME)})
    skipped('metadata belonging to another home', meta=alternate_state / 'task.meta')
    skipped('state override refuses old home metadata', env={'FM_STATE_OVERRIDE': str(alternate_state)})
    exported('unset home with explicit config and state', env={'FM_HOME': None, 'FM_CONFIG_OVERRIDE': str(CONFIG), 'FM_STATE_OVERRIDE': str(STATE)})
    code_home = WORK / 'code-home'
    (code_home / 'bin').mkdir(parents=True, exist_ok=True)
    (code_home / 'state').mkdir(exist_ok=True)
    for filename in ('fm-trace-span-lib.sh', 'fm-trace-context-lib.sh', 'fm-timing-lib.sh'):
        shutil.copyfile(ROOT / 'bin' / filename, code_home / 'bin' / filename)
    for filename in ('.lock', '.trace-context-effective', 'task.meta'):
        shutil.copyfile(STATE / filename, code_home / 'state' / filename)
    config(endpoint, directory=code_home / 'config')
    default_env = {'FM_HOME': None, 'FM_VALIDATION_LIBRARY': str(code_home / 'bin' / 'fm-trace-span-lib.sh')}
    exported('default configuration from library code home', meta=code_home / 'state' / 'task.meta', env=default_env)
    exported('state override retains default code-home collector', meta=alternate_state / 'task.meta',
             env={**default_env, 'FM_STATE_OVERRIDE': str(alternate_state)})

    # Remove curl from a private PATH while retaining actual dependencies.
    no_curl = WORK / 'no-curl'
    no_curl.mkdir(exist_ok=True)
    for tool in ('bash', 'jq', 'grep', 'sed', 'head', 'basename', 'dirname', 'tr', 'od', 'uname', 'stat', 'cmp'):
        if not (no_curl / tool).exists():
            (no_curl / tool).symlink_to(shutil.which(tool))
    assert not (no_curl / 'curl').exists()
    skipped('missing curl', env={'PATH': str(no_curl)})

    # Real receiver authentication rejection, not a synthetic status server.
    header.write_text('Authorization: Bearer wrong-disposable-token\n')
    count = len(REQUESTS)
    emit('actual collector rejects wrong credential')
    denied = wait_response(count)
    assert denied['actual_collector_response'].startswith('HTTP/1.1 401'), denied
    header.write_text('Authorization: Bearer ' + TOKEN + '\n')
    config(rejected_endpoint)
    count = len(REQUESTS)
    emit('actual collector pipeline fails')
    failed = wait_response(count)
    assert failed['actual_collector_response'].startswith('HTTP/1.1 503'), failed
    # Collector 0.85 emits actual HTTP 500 for a failing trace consumer;
    # current collectors map the same error to 503. Both are real upstreams.
    legacy_port = port()
    legacy_cfg = f'''receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:{legacy_port}
processors:
  filter/reject:
    error_mode: propagate
    traces:
      span:
        - 'Substring(name, 999, 1) != ""'
exporters:
  logging:
    verbosity: basic
service:
  telemetry:
    metrics:
      level: none
  pipelines:
    traces:
      receivers: [otlp]
      processors: [filter/reject]
      exporters: [logging]
'''
    (EVIDENCE / 'collector-legacy-config.yaml').write_text(legacy_cfg)
    legacy_log = (EVIDENCE / 'collector-legacy.log').open('w')
    LEGACY_COLLECTOR = subprocess.Popen([str(WORK / 'legacy' / 'otelcol-contrib'), '--config',
                                       str(EVIDENCE / 'collector-legacy-config.yaml')], stdout=legacy_log, stderr=subprocess.STDOUT)
    for _ in range(100):
        if LEGACY_COLLECTOR.poll() is not None:
            raise AssertionError('legacy collector failed to start: see collector-legacy.log')
        try:
            with socket.create_connection(('127.0.0.1', legacy_port), timeout=.2):
                break
        except OSError:
            time.sleep(.05)
    config(tap(legacy_port))
    count = len(REQUESTS)
    emit('actual legacy collector HTTP 500')
    failed500 = wait_response(count)
    assert failed500['actual_collector_response'].startswith('HTTP/1.1 500'), failed500
    config('http://127.0.0.1:' + str(port()) + '/v1/traces')
    emit('connection refused')
    config(slow_endpoint)
    count = len(REQUESTS)
    # Inspect live OS argv while the actual curl is waiting for transport.
    with concurrent.futures.ThreadPoolExecutor() as executor:
        running = executor.submit(emit, 'delayed collector transport')
        time.sleep(.3)
        ps = subprocess.run(['ps', '-axo', 'pid,ppid,args'], capture_output=True, text=True, check=True).stdout
        relevant = '\n'.join(line for line in ps.splitlines() if 'curl -q --globoff' in line and str(header) in line)
        assert relevant and TOKEN not in relevant
        (EVIDENCE / 'curl-process-argv.log').write_text(relevant + '\n')
        completed, elapsed = running.result()
    assert elapsed < 1.6, elapsed
    delayed = wait_response(count)
    assert delayed['actual_collector_response'] == 'HTTP/1.1 200 OK', delayed
    record('failure oracle', actual_http_401=denied['actual_collector_response'], actual_http_500=failed500['actual_collector_response'],
           actual_http_503=failed['actual_collector_response'], http_500_collector_version='0.85.0',
           delayed_request_later_accepted_by_real_collector=True, timeout_elapsed_seconds=round(elapsed, 3),
           token_absent_from_actual_curl_argv=True)

    # The real collector turns emitted spans into fleet metric dimensions.
    prom_url = f'http://127.0.0.1:{prom}/metrics'
    for _ in range(100):
        output = metrics(prom_url)
        if 'fleet_calls_total' in output and 'firstmate_project="client-alpha"' in output and 'delayed collector transport' in output:
            break
        time.sleep(.1)
    else:
        raise AssertionError('aggregate metrics did not appear')
    assert 'fleet_duration_milliseconds_sum' in output
    assert 'firstmate_task_id=' not in output
    (EVIDENCE / 'fleet-metrics.prom').write_text(output)
    record('aggregate fleet metrics', real_prometheus_endpoint=prom_url,
           project_dimension='client-alpha', per_task_identity_dimension=False,
           spans_accepted=sum(entry.get('actual_collector_response') == 'HTTP/1.1 200 OK' for entry in REQUESTS))
    assert TOKEN not in json.dumps(REQUESTS) + json.dumps(OBS)
    record('complete', result='pass', all_requests_forwarded_to_official_collector=True)


try:
    main()
finally:
    if LEGACY_COLLECTOR is not None and LEGACY_COLLECTOR.poll() is None:
        LEGACY_COLLECTOR.terminate()
        LEGACY_COLLECTOR.wait(timeout=10)
    if COLLECTOR is not None and COLLECTOR.poll() is None:
        COLLECTOR.terminate()
        COLLECTOR.wait(timeout=10)
    for server in TAPS:
        server.shutdown()
        server.server_close()
    (EVIDENCE / 'live-observations.json').write_text(json.dumps(OBS, ensure_ascii=False, indent=2))
    (EVIDENCE / 'http-wire-evidence.json').write_text(json.dumps(REQUESTS, ensure_ascii=False, indent=2))
    # Even a failed run never publishes its disposable bearer secret.
    for artifact in EVIDENCE.iterdir():
        if artifact.is_file():
            data = artifact.read_bytes()
            if TOKEN.encode() in data:
                artifact.write_bytes(data.replace(TOKEN.encode(), b'[REDACTED DISPOSABLE TOKEN]'))

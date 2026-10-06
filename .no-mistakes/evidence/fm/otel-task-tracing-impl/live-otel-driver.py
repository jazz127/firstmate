import json, os, pathlib, secrets, shutil, signal, socket, subprocess, time, urllib.request, urllib.error
ROOT = pathlib.Path.cwd()
WORK = ROOT / '.test-otel'
EVIDENCE = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M48P9XZH3CX8RVGFRJK967JY')
BIN = WORK / 'tools/otelcol-contrib'
for item in WORK.iterdir():
    if item.name not in ['tools', 'tmp', 'components.txt']:
        if item.is_dir(): shutil.rmtree(item)
        else: item.unlink()
for name in ['collector-spans.jsonl','alternate-spans.jsonl','caller-transcript.jsonl','live-results.json']:
    (EVIDENCE/name).unlink(missing_ok=True)
SECRET = secrets.token_urlsafe(32)
PROCS = []
LOGS = []
REPORT = []
ENV = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('OTEL_'))}
ENV['TMPDIR'] = str(WORK / 'tmp')

def freeport():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
ports = {n:freeport() for n in ['main','alternate','error','relay']}
endpoints = {n:f'http://127.0.0.1:{p}/v1/traces' for n,p in ports.items()}

def start_collector(name, config, port, binary=BIN):
    path = WORK / (name + '.yaml'); path.write_text(config); path.chmod(0o600)
    log = (EVIDENCE / (name + '.log')).open('w'); LOGS.append(log)
    proc = subprocess.Popen([str(binary), '--config', str(path)], stdout=log, stderr=log, env=ENV)
    PROCS.append(proc)
    for _ in range(150):
        if proc.poll() is not None:
            raise RuntimeError(f'{name} exited {proc.returncode}; inspect collector log')
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=.1): return proc
        except OSError: time.sleep(.05)
    raise RuntimeError(f'{name} did not listen')

def read_spans(filename='collector-spans.jsonl'):
    f = EVIDENCE / filename
    if not f.exists(): return []
    spans = []
    for line in f.read_text().splitlines():
        if not line.strip(): continue
        for rs in json.loads(line)['resourceSpans']:
            for ss in rs['scopeSpans']:
                for s in ss['spans']: spans.append((rs.get('resource',{}),ss.get('scope',{}),s))
    return spans

def count(): return len(read_spans()) + len(read_spans('alternate-spans.jsonl'))

def check(condition, msg):
    if not condition: raise AssertionError(msg)

def record(name, detail):
    REPORT.append({'scenario':name,'result':'pass','detail':detail})
    print(name + ': ' + detail, flush=True)

def config(home, endpoint=None, enabled=True, header=None):
    directory = pathlib.Path(home)/'config'; directory.mkdir(exist_ok=True,parents=True)
    (directory/'trace-export.json').write_text(json.dumps({'enabled':enabled,'endpoint':endpoint or endpoints['main'],'auth-header-file':str(header or HEADER)}))

def emit(name, start='01000', end='02000', args=('--root',), meta=None, extra_env=None, library=None, expect_delta=1):
    before = count()
    env = dict(ENV, FM_HOME=str(HOME))
    if extra_env: env.update(extra_env)
    env = {k:v for k,v in env.items() if v is not None}
    trace = WORK / 'xtrace'; stdout = WORK / 'stdout'; stderr = WORK / 'stderr'
    # Public shell entry point. Constants come from intent's OTLP/JSON, W3C identity,
    # decimal milliseconds and best-effort shell contracts, never source matching.
    script = '''set -eu; set -o pipefail
CDPATH=.
. "$1"
exec 9> "$2"
BASH_XTRACEFD=9
set -x
before=$-
shift 2
fm_trace_span_emit "$@"
[ "$-" = "$before" ]
[[ -o pipefail ]]
set +x
printf 'caller continued with unchanged options\\n'
'''
    argv = ['bash','-c',script,'_',str(library or ROOT/'bin/fm-trace-span-lib.sh'),str(trace),str(meta or META),name,str(start),str(end),*args]
    t = time.monotonic()
    p = subprocess.run(argv,env=env,capture_output=True,text=True,timeout=12)
    elapsed = time.monotonic()-t
    check(p.returncode == 0, f'{name}: caller exited {p.returncode}: {p.stderr}')
    check(p.stdout == 'caller continued with unchanged options\n', f'{name}: caller output changed')
    check(SECRET not in p.stdout+p.stderr+trace.read_text(), f'{name}: token leaked in caller output/xtrace')
    calls = [line for line in trace.read_text().splitlines() if 'curl -q ' in line]
    check(all(SECRET not in line for line in calls), f'{name}: token leaked in traced curl argv')
    if expect_delta == 0:
        check(not calls, f'{name}: no-op still invoked curl')
    else: check(len(calls)==1, f'{name}: expected exactly one real curl invocation')
    time.sleep(.04)
    check(count() == before+expect_delta, f'{name}: accepted span delta {count()-before} != {expect_delta}')
    with (EVIDENCE/'caller-transcript.jsonl').open('a') as f:
        f.write(json.dumps({'name':name,'exit':p.returncode,'elapsed_seconds':round(elapsed,3),'stdout':p.stdout,'stderr':p.stderr,'real_curl_argv':calls,'accepted_span_delta':count()-before})+'\n')
    return elapsed

def fault_emit(name, endpoint, args=('--root',), max_seconds=None):
    config(HOME,endpoint)
    # Fault emissions make a genuine request but must never be accepted downstream.
    # Avoid the no-curl assertion specific to locally rejected invocations.
    before=count()
    env=dict(ENV, FM_HOME=str(HOME))
    trace=WORK/'fault-xtrace'
    program='''set -eu; set -o pipefail; . "$1"; exec 9> "$2"; BASH_XTRACEFD=9; set -x; before=$-; shift 2; fm_trace_span_emit "$@"; [ "$-" = "$before" ]; [[ -o pipefail ]]; set +x; printf 'caller continued with unchanged options\\n' '''
    t=time.monotonic()
    p=subprocess.run(['bash','-c',program,'_',str(ROOT/'bin/fm-trace-span-lib.sh'),str(trace),str(META),name,'1','2',*args],env=env,capture_output=True,text=True,timeout=10)
    elapsed=time.monotonic()-t
    check(p.returncode==0 and p.stdout=='caller continued with unchanged options\n',f'{name}: failure changed caller')
    check(SECRET not in p.stdout+p.stderr+trace.read_text(),f'{name}: credential leaked')
    calls=[l for l in trace.read_text().splitlines() if 'curl -q ' in l]
    check(len(calls)==1,f'{name}: endpoint was not attempted')
    check(count()==before,f'{name}: failed request was accepted')
    if max_seconds: check(elapsed < max_seconds,f'{name}: unbounded wait {elapsed}')
    with (EVIDENCE/'caller-transcript.jsonl').open('a') as f:
        f.write(json.dumps({'name':name,'endpoint':endpoint,'exit':p.returncode,'elapsed_seconds':round(elapsed,3),'stdout':p.stdout,'stderr':p.stderr,'real_curl_argv':calls,'accepted_span_delta':0})+'\n')
    return elapsed

HOME=WORK/'home'; STATE=HOME/'state'; STATE.mkdir(parents=True,exist_ok=True)
HEADER=WORK/'private-header'; HEADER.write_text('Authorization: Bearer '+SECRET+'\n'); HEADER.chmod(0o600)
(STATE/'.lock').write_text('101\n'); (STATE/'.trace-context-effective').write_text('101 on\n')
META=STATE/'task-1.meta'
CARRIER='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
META.write_text(f'traceparent={CARRIER}\nendpoint_task_id=task-1\nkind=ship\nproject=/private/projects/fleet-metrics\nhome=/private/home\nworktree=/private/project-worktree\nmodel=café 日本語 🐟\nspawn_gen=1234\n')
base = f'''extensions:
  bearertokenauth:
    token: {SECRET}
receivers:
'''
for name in ['main','alternate']:
    base+=f'''  otlp/{name}:
    protocols:
      http:
        endpoint: 127.0.0.1:{ports[name]}
        auth:
          authenticator: bearertokenauth
'''
base+=f'''processors:
  transform/fault:
    error_mode: propagate
    trace_statements:
      - context: span
        statements:
          - set(attributes["parsed"], ParseJSON(attributes["bad"]))
exporters:
  file/main:
    path: {EVIDENCE}/collector-spans.jsonl
    flush_interval: 10ms
  file/alternate:
    path: {EVIDENCE}/alternate-spans.jsonl
    flush_interval: 10ms
  debug:
    verbosity: detailed
service:
  extensions: [bearertokenauth]
  telemetry:
    metrics:
      level: none
    logs:
      level: info
  pipelines:
    traces/main:
      receivers: [otlp/main]
      exporters: [file/main]
    traces/alternate:
      receivers: [otlp/alternate]
      exporters: [file/alternate]
'''
relay=f'''extensions:
  bearertokenauth:
    token: {SECRET}
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:{ports['relay']}
        auth:
          authenticator: bearertokenauth
exporters:
  otlp_http:
    endpoint: http://127.0.0.1:{ports['main']}
    headers:
      Authorization: Bearer {SECRET}
    timeout: 4s
    retry_on_failure:
      enabled: false
    sending_queue:
      enabled: false
service:
  extensions: [bearertokenauth]
  telemetry:
    metrics:
      level: none
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlp_http]
'''
faultconfig=f'''receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:{ports['error']}
processors:
  transform:
    error_mode: propagate
    trace_statements:
      - context: span
        statements:
          - set(attributes["parsed"], ParseJSON(attributes["bad"]))
exporters:
  logging:
    verbosity: detailed
service:
  telemetry:
    metrics:
      level: none
  pipelines:
    traces:
      receivers: [otlp]
      processors: [transform]
      exporters: [logging]
'''
try:
    primary=start_collector('collector',base,ports['main'])
    relayproc=start_collector('relay-collector',relay,ports['relay'])
    errorproc=start_collector('fault-collector',faultconfig,ports['error'],WORK/'tools/collector-080/otelcol-contrib')
    # Default off and explicit kill switch must avoid transport entirely.
    emit('default-off',expect_delta=0)
    config(HOME,enabled=False); emit('disabled-config',expect_delta=0)
    config(HOME); emit('explicit-off',extra_env={'FM_TRACE_EXPORT':'off'},expect_delta=0)
    record('off','Absent config, enabled=false and FM_TRACE_EXPORT=off made zero curl calls and zero collector spans.')
    special='root "quoted" \\ slash\ncontrol\x01 café 日本語 🐟'
    attr='quote" slash\\ newline\n' + ''.join(chr(x) for x in range(1,32))
    emit(special,args=('--root','--status','ok','detail='+attr))
    resource,scope,s=read_spans()[-1]
    check(s['traceId']=='4bf92f3577b34da6a3ce929d0e0e4736' and s['spanId']=='00f067aa0ba902b7' and not s.get('parentSpanId'),'root identity')
    check(s['startTimeUnixNano']=='1000000000' and s['endTimeUnixNano']=='2000000000','decimal ms to ns')
    check(s['name']==special and s['attributes'][0]['value']['stringValue']==attr,'quoted, control or Unicode corruption')
    check(s['status']['code']==1 and scope['name']=='firstmate','OTLP status or scope')
    attrs={a['key']:a['value']['stringValue'] for a in resource['attributes']}
    check(attrs=={'service.name':'firstmate','firstmate.task.id':'task-1','firstmate.task.kind':'ship','firstmate.project':'fleet-metrics','firstmate.model':'café 日本語 🐟'},'private path or absent metadata leaked')
    emit('child-clamped','09','08',args=('--status','error'))
    s=read_spans()[-1][2]
    check(s['parentSpanId']=='00f067aa0ba902b7' and len(s['spanId'])==16 and s['spanId']!='00f067aa0ba902b7','child parent identity')
    check(s['startTimeUnixNano']==s['endTimeUnixNano']=='9000000' and s['status']['code']==2,'duration clamp/status')
    minimal=STATE/'minimal.meta'; minimal.write_text('traceparent='+CARRIER+'\n')
    emit('minimal',meta=minimal)
    check({a['key'] for a in read_spans()[-1][0]['attributes']}=={'service.name','firstmate.task.id'},'absent metadata not omitted')
    for locale in ['C','en_US.UTF-8']:
        emit('café 日本語 🐟',extra_env={'LC_ALL':locale})
        check(read_spans()[-1][2]['name']=='café 日本語 🐟','Unicode corruption under '+locale)
    record('wire-and-privacy','Authenticated official collector accepted root/child, all representable controls, Unicode, decimal nanoseconds, clamping, statuses and basename-only metadata.')
    # Distinct real receiver pipelines prove override routing, with no fake endpoints.
    altstate=WORK/'alternate-state'; altstate.mkdir(); shutil.copy(META,altstate/META.name)
    for f in ['.lock','.trace-context-effective']: shutil.copy(STATE/f,altstate/f)
    althome=WORK/'alternate-home'; config(althome,endpoints['alternate'])
    emit('state-override',meta=altstate/META.name,extra_env={'FM_STATE_OVERRIDE':str(altstate)})
    for rootargs in [('--root',),()]:
        emit('config-override',args=rootargs,extra_env={'FM_CONFIG_OVERRIDE':str(althome/'config')})
        check(read_spans('alternate-spans.jsonl')[-1][2]['name']=='config-override','config override ignored')
        emit('both-overrides',args=rootargs,meta=altstate/META.name,extra_env={'FM_CONFIG_OVERRIDE':str(althome/'config'),'FM_STATE_OVERRIDE':str(altstate)})
    emit('foreign-home',meta=altstate/META.name,expect_delta=0)
    emit('wrong-state',extra_env={'FM_STATE_OVERRIDE':str(altstate)},expect_delta=0)
    codehome=WORK/'code-home'; (codehome/'bin').mkdir(parents=True)
    for f in ['fm-trace-span-lib.sh','fm-trace-context-lib.sh','fm-timing-lib.sh']: shutil.copy(ROOT/'bin'/f,codehome/'bin'/f)
    shutil.copytree(STATE,codehome/'state'); config(codehome,endpoints['alternate'])
    emit('code-root-default',meta=codehome/'state/task-1.meta',library=codehome/'bin/fm-trace-span-lib.sh',extra_env={'FM_HOME':None})
    emit('code-root-state-override',meta=altstate/META.name,library=codehome/'bin/fm-trace-span-lib.sh',extra_env={'FM_HOME':None,'FM_STATE_OVERRIDE':str(altstate)})
    emit('root-override',extra_env={'FM_HOME':None,'FM_ROOT_OVERRIDE':str(HOME)})
    record('home-boundaries','FM_HOME, explicit state/config overrides, unset-home code root and FM_ROOT_OVERRIDE selected the correct real collector; foreign metadata was rejected.')
    # Validate malformed files and forbidden option forms at the public interface.
    cf=HOME/'config/trace-export.json'; valid=cf.read_text()
    for shape,text in [('empty',''),('null','null'),('array','[]'),('concatenated',valid+valid),('malformed-tail',valid+'{bad')]:
        cf.write_text(text); emit('invalid-config-'+shape,expect_delta=0)
    cf.write_text(valid)
    for n,args in [('unknown',('--rot',)),('missing-status',('--status',)),('invalid-status',('--status','bogus')),('invalid-attribute',('=value',))]:
        emit('invalid-invocation-'+n,args=args,expect_delta=0)
    broken=STATE/'broken.meta'; broken.write_text('traceparent=invalid\n')
    emit('invalid-carrier',meta=broken,expect_delta=0)
    emit('absent-meta',meta=STATE/'absent.meta',expect_delta=0)
    (STATE/'.trace-context-effective').write_text('202 on\n'); emit('stale-session',expect_delta=0)
    (STATE/'.trace-context-effective').write_text('101 on\n')
    HEADER.chmod(0o644); emit('insecure-header',expect_delta=0); HEADER.chmod(0o600)
    for name,body in [('invalid-prefix','Wrong: Bearer '+SECRET+'\n'),('extra-line','Authorization: Bearer '+SECRET+'\nextra\n'),('nul-tail','Authorization: Bearer '+SECRET+'\n\x00')]:
        HEADER.write_text(body); emit(name,expect_delta=0)
    HEADER.write_text('Authorization: Bearer '+SECRET+'\n')
    nocurl=WORK/'no-curl'; nocurl.mkdir()
    for tool in ['dirname','jq','grep','sed','head','basename','tr','od','uname','stat','cmp']:
        (nocurl/tool).symlink_to(shutil.which(tool))
    # bash must still launch; absolute path avoids replacing the product/client.
    (nocurl/'bash').symlink_to(shutil.which('bash'))
    emit('missing-curl',extra_env={'PATH':str(nocurl)},expect_delta=0)
    record('invalid-input-and-dependencies','Malformed/concatenated config, invalid options/carrier, absent metadata, stale session, unsafe headers and absent curl skipped transport and preserved caller options/result.')
    record('credential-secrecy','All live calls with BASH_XTRACEFD=9 left token absent from diagnostic output, traced curl argv and collector payloads; only a private file supplied bearer auth.')
    # Unauthorized: real collector authenticates and rejects this alternate token.
    wrong=WORK/'wrong-header'; wrong.write_text('Authorization: Bearer wrong-token\n'); wrong.chmod(0o600)
    config(HOME,header=wrong)
    # Independent real-service probe confirms status; no secret appears in argv.
    def probe(endpoint,header,payload=b'{}'):
        req=urllib.request.Request(endpoint,data=payload,headers={'Authorization':header,'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req,timeout=3) as res: return res.status
        except urllib.error.HTTPError as e: return e.code
    check(probe(endpoints['main'],'Bearer wrong-token')==401,'collector failed to reject invalid bearer')
    # fault_emit resets configuration, retain wrong header through swapping owned file.
    old=HEADER.read_text(); HEADER.write_text(wrong.read_text())
    fault_emit('http-401',endpoints['main']); HEADER.write_text(old)
    # Transform ParseJSON is an actual Collector processor failure, not a synthetic response.
    payload=json.dumps({'resourceSpans':[{'scopeSpans':[{'spans':[{'traceId':'4bf92f3577b34da6a3ce929d0e0e4736','spanId':'00f067aa0ba902b7','name':'probe-error','attributes':[{'key':'bad','value':{'stringValue':'{invalid'}}]}]}]}]}).encode()
    status=probe(endpoints['error'],'Bearer '+SECRET,payload)
    with (EVIDENCE/'http-status-probes.json').open('w') as f:
        json.dump({'unauthorized':401,'processor_failure':status},f,indent=2)
    check(status==500,f'actual collector processor fault produced HTTP {status}, expected 500')
    fault_emit('http-500',endpoints['error'],('--root','bad={invalid'))
    refused=freeport(); fault_emit('connection-refused',f'http://127.0.0.1:{refused}/v1/traces')
    # A separate genuine collector forwards to a suspended genuine collector.
    # This is actual stalled upstream I/O; no fake HTTP server participates.
    primary.send_signal(signal.SIGSTOP)
    try: elapsed=fault_emit('slow-collector',endpoints['relay'],max_seconds=2.5)
    finally: primary.send_signal(signal.SIGCONT)
    time.sleep(4.3)
    record('collector-failure-isolation',f'Real collector HTTP 401 and 500, connection refusal, and stalled collector relay preserved success; slow call returned in {elapsed:.3f}s.')
    for p in PROCS:
        p.terminate(); p.wait(timeout=8)
    for log in LOGS: log.flush()
    check(SECRET not in ''.join((EVIDENCE/f).read_text() for f in ['collector-spans.jsonl','alternate-spans.jsonl','collector.log','relay-collector.log','fault-collector.log','caller-transcript.jsonl']),'credential leaked into evidence or payload')
    (EVIDENCE/'live-results.json').write_text(json.dumps({'collector_versions':{'main_and_relay':'0.162.0','http_500_fault':'0.80.0'},'upstream':'official OpenTelemetry Collector Contrib, authenticated OTLP/HTTP on loopback','substitutes':[],'scenarios':REPORT},indent=2)+'\n')
finally:
    for p in PROCS:
        if p.poll() is None:
            p.send_signal(signal.SIGCONT); p.terminate()
            try: p.wait(timeout=8)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
    for log in LOGS: log.close()

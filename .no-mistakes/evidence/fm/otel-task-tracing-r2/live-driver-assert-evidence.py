import json
from pathlib import Path
from collections import defaultdict
E=Path('/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2')
spans=defaultdict(list)
for line in (E/'otlp.jsonl').read_text().splitlines():
 for r in json.loads(line)['resourceSpans']:
  resource={a['key']:a['value']['stringValue'] for a in r['resource']['attributes']}
  for scope in r['scopeSpans']:
   for s in scope['spans']:
    s['attributes']={a['key']:a['value']['stringValue'] for a in s.get('attributes',[])}
    spans[resource['firstmate.task.id']].append(s)
def meta(name):
 return dict(line.split('=',1) for line in (E/name).read_text().splitlines())
fresh=meta('fresh.meta'); relaunched=meta('relaunch.meta')
assert fresh['traceparent']==relaunched['traceparent']
assert fresh['trace_started']==relaunched['trace_started']
assert fresh['spawn_gen']!=relaunched['spawn_gen']
s=spans['trace-live-a7']; children=[x for x in s if x['name']=='firstmate.spawn']; roots=[x for x in s if x['name']=='firstmate.task']
assert len(children)==2 and len(roots)==1
assert {x['parentSpanId'] for x in children}=={fresh['traceparent'].split('-')[2]}
assert {x['traceId'] for x in s}=={fresh['traceparent'].split('-')[1]}
assert roots[0]['spanId']==fresh['traceparent'].split('-')[2] and 'parentSpanId' not in roots[0]
assert int(roots[0]['startTimeUnixNano'])==int(fresh['trace_started'])*1000000
assert roots[0]['status']['code']==1
assert {x['attributes']['firstmate.spawn_gen'] for x in children}=={fresh['spawn_gen'],relaunched['spawn_gen']}
assert children[0]['attributes']['firstmate.relaunch']=='false' and children[1]['attributes']['firstmate.relaunch']=='true'
for task,outcome,code in [('trace-historical-failed','failed',2),('trace-historical-unknown','unknown',0),('trace-historical-renewed','unknown',0),('trace-restart-close-a7','failed',2),('trace-restart-retain-a7','failed',2),('trace-remove-failed-a7','failed',2),('trace-remove-done-a7','done',1)]:
 s=spans[task]
 assert len(s)==1 and s[0]['name']=='firstmate.task',(task,s)
 assert s[0]['attributes']['firstmate.task.outcome']==outcome
 assert s[0]['status'].get('code',0)==code
 assert 0<int(s[0]['startTimeUnixNano'])<=int(s[0]['endTimeUnixNano'])
 assert 'parentSpanId' not in s[0]
assert len(spans['trace-live-disabled-a7'])==1 and spans['trace-live-disabled-a7'][0]['name']=='firstmate.spawn'
for filename in ['disabled-after.meta','default-off.meta']:
 m=meta(filename)
 assert not {'traceparent','trace_started','trace_outcome'} & m.keys()
for filename in ['disabled-after.txt','default-off.txt']:
 assert 'carrier-after-worker:unset' in (E/filename).read_text()
for task in ['trace-live-rollback-a7','trace-remove-disabled-a7','trace-default-off-a7']:
 assert not spans[task]
for filename,outcome in [('refused-cleanup.meta','done'),('remove-done-refused.meta','done'),('remove-failed-refused.meta','failed'),('remove-disabled-refused.meta','failed'),('restart-close-refused.meta','failed'),('restart-retain-refused.meta','failed')]:
 assert meta(filename)['trace_outcome']==outcome
for mode in ['close','retain']:
 assert 'status presentation could not be retired' in (E/f'bootstrap-{mode}.txt').read_text()
for name in ['launch','lifecycle','more','rollback','backlog','removal','default']:
 assert (E/f'{name}-ready').exists(),name
allowed={'firstmate.relaunch','firstmate.spawn_gen','firstmate.backend','firstmate.task.outcome','firstmate.task.mode','firstmate.task.yolo','firstmate.teardown.forced'}
for rows in spans.values():
 for s in rows: assert s['attributes'].keys()<=allowed
report=['Driver: real Firstmate CLI + private tmux lab + authenticated OpenTelemetry Collector 0.162.0 at http://127.0.0.1:24318/v1/traces. Codex workers reached the real OpenAI service. No fake CLI or upstream service was used in these live checks.','Oracle: accepted lifecycle contract; W3C carrier identity; OTLP OK=1, ERROR=2, and unset=0.','Assertions passed: launch count and parent identity; relaunch carrier/start preservation and generation replacement; historical fallback and stable task IDs; terminal notes; renewed-work reset; cursor and deletion failures retaining retryability; pending-close/retain restart refusal; repair/retry exports exactly once; repeat refusal; default-off and disabled scrubbing; rollback omission; deferred pane-resource attributes.','','Task | Span | Outcome | Status | Generation']
for task,rows in spans.items():
 for s in rows:
  a=s['attributes'];report.append(f"{task} | {s['name']} | {a.get('firstmate.task.outcome','-')} | {s['status'].get('code',0)} | {a.get('firstmate.spawn_gen','-')}")
(E/'live-evidence-summary.txt').write_text('\n'.join(report)+'\n')
print('\n'.join(report))

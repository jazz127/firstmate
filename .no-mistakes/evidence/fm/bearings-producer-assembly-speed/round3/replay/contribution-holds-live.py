from drive import *
h=T/'hold-home'
for d in ['data','state','config','projects']:(h/d).mkdir(parents=True,exist_ok=True)
(h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
(h/'data/backlog.md').write_text('''## In flight

## Queued
- [ ] same-id - Saved contribution hold (repo: sample) (kind: ship) (hold: choose scope) (hold-kind: captain)
- [ ] by-url - Link to saved contribution https://github.com/example/disposable/pull/2 (repo: sample) (kind: captain) (hold: choose route) (hold-kind: captain)
- [ ] deferred - Future call (repo: sample) (kind: ship) (hold: revisit later) (hold-kind: captain) (hold-until: 2099-01-01)
- [ ] blocked - Blocked call blocked-by: missing-work (repo: sample) (kind: ship) (hold: wait) (hold-kind: captain)
- [ ] unrelated - Ordinary queued work (repo: sample) (kind: ship)

## Done
''')
for i,name in enumerate(['same-id','url-owner','deferred','blocked','unrelated'],1):
 d=h/'data'/name;d.mkdir(exist_ok=True)
 (d/'contributions.json').write_text(json.dumps({'schema':'fm-contributions.v1','task':name,'records':[{'url':f'https://github.com/example/disposable/pull/{i}','kind':'pr','pending':[],'seen':[],'checked_at':None,'error':None,'observation':None,'verdict':None}]}))
o,_=run('contribution-holds',[R/'bin/fm-bearings-snapshot.sh','--json'],h)
c=o['contributions']
assert {r['task'] for r in c['captain']}=={'same-id','by-url'},c
assert c['counts']['fleet']==3,c
input_model,_=run('contribution-holds-input',[R/'bin/fm-fleet-snapshot.sh','--contribution-input'],h)
input_path=h/'input.json';input_path.write_text(json.dumps(input_model))
raw,_=run('contribution-holds-all',[R/'bin/fm-contributions.sh','snapshot',input_path,'--all'],h)
assert any(r['url'].endswith('/2') and r['actor']=='captain' and set(r['tasks'])=={'url-owner','by-url'} for r in raw['rows']),raw
assert {r['id'] for r in o['decisions_open']}=={'same-id','by-url'},o['decisions_open']
assert {'deferred','blocked'} <= {r['id'] for r in o['gates']},o['gates']
(E/'contribution-holds-results.json').write_text(json.dumps({'driver':'real fm-bearings-snapshot.sh --json, isolated durable backlog and saved contributions; default cache-only product contract requires no upstream calls','oracle':'live captain holds match saved contribution by task identity or explicit URL; future and blocked holds remain gates and never produce captain contribution rows','captain_tasks':sorted(r['task'] for r in c['captain']),'fleet_count':c['counts']['fleet']},indent=2))
print('Live same-id and explicit-URL hold matching passed; dated, blocked, and unrelated records do not create captain contribution rows.')

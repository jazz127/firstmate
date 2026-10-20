from drive import *
h=T/'decision-home'
for d in ['data','state','config','projects']:(h/d).mkdir(parents=True,exist_ok=True)
(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
(h/'state/worker.meta').write_text(f'kind=secondmate\nmode=secondmate\nharness=codex\nbackend=tmux\nwindow=absent:worker\nhome={T}/mate-1\nworktree={T}/mate-1\n')
for name in ['z-last','café notes','a\\b']:
 d=h/'data'/name;d.mkdir(exist_ok=True);(d/'report.md').write_text('# Completed report\n')
s=h/'state/worker.status'
initial='needs-decision [at=10:30] [key=api]: choose café\tpath  \nblocked: [key=network] awaiting service\nresolved [key=network]: fixed\nneeds-decision [key=invalid/slug]: ignore\nworking [key=phase]: unrelated activity\ndone: unrelated secondmate task\n'
s.write_text(initial)
def task(label):
 o,_=run(label,[R/'bin/fm-fleet-snapshot.sh','--json'],h)
 assert {r['id'] for r in o['scout_reports']}=={'z-last','café notes','a\\b'}
 return o['tasks'][0]
a=task('decision-cold');assert a['hints']['open_decisions']==[{'key':'api','verb':'needs-decision','summary':'choose café\tpath  '}]
with s.open('a') as f:f.write('captain-held [key=api]: durable hold\n')
a=task('decision-warm-append');assert a['hints']['open_decisions']==[]
s.write_text(initial.replace('api','sql'))
a=task('decision-rewrite');assert a['hints']['open_decisions']==[{'key':'sql','verb':'needs-decision','summary':'choose café\tpath  '}]
p=h/'state/worker.meta';p.write_text(p.read_text().replace('kind=secondmate','kind=ship'))
a=task('decision-ship-terminal');assert a['hints']['open_decisions']==[]
(E/'decision-live-results.json').write_text(json.dumps({'cold':'one api key preserved across unrelated secondmate done; malformed key rejected; café, tabs and trailing spaces preserved','warm_append':'captain-held closes api','rewrite':'same-key-width prefix rewrite reopens sql rather than stale cached api','ship_terminal':'ship done clears decisions','report_ids':['z-last','café notes','a\\b'],'driver':'real bin/fm-fleet-snapshot.sh --json with isolated durable data; real tmux directed to absent private socket; no substitutes'},ensure_ascii=False,indent=2))
print('Decision cursor, terminal behavior and special-character report ids verified.')

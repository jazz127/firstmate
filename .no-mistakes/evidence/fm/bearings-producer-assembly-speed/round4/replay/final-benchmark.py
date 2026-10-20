from drive import *
h=T/'fleet';metrics=[];models={}
def durable_hashes():
 return {str(p.relative_to(h)):hashlib.sha256(p.read_bytes()).hexdigest() for d in ['data','config','state'] for p in (h/d).rglob('*') if p.is_file() and 'secondmate-summary-cache' not in p.parts and not p.name.endswith('.snapshot-open-decisions-cursor')}
durable_before=durable_hashes()
for label,code in [('benchmark-base',T/'base'),('benchmark-target-cold',R)]+[(f'benchmark-target-warm-{i}',R) for i in range(1,8)]:
 if label=='benchmark-target-cold':
  for p in (h/'state').glob('.*.snapshot-open-decisions-cursor'):p.unlink()
  c=h/'state/secondmate-summary-cache'
  if c.exists():shutil.rmtree(c)
 obj,secs=run(label,[code/'bin/fm-bearings-snapshot.sh','--json'],h)
 models[label]=obj;metrics.append({'command':str(code/'bin/fm-bearings-snapshot.sh')+' --json','label':label,'seconds':round(secs,3)})
 assert len(obj['secondmates'])==9 and all(r['freshness']=='fresh' and r['provenance']=='structured-home' for r in obj['secondmates'])
 assert obj['contributions']['known']==813
 assert obj['contributions']['unreadable_records']==0
assert all(obj==models['benchmark-base'] for obj in models.values()), 'fm-bearings.v1 projection drift'
fleet,secs=run('benchmark-canonical',[R/'bin/fm-fleet-snapshot.sh','--json'],h)
assert len(fleet['tasks'])==9 and len(fleet['scout_reports'])==813
assert {r['id'] for r in fleet['scout_reports']}=={f'contribution-{i:04d}' for i in range(1,814)}
assert all(r['provenance']['selected']=='structured-home' for r in fleet['secondmate_current']['records'])
assert all(t['hints']['open_decisions']==[{'key':'keep','verb':'needs-decision','summary':'preserve this choice'}] for t in fleet['tasks'])
target=[r['seconds'] for r in metrics if r['label'].startswith('benchmark-target')]
result={'threshold_seconds':5,'source_of_threshold':'author acceptance intent: target under 5 seconds','dataset':{'secondmates':9,'local_secondmates':6,'real_ssh_secondmates':3,'saved_contribution_records_in_primary':813,'report_pointers_in_primary':813,'status_lines_per_parent_secondmate':84},'metrics':metrics,'minimum_target_seconds':min(target),'median_target_seconds':sorted(target)[len(target)//2],'threshold_met':all(x<5 for x in target),'projection_equal_to_base':True,'canonical_oracle':'813 explicit report ids and nine surviving keep decisions from generated durable records; independently verified valid structured-home provenance','speedup_from_base_percent':round(100*(1-sorted(target)[len(target)//2]/metrics[0]['seconds']),1)}
(E/'benchmark-results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result),flush=True)

assert durable_before==durable_hashes(), 'snapshot modified durable primary state beyond documented observational caches'
(E/'durable-state-check.json').write_text(json.dumps({'unchanged':True,'files':len(durable_before),'excluded':'documented secondmate-summary-cache and snapshot-open-decisions-cursor observational caches'},indent=2))

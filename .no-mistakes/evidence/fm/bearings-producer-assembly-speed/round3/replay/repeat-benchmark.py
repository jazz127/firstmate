from drive import *
h=T/'fleet';rows=[]
expected=json.loads((E/'benchmark-base.json').read_text())
for i in range(1,6):
 obj,secs=run('repeat-target-'+str(i),[R/'bin/fm-bearings-snapshot.sh','--json'],h)
 assert obj==expected, 'projection drift'
 assert len(obj['secondmates'])==9 and all(r['freshness']=='fresh' for r in obj['secondmates'])
 rows.append({'label':'repeat-target-'+str(i),'seconds':round(secs,3),'exit':0})
result={'driver':'real bin/fm-bearings-snapshot.sh --json; six local homes and three real SSH homes; no substitutes','threshold_seconds':5,'metrics':rows,'threshold_met':all(r['seconds']<5 for r in rows),'projection_equal_to_base':True}
(E/'repeat-benchmark-results.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result),flush=True)

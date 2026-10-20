from drive import *
h=T/'fleet';calls=T/'ssh-calls.log';results=[]
def snapshot(label,extra=None):
 calls.write_text('')
 obj,secs=run(label,[R/'bin/fm-bearings-snapshot.sh','--json'],h,extra)
 count=len(calls.read_text().splitlines())
 results.append({'label':label,'seconds':secs,'ssh_reads':count,'secondmates':obj['secondmates']})
 assert count==3, f'{count} SSH reads instead of one per remote home'
 return obj
fresh=snapshot('remote-fresh')
assert len(fresh['secondmates'])==9
assert all(x['freshness']=='fresh' for x in fresh['secondmates'])
assert all(x['provenance']=='structured-home' for x in fresh['secondmates'])
# Freeze the real SSH server to exercise deadline cancellation and cached ledgers.
subprocess.run(['docker','pause','fm-bearings-gate-round3'],check=True,capture_output=True)
try:
 cached=snapshot('remote-frozen-cache')
 assert {x['id'] for x in cached['secondmates'] if x['freshness']=='cached'}=={'mate-7','mate-8','mate-9'}
 assert all(x['provenance']=='structured-home-cache' for x in cached['secondmates'] if x['id'] in {'mate-7','mate-8','mate-9'})
finally:subprocess.run(['docker','unpause','fm-bearings-gate-round3'],check=True,capture_output=True)
# Remove remote ledgers and cache: the product must disclose unknowns, never infer work.
cache=h/'state/secondmate-summary-cache';shutil.rmtree(cache)
ledger=T/'mate-7/state/home-summary.json';saved=ledger.read_bytes();ledger.unlink()
try:
 missing=snapshot('remote-missing-ledger')
 row=next(x for x in missing['secondmates'] if x['id']=='mate-7')
 assert row['state']=='unknown' and row['provenance']=='parent-event-fallback'
 assert 'missing, unreadable, or invalid' in row['reason']
 assert not ledger.exists(), 'reader unexpectedly computed or wrote a missing remote ledger'
 ledger.write_text('{not-json')
 invalid=snapshot('remote-invalid-ledger')
 row=next(x for x in invalid['secondmates'] if x['id']=='mate-7')
 assert row['state']=='unknown' and row['provenance']=='parent-event-fallback'
finally:ledger.write_bytes(saved)
# Cap applied before sampling: sorted mate-1 and mate-2 are local, so no SSH is permitted.
calls.write_text('')
obj,secs=run('remote-cap',[R/'bin/fm-bearings-snapshot.sh','--json'],h,{'FM_SNAPSHOT_SECONDMATES':'2'})
assert {r['id'] for r in obj['secondmates']}=={'mate-1','mate-2'} and not calls.read_text()
results.append({'label':'remote-cap','seconds':secs,'ssh_reads':0})
(E/'remote-live-results.json').write_text(json.dumps({'driver':'real bin/fm-bearings-snapshot.sh --json -> fm-on.sh -> real /usr/bin/ssh -> disposable Linux OpenSSH server -> real fm-remote-entrypoint.sh and remote job worker -> fm-remote-file.sh; no substitutes','results':results},ensure_ascii=False,indent=2))
print('Real SSH freshness, shared deadline/cache, missing/invalid ledger and cap behavior verified.',flush=True)

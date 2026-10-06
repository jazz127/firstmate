import importlib.util, contextlib, io, shutil, subprocess, json
from pathlib import Path
spec=importlib.util.spec_from_file_location('driver',Path(__file__).with_name('drive-quota.py'))
d=importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
source=d.LAB/'home with spaces/projects/quota-axi'
remote=subprocess.check_output(['git','ls-remote','https://github.com/jazz127/quota-axi.git','refs/heads/house'],env=d.base,text=True).split()[0]
subject=subprocess.check_output(['git','-C',str(source),'show','-s','--format=%s','HEAD'],env=d.base,text=True).strip()
assert subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],env=d.base,text=True).strip()==remote
summary={'upstream':'https://github.com/jazz127/quota-axi.git','independent_house_ref':remote,'subject':subject,'cases':[],'isolation':'Disposable empty HOME; sandbox denies operator home and security executable. Real quota-axi and GitHub git fetch; no CLI or upstream stubs. Quota account cards unavailable, not tested as live provider readings.'}
shutil.copyfile(d.LAB/'isolation.sb',d.EVIDENCE/'isolation.sb')
def run(name,**kw):
    with contextlib.redirect_stdout(io.StringIO()): text,result=d.drive(name,**kw)
    summary['cases'].append({k:v for k,v in result.items() if k!='visible'})
    print(name+': '+str(result['exit'])+'; '+next((x.strip() for x in result['visible'].splitlines() if x.startswith('House tip:')),'no house tip'),flush=True)
    return text,result

def expect_house(text,result):
    assert result['exit']==0, result
    assert 'House tip: '+remote[:7]+' '+subject in text, text
    assert 'clone is absent' not in text
    assert 'quota-axi executable: /opt/homebrew/bin/quota-axi' in text
    assert 'quota-axi ·' in text
    assert 'zero-sized' not in text

before,b=run('before-fallback',script=d.SCRIPT.with_name('before.sh'))
assert 'clone is absent (/projects/quota-axi)' in before
for name,changes in [('unset-home',{}),('empty-home',{'FM_HOME':'','FM_QUOTA_CLONE':''})]:
    t,r=run(name,changes=changes); expect_house(t,r)
t,r=run('loop-two-frames',changes={'FM_QUOTA_TAB_INTERVAL':'1'},mode='loop',frames=2)
assert r['frames']==2,r
assert t.count('House tip: '+remote[:7]+' '+subject)==2,t
assert 'interval: 1 seconds' in t
alt=d.LAB/'explicit-home'
(alt/'projects').mkdir(parents=True, exist_ok=True)
altclone=alt/'projects/quota-axi'
source.rename(altclone)
try:
    t,r=run('missing-script-home-clone')
    assert r['exit']==0
    assert 'clone is absent ('+str(source)+')' in t
    t,r=run('explicit-home',changes={'FM_HOME':str(alt)},script=d.ROOT/'bin/fm-quota-tab.sh'); expect_house(t,r)
    t,r=run('explicit-clone-precedence',changes={'FM_HOME':str(d.LAB/'wrong-home'),'FM_QUOTA_CLONE':str(altclone)},script=d.ROOT/'bin/fm-quota-tab.sh'); expect_house(t,r)
    missing=d.LAB/'deliberately-absent-clone'
    t,r=run('missing-explicit-clone-precedence',changes={'FM_HOME':str(alt),'FM_QUOTA_CLONE':str(missing)},script=d.ROOT/'bin/fm-quota-tab.sh')
    assert r['exit']==0
    assert 'clone is absent ('+str(missing)+')' in t
    assert 'House tip: '+remote[:7] not in t
finally:
    altclone.rename(source)
summary['result']='All current-product scenarios passed; pre-fallback renderer reproduced the missing /projects/quota-axi defect.'
(d.EVIDENCE/'scenario-results.json').write_text(json.dumps(summary,indent=2))
print(summary['result'])

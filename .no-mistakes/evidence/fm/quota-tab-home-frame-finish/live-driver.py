import os, pathlib, subprocess, pty, fcntl, termios, struct, select, time, json, hashlib, html
import pyte
root = pathlib.Path.cwd()
lab = root / '.quota-test-run'
evidence = pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M487Y8VV6T9T98TTKWE05EAK')
home = lab / 'script home'
clone = home / 'projects/quota-axi'
env = {'HOME':str(lab/'user'), 'XDG_CONFIG_HOME':str(lab/'config'), 'XDG_CACHE_HOME':str(lab/'cache'), 'CODEX_HOME':str(lab/'codex'), 'PATH':str(lab/'launcher')+':/opt/homebrew/bin:/usr/bin:/bin', 'TERM':'xterm-256color','GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','FM_QUOTA_TAB_INTERVAL':'17','LANG':'en_US.UTF-8'}

def git(*args):
    return subprocess.check_output(['git','-C',str(clone),*args],env=env,text=True).strip()

expected_sha = subprocess.check_output(['git','ls-remote','https://github.com/jazz127/quota-axi.git','refs/heads/house'],env=env,text=True).split()[0]
expected_short = expected_sha[:7]
expected_subject = git('show','-s','--format=%s','jazz127/house')
assert git('rev-parse','jazz127/house') == expected_sha

def tree_hash():
    d = hashlib.sha256()
    for p in sorted(clone.rglob('*')):
        if '.git' in p.relative_to(clone).parts or not p.is_file(): continue
        d.update(str(p.relative_to(clone)).encode()); d.update(p.read_bytes())
    return d.hexdigest()

before_hash = tree_hash()
before_status = git('status','--porcelain')

cases = [
    ('unset-from-unrelated-directory', home/'bin/fm-quota-tab.sh', {}, True),
    ('empty-home-and-override', home/'bin/fm-quota-tab.sh', {'FM_HOME':'','FM_QUOTA_CLONE':''}, True),
    ('explicit-home', root/'bin/fm-quota-tab.sh', {'FM_HOME':str(home)}, True),
    ('clone-overrides-conflicting-home', root/'bin/fm-quota-tab.sh', {'FM_HOME':str(lab/'nonexistent'), 'FM_QUOTA_CLONE':str(clone)}, True),
    ('missing-home-clone-diagnostic', lab/'missing-home/bin/fm-quota-tab.sh', {}, False)
]
results=[]
for name, script, overrides, has_clone in cases:
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',40,132,0,0))
    child_env = dict(env,**overrides)
    proc = subprocess.Popen(['bash',str(script),'once'],cwd=lab/'elsewhere',env=child_env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
    os.close(slave)
    chunks=[]; deadline=time.monotonic()+30
    try:
        while time.monotonic()<deadline:
            ready,_,_=select.select([master],[],[],0.1)
            if ready:
                try:
                    data=os.read(master,65536)
                    if not data: break
                    chunks.append(data)
                except OSError: break
            elif proc.poll() is not None: break
        if proc.poll() is None:
            proc.wait(timeout=5)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid,15); proc.wait(timeout=5)
        os.close(master)
    raw=b''.join(chunks).decode('utf-8','replace')
    screen=pyte.Screen(132,40); pyte.Stream(screen).feed(raw)
    visible='\n'.join(screen.display).rstrip()
    (evidence/(name+'.ansi')).write_text(raw)
    (evidence/(name+'.txt')).write_text(visible+'\n')
    assert proc.returncode == 0,(name,proc.returncode,visible)
    assert 'Codex profile credentials missing' in visible,(name,visible)
    assert 'terminal reported a zero-sized grid' not in visible
    assert 'quota-axi view of the fleet house line' in visible
    if has_clone:
        assert 'House tip: '+expected_short in visible,(name,expected_sha,visible)
        assert expected_subject in visible,(name,expected_subject,visible)
        assert 'clone is absent' not in visible,(name,visible)
    else:
        assert 'clone is absent ('+str(lab/'missing-home/projects/quota-axi')+')' in ''.join(line.rstrip() for line in visible.splitlines()),(name,visible)
    assert 'interval: 17 seconds' in visible
    # Preserve the terminal's actual cell grid and color attributes as rendered HTML.
    rendered=[]
    for y in range(screen.lines):
        row=[]
        for x in range(screen.columns):
            cell=screen.buffer[y][x]
            palette={'default':'#d9e1e8','black':'#111111','red':'#e77373','green':'#8fcf93','brown':'#d4bc73','blue':'#83aff1','magenta':'#cfa0ef','cyan':'#73cfd0','white':'#eeeeee'}
            fg=palette.get(cell.fg,'#'+cell.fg if len(cell.fg)==6 else '#d9e1e8')
            row.append('<span style="color:'+fg+('font-weight:bold;' if cell.bold else ';')+'">'+html.escape(cell.data)+'</span>')
        rendered.append(''.join(row))
    document='<!doctype html><meta charset="utf-8"><title>'+name+'</title><style>body{background:#121a23;color:#d9e1e8;padding:24px}pre{font:14px/1.35 ui-monospace,Menlo,monospace;white-space:pre}</style><pre>'+ '\n'.join(rendered)+'</pre>'
    (evidence/(name+'.html')).write_text(document)
    results.append({'name':name,'exit':proc.returncode,'cwd':str(lab/'elsewhere'),'command':['bash',str(script),'once'],'env_overrides':overrides,'observed_house_line':next(l.strip() for l in visible.splitlines() if 'House tip:' in l),'html':str(evidence/(name+'.html'))})
    print(name+': '+results[-1]['observed_house_line'])
assert tree_hash()==before_hash,'clone working files were changed'
assert git('status','--porcelain')==before_status=='','clone worktree became dirty'
report={'upstream':'https://github.com/jazz127/quota-axi.git','house_sha':expected_sha,'house_subject':expected_subject,'terminal_size':[40,132],'quota_launcher':'exec /opt/homebrew/bin/quota-axi --provider codex --profile-only --no-credential-refresh "$@"','credential_profile':'Empty disposable CODEX_HOME; no provider API quota or real-account proof claimed. No substitute service or synthetic quota response.','before_after_working_file_sha256':before_hash,'cases':results}
(evidence/'live-validation.json').write_text(json.dumps(report,indent=2)+'\n')
print('Clone checked-out file digest unchanged; real GitHub house fetch completed; all target scenario assertions passed.')

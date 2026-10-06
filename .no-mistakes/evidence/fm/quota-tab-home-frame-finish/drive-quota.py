import os, sys, subprocess, pty, fcntl, termios, struct, select, time, signal, html, json
from pathlib import Path
ROOT=Path('/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M485WZXY5YFW1E8JX78M2KFK')
LAB=ROOT/'.quota-validation-tmp'
EVIDENCE=Path(__file__).parent
sys.path.insert(0,str(LAB/'pydeps'))
import pyte
USER=LAB/'empty-user'
SCRIPT=LAB/'home with spaces/bin/fm-quota-tab.sh'
base={'HOME':str(USER),'PATH':'/opt/homebrew/bin:/usr/bin:/bin','TERM':'xterm-256color','LANG':'en_US.UTF-8', 'XDG_CONFIG_HOME':str(USER/'.config'),'XDG_CACHE_HOME':str(USER/'.cache'),'XDG_DATA_HOME':str(USER/'.local/share'),'CLAUDE_CONFIG_DIR':str(USER/'.claude'),'CODEX_HOME':str(USER/'.codex'),'QUOTA_AXI_CODEX_HOMES':'[]','PI_CODING_AGENT_DIR':str(USER/'.pi/agent'),'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null', 'TMPDIR':str(LAB)}

def drive(name, changes=None, script=SCRIPT, mode='once', frames=1):
    env=base.copy(); env.update(changes or {})
    master,slave=pty.openpty()
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',48,140,0,0))
    def setup():
        os.setsid(); fcntl.ioctl(0,termios.TIOCSCTTY,0)
    command=['/usr/bin/sandbox-exec','-f',str(LAB/'isolation.sb'),'/bin/bash',str(script),mode]
    proc=subprocess.Popen(command,cwd=LAB/'other-cwd',env=env,stdin=slave,stdout=slave,stderr=slave,preexec_fn=setup)
    os.close(slave); data=b''; deadline=time.monotonic()+45
    try:
        while time.monotonic()<deadline:
            ready,_,_=select.select([master],[],[],0.2)
            if ready:
                try: chunk=os.read(master,65536)
                except OSError: break
                if not chunk: break
                data+=chunk
                if mode=='loop' and data.count(b'Refreshed:')>=frames:
                    proc.terminate()
            elif proc.poll() is not None: break
        if proc.poll() is None:
            proc.terminate()
        code=proc.wait(timeout=5)
    finally: os.close(master)
    text=data.decode('utf-8','replace')
    (EVIDENCE/(name+'.ansi')).write_bytes(data)
    screen=pyte.Screen(140,48); pyte.Stream(screen).feed(text)
    visible='\n'.join(screen.display).rstrip()
    (EVIDENCE/(name+'.txt')).write_text(visible+'\n')
    # Render the captured terminal grid, retaining real TUI colors.
    palette={'default':'#ddd','black':'#111','red':'#e66','green':'#7c9','brown':'#dc8','blue':'#8af','magenta':'#c9f','cyan':'#6dd','white':'#eee','brightblack':'#888','brightred':'#f88','brightgreen':'#afa','brightbrown':'#fea','brightblue':'#acf','brightmagenta':'#ecf','brightcyan':'#aff','brightwhite':'#fff'}
    lines=[]
    for y in range(48):
        row=[]
        for x in range(140):
            c=screen.buffer[y][x]
            color=palette.get(c.fg,'#'+c.fg if len(c.fg)==6 else '#ddd')
            row.append('<span style="color:'+color+';'+('font-weight:bold;' if c.bold else '')+'">'+html.escape(c.data)+'</span>')
        lines.append(''.join(row))
    (EVIDENCE/(name+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>'+html.escape(name)+'</title><style>body{background:#12151c;color:#ddd;margin:24px}pre{font:14px/1.3 monospace;white-space:pre}</style><pre>'+ '\n'.join(lines)+'</pre>')
    result={'name':name,'exit':code,'command':command,'cwd':str(LAB/'other-cwd'),'FM_HOME':env.get('FM_HOME','<unset>'),'FM_QUOTA_CLONE':env.get('FM_QUOTA_CLONE','<unset>'),'frames':text.count('Refreshed:'),'visible':visible}
    (EVIDENCE/(name+'.json')).write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2),flush=True)
    return text,result

if __name__=='__main__': drive('unset-home')

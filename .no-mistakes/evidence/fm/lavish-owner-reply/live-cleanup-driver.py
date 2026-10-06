exec(open('.test-live/live.py').read().split('try:\n    for version')[0])
try:
    for version in ['modern','legacy']:
        name=version+'-unlink-denied';env,art,id=prepare(name,version)
        lavish(env,'arm',art)
        wait(lambda:not text_contains('Your agent is not listening.'),'actual Lavish poll connected')
        home=Path(env['FM_HOME']);reg=home/'state/procevent';mode=reg.stat().st_mode&0o777
        claim=(Path(env['FM_PROCEVENT_CLAIM_ROOT'])/(id+'.claim')).read_text().splitlines()
        out=reg/('.'+id+'.'+claim[2]+'.output')
        try:
            reg.chmod(0o500)
            send('Feedback committed while staging deletion is denied.')
            wait_capture(env,id,1)
            wait(lambda:out.exists() and out.stat().st_size==0,'committed staging emptied despite unlink denial')
            LOG.write('Actual OS permission denial: registry mode 0500, committed result count 1, staging still exists with length 0\n')
            assert len(captures(env,id))==1
            wait(lambda:not (Path(env['FM_PROCEVENT_CLAIM_ROOT'])/(id+'.claim')).exists(),'original runner completed')
        finally:reg.chmod(mode)
        reply=W/(name+'.md');reply.write_text('The committed feedback is preserved.\n')
        lavish(env,'arm',art,'--agent-reply-file',reply)
        wait(lambda:text_contains('The committed feedback is preserved.'),'reply after failed staging deletion')
        assert len(captures(env,id))==1,'Reply re-arm captured committed staging again'
        send('Next feedback after cleanup failure.')
        wait(lambda:any('Next feedback after cleanup failure.' in f.read_text() for f in captures(env,id)),'normal feedback continues')
        assert sum('Feedback committed while staging deletion is denied.' in f.read_text() for f in captures(env,id))==1
        for f in captures(env,id):shutil.copyfile(f,E/(name+'-'+f.name))
        screenshot(name)
        result(name+' retains one committed feedback result, does not replay staging on reply re-arm, and accepts subsequent feedback')
        lavish(env,'retire',art);run(['lavish-axi','end',art],env=env)
finally:
    for home in ACTIVE:
        env=BASE.copy();env['FM_HOME']=str(home);pe(env,'sweep-home',ok=False)
    LOG.close()

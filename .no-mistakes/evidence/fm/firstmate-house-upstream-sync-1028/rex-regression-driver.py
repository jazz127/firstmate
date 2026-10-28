import io,os,pathlib,shutil,subprocess,tarfile
root=pathlib.Path.cwd(); tmp=root/'.test-phase-disposable'
evidence=pathlib.Path(__file__).resolve().parent
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_'): env.pop(k,None)
env.update(TMPDIR=str(tmp/'tmp'),FM_HOME=str(tmp/'home'),FM_TEST_ONLY='test_marks_clear_preserves_failed_operations_for_retry')
source=(root/'tests/fm-backend-rex.test.sh').read_text()
observer='''
    printf 'case=%s phase=first exit=%s emitted_hex=' "$scenario" "$rc"
    od -An -tx1 "$MARK_TTY" | tr -d ' \\n'
    printf ' retained_caches='
    for observed in "$mark_cache" "$progress_cache" "$tint_cache"; do [ ! -f "$observed" ] || printf '%s ' "${observed##*/}"; done
    printf '\\n'
'''
source=source.replace('    expect_code 1 "$rc" "$scenario must report the failed operation"',observer+'    expect_code 1 "$rc" "$scenario must report the failed operation"')
source=source.replace('    [ ! -e "$mark_cache" ] && [ ! -e "$progress_cache" ] && [ ! -e "$tint_cache" ] || fail "$scenario retained a cache after successful cleanup"','''    printf 'case=%s phase=retry exit=0 emitted_hex=' "$scenario"
    od -An -tx1 "$MARK_TTY" | tr -d ' \\n'
    printf '\\n'
    [ ! -e "$mark_cache" ] && [ ! -e "$progress_cache" ] && [ ! -e "$tint_cache" ] || fail "$scenario retained a cache after successful cleanup"
''')
for mode in ['before','after']:
    dest=tmp/('rex-'+mode); dest.mkdir(); (dest/'tests').mkdir()
    for name in ['lib.sh','git-config-helpers.sh']:
        shutil.copyfile(root/'tests'/name,dest/'tests'/name)
    (dest/'tests/fm-backend-rex.test.sh').write_text(source)
    if mode=='before':
        blob=subprocess.check_output(['git','archive','HEAD^','bin'])
        with tarfile.open(fileobj=io.BytesIO(blob)) as tf: tf.extractall(dest,filter='data')
    else: (dest/'bin').symlink_to(root/'bin',target_is_directory=True)
    p=subprocess.run(['bash',str(dest/'tests/fm-backend-rex.test.sh')],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    output=('Rex clear regression '+mode+' fix; stateful fake Rex and simulated TTY; product validation remains untested.\n'+p.stdout+'\nexit='+str(p.returncode)+'\n').replace(str(root),'<worktree>')
    (evidence/('rex-regression-'+mode+'.txt')).write_text(output)
    print(output)
    assert p.returncode == (1 if mode=='before' else 0), mode

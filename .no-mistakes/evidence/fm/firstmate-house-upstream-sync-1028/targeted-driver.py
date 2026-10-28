import concurrent.futures, json, os, pathlib, signal, subprocess, time
root=pathlib.Path.cwd()
evidence=pathlib.Path(__file__).resolve().parent
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','REX_SESSION','REX_BLOCK','REX_SERVER']:
        env.pop(k,None)
env.update(TMPDIR=str(root/'.test-phase-disposable/tmp'), FM_HOME=str(root/'.test-phase-disposable/home'))
cases=[
('rex-retry','fm-backend-rex','test_marks_clear_preserves_failed_operations_for_retry',180),
('rex-clear','fm-backend-rex','test_marks_clear_removes_records_and_caches',180),
('rex-converge','fm-backend-rex','test_marks_producer_converges_and_notifies_once',180),
('rex-protocol','fm-backend-rex','test_mark_progress_tint_and_alert_sequences',180),
('rex-off','fm-backend-rex','test_marks_are_off_by_default',90),
('descendant-homes','fm-teardown-endpoint-safety','test_paseo_tern_descendants_use_the_owning_home',180),
('paseo-close-failure','fm-backend-paseo','test_kill_refuses_when_terminal_kill_fails',90),
('paseo-unknown','fm-backend-paseo','test_kill_keeps_workspace_when_inventory_unreadable',90),
('wedge-poll-oracle','fm-watch-wedge-cap','test_poll_progress_rejects_stalls_and_exits',90),
('wedge-ack-failure','fm-watch-wedge-cap','test_cycle_acknowledgement_failures',90),
('wedge-disabled','fm-watch-wedge-cap','test_wedge_cap_disabled_by_default',180),
('wedge-cap-release','fm-watch-wedge-cap','test_wedge_cap_expires_after_horizon',420),
]
def run(case):
    label,suite,selector,bound=case
    cmd=['bin/fm-test-run.sh','--per-script-timeout-secs',str(bound),f'tests/{suite}.test.sh']
    start=time.monotonic()
    p=subprocess.Popen(cmd,env=dict(env,FM_TEST_ONLY=selector),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        out,_=p.communicate(timeout=bound+40)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGTERM)
        try: out,_=p.communicate(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL); out,_=p.communicate()
    text=out.decode(errors='replace').replace(str(root),'<worktree>')
    (evidence/(label+'.log')).write_text(text)
    result=dict(label=label,command='FM_TEST_ONLY='+selector+' '+' '.join(cmd),exit=p.returncode,seconds=round(time.monotonic()-start,1),log=label+'.log')
    print(json.dumps(result),flush=True)
    return result
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(run,cases))
(evidence/'targeted-results.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(any(r['exit']!=0 for r in results))

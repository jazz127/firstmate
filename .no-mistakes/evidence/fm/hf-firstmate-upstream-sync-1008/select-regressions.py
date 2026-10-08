from pathlib import Path

# Preserve the existing behavioral functions and their setup; replace only
# suite-level dispatch so the canonical runner executes the scoped regressions.
specs = [
    ('fm-pending-reply.test.sh', 'test_normal_correlated_reply_resolves_once', ['test_another_mates_echo_cannot_resolve']),
    ('fm-watch-arm.test.sh', 'test_attached_arm_reports_the_delivered_wake', ['test_opencode_arm_plugin_decides_with_the_shared_predicate']),
    ('fm-supervision-host.test.sh', 'test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main', ['test_successor_left_at_the_turn_survives_the_hook_process_group_teardown', 'test_pass_through_successor_survives_the_hook_process_group_teardown']),
    ('fm-test-fixtures.test.sh', 'test_git_config_isolation || fail "Git fixture config isolation"', ['test_agent_standin_survives_a_multicall_sleep']),
]
for filename, dispatch, functions in specs:
    source = Path('tests', filename).read_text()
    marker = '\n' + dispatch + '\n'
    assert marker in source, filename
    destination = Path('tests', 'fm-gate-selected-' + filename[3:])
    destination.write_text(source.split(marker, 1)[0] + '\n' + '\n'.join(functions) + '\n')
    print(f'{destination}: {functions}')

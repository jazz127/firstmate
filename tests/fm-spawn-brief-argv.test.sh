#!/usr/bin/env bash
# The launch prompt must let a worker read its brief without copying it into argv.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

tmp=$(fm_test_tmproot fm-spawn-brief-argv)
home=$tmp/home
project=$tmp/project
worktree=$tmp/worktree
launch_log=$tmp/launch.log
args_log=$tmp/args.log
fakebin=$(fm_test_make_spawn_fakebin "$tmp/fake")
fm_test_spawn_home "$home" codex
fm_git_worktree "$project" "$worktree" brief-argv
fm_test_spawn_brief "$home" brief-argv 'Stop my development server with pkill -f wrangler dev.'

cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_TEST_ARGS_LOG"
SH
chmod +x "$fakebin/codex"

out=$(FM_FAKE_LAUNCH_LOG="$launch_log" fm_test_run_spawn \
  "$home" "$worktree" "$fakebin" brief-argv "$project" --mode no-mistakes --yolo off)
expect_code 0 "$?" "codex spawn failed: $out"

FM_TEST_ARGS_LOG="$args_log" PATH="$fakebin:$PATH" bash -c "$(cat "$launch_log")" \
  || fail "could not execute the staged launch with the argv capture harness"
assert_no_grep 'pkill -f wrangler dev' "$args_log" "launch brief leaked into worker argv"
assert_grep 'launch-brief.md' "$args_log" "worker argv did not name its launch brief"
pass "worker argv contains a brief pointer rather than the brief text"

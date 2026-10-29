"""Exercise the actual pause/send/handoff CLIs with existing synthetic session fixtures."""
import os
from pathlib import Path
import subprocess

root = Path.cwd()
fixture = (root / "tests/fm-secondmate-restart.test.sh").read_text()
fixture = fixture.split("\ntest_pause_authorizes_before_publishing_intent\n", 1)[0]
for helper in ("lib.sh", "t3-fake-lib.sh"):
    fixture = fixture.replace('. "$(dirname "${BASH_SOURCE[0]}")/' + helper + '"',
                              '. "' + str(root / "tests" / helper) + '"')
scenario = r'''
set -e
printf '%s\n' 'SYNTHETIC: real Firstmate CLIs; fake tmux/agent; disposable local git homes.'
dir=$(new_case evidence)
add_local_mate "$dir" sm1
clean_pause_home "$dir" sm1
printf -- '- sm1 - domain (home: %s; scope: things; projects: p; added 2026-09-03)\n' "$dir/sm1-home" > "$dir/home/data/secondmates.md"
printf '# Backlog\n\n## Queued\n\n- [ ] routed - new work (repo: p; added 2026-10-29)\n\n## In flight\n\n## Done\n' > "$dir/home/data/backlog.md"
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$dir/sm1-home/data/backlog.md"
printf '%s\n' '$ fm-secondmate-restart.sh --pause sm1'
run_restart "$dir" --pause sm1
printf '%s\n' '$ fm-crew-state.sh sm1'
env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" "$ROOT/bin/fm-crew-state.sh" sm1
[ -d "$dir/sm1-home" ] && [ -f "$dir/home/state/sm1.meta" ]
printf '%s\n' 'Home and route retained.'
printf '%s\n' '$ fm-send.sh sm1 "re-read config"'
rc=0
env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" "$ROOT/bin/fm-send.sh" sm1 're-read config' 2>&1 || rc=$?
printf 'exit=%s\n' "$rc"
[ "$rc" = 75 ] && [ -f "$dir/home/state/.secondmate-paused-sm1" ]
printf '%s\n' '$ fm-secondmate-restart.sh --resume sm1'
run_restart "$dir" --resume sm1
[ ! -e "$dir/home/state/.secondmate-paused-sm1" ]
printf '%s\n' '$ fm-secondmate-restart.sh --pause sm1'
run_restart "$dir" --pause sm1
printf '%s\n' '$ fm-backlog-handoff.sh sm1 routed'
env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_SUPERVISION_ACTOR=main FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 "$ROOT/bin/fm-backlog-handoff.sh" sm1 routed
[ ! -e "$dir/home/state/.secondmate-paused-sm1" ]
printf '%s\n' 'Destination backlog after fresh-work resume:'
cat "$dir/sm1-home/data/backlog.md"
printf 'kind=ship\n' > "$dir/sm1-home/state/unlanded.meta"
printf '%s\n' '$ fm-secondmate-restart.sh --pause sm1 (child work remains)'
rc=0
run_restart "$dir" --pause sm1 || rc=$?
printf 'exit=%s\n' "$rc"
[ "$rc" = 3 ] && [ ! -e "$dir/home/state/.secondmate-paused-sm1" ]
printf '%s\n' 'Unsafe pause refused; running posture retained.'
'''
env = os.environ.copy()
env["TMPDIR"] = "/tmp"
raise SystemExit(subprocess.run(["bash"], input=fixture + scenario, text=True, env=env).returncode)

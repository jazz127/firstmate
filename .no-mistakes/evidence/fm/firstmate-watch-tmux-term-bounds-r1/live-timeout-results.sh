#!/bin/bash
set -eu
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB="$PWD/.nm-results"
bash bin/fm-lab-home.sh create "$LAB"
trap 'python3 -c "import pathlib,shutil;shutil.rmtree(pathlib.Path.cwd()/\".nm-results\")"' EXIT
for MECHANISM in perl bash; do
  FM_HOME="$LAB" FM_TIMEOUT_MECHANISM_OVERRIDE="$([ "$MECHANISM" != bash ] || printf bash)" bash -c '
    . bin/fm-watch.sh
    watcher_query fm_run_timed 05 bash -c "printf through; exit 7"
    rc=$?
    printf "mechanism=%s output=%s status=%s\n" "$1" "$WATCHER_QUERY" "$rc"
    [ "$rc" = 7 ] && [ "$WATCHER_QUERY" = through ] || exit 1
    watcher_query fm_run_timed 1 bash -c "echo \$\$ > \"\$1/pid\"; trap \"\" TERM; exec sleep 60" _ "$FM_HOME"
    rc=$?
    printf "mechanism=%s deadline_status=%s\n" "$1" "$rc"
    [ "$rc" = 124 ] || exit 1
    child=$(cat "$FM_HOME/pid")
    if kill -0 "$child" 2>/dev/null; then echo "deadline child survived"; kill -KILL "$child"; exit 1; fi
    . bin/fm-nm-run-lib.sh
    export FM_TIMEOUT_OWNER_PID=$$
    result=$(fm_nm_bounded "$FM_HOME" 5 bash -c "read -r input; printf %s \"\$input\"; exit 7" <<< provided)
    rc=$?
    printf "mechanism=%s stdin_output=%s status=%s\n" "$1" "$result" "$rc"
    [ "$rc" = 7 ] && [ "$result" = provided ] || exit 1
  ' _ "$MECHANISM"
done

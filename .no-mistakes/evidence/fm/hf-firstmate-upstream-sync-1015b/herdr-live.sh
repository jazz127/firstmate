#!/bin/bash
set -eu
export FM_HERDR_LAB_STATE_DIR="$PWD/.validation-tmp/herdr"
name=$(bin/fm-herdr-lab.sh name upstream-sync)
cleanup() { bin/fm-herdr-lab.sh teardown "$name"; }
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$name"
created=$(bin/fm-herdr-lab.sh run "$name" workspace create --cwd "$PWD" --label validation --no-focus)
printf '%s\n' "$created"
pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
bin/fm-herdr-lab.sh viewer start "$name"
bin/fm-herdr-lab.sh run "$name" pane send-text "$pane" 'printf "HERDR_LIVE_CAPTURE_OK\n"'
bin/fm-herdr-lab.sh run "$name" pane send-keys "$pane" enter
sleep 1
. bin/fm-backend.sh
fm_backend_source herdr
target="$name:$pane"
plain=$(fm_backend_herdr_visible_capture "$target")
printf 'Real visible capture: %s\n' "$plain"
case "$plain" in *HERDR_LIVE_CAPTURE_OK*) ;; *) exit 1 ;; esac
bin/fm-herdr-lab.sh viewer stop "$name"
bin/fm-herdr-lab.sh stop "$name"
if fm_backend_herdr_visible_capture "$target"; then echo 'FAIL: plain capture accepted a stopped session'; exit 1; else echo 'Plain capture refused the stopped session'; fi
if fm_backend_herdr_visible_capture_ansi "$target"; then echo 'FAIL: ANSI capture accepted a stopped session'; exit 1; else echo 'ANSI capture refused the stopped session'; fi
status=$(bin/fm-herdr-lab.sh run "$name" status --json)
printf '%s\n' "$status"
printf '%s' "$status" | jq -e '.server.running == false' >/dev/null
printf '%s\n' 'PASS: passive captures left the real named lab server stopped'

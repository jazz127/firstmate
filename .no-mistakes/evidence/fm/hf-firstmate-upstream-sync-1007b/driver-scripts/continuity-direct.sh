#!/usr/bin/env bash
set -eu
. "$PWD/tests/lib.sh"
. "$PWD/bin/fm-classify-lib.sh"
LAB_DIR=$(mktemp -d "$PWD/.test-phase-tmp/continuity-direct.XXXXXX")
trap 'rm -rf "$LAB_DIR"; fm_test_cleanup' EXIT
mkdir -p "$LAB_DIR/parent/state/remote-replies" "$LAB_DIR/parent/data" "$LAB_DIR/remote/state"
ADAPTER="$PWD/bin/fm-procevent-remote-reply.sh"
READER="$PWD/bin/fm-remote-delta-read.sh"
empty_hash=$(printf '' | shasum -a 256 | awk '{print $1}')
original='working: accepted first reply'
printf '%s\n' "$original" > "$LAB_DIR/remote/state/parent-replies.status"
read_delta() { FM_HOME="$LAB_DIR/remote" "$READER" state/parent-replies.status "$1" "$2" 1 > "$LAB_DIR/result"; }
ingest() { FM_HOME="$LAB_DIR/parent" "$ADAPTER" ingest ios "$LAB_DIR/result"; }
current_break() {
  offset=$(sed -n 's/^offset=//p' "$LAB_DIR/parent/state/remote-replies/ios.cursor")
  hash=$(sed -n 's/^prefix_sha256=//p' "$LAB_DIR/parent/state/remote-replies/ios.cursor")
  : > "$LAB_DIR/remote/state/parent-replies.status"
  read_delta "$offset" "$hash"
  rc=0; ingest || rc=$?
  [ "$rc" -eq 3 ] || fail "a broken prefix must return continuity status 3"
}
read_delta 0 "$empty_hash"
ingest
current_break
[ "$(grep -c 'blocked \[key=remote-reply-continuity-ios\]' "$LAB_DIR/parent/state/ios.status")" -eq 1 ] || fail 'first break did not open exactly once'
printf 'resolved [key=remote-reply-continuity-ios]: accepted the first break\n' >> "$LAB_DIR/parent/state/ios.status"
rc=0; ingest || rc=$?
[ "$rc" -eq 3 ] || fail 'repeat lost continuity classification'
[ -z "$(status_open_decisions "$LAB_DIR/parent/state/ios.status")" ] || fail 'the same break reopened after resolution'
printf '%s\nworking: newly accepted later reply\n' "$original" > "$LAB_DIR/remote/state/parent-replies.status"
read_delta "$offset" "$hash"
ingest
current_break
[ "$(grep -c 'blocked \[key=remote-reply-continuity-ios\]' "$LAB_DIR/parent/state/ios.status")" -eq 2 ] || fail 'later reader position did not reopen'
[ -n "$(status_open_decisions "$LAB_DIR/parent/state/ios.status")" ] || fail 'later break did not open a decision'
rc=0; ingest || rc=$?
[ "$rc" -eq 3 ] || fail 'later replay lost classification'
[ "$(grep -c 'blocked \[key=remote-reply-continuity-ios\]' "$LAB_DIR/parent/state/ios.status")" -eq 2 ] || fail 'later replay duplicated decision'
cp "$LAB_DIR/parent/state/ios.status" "$FM_DIRECT_CONTINUITY_EVIDENCE/status.txt"
cp "$LAB_DIR/parent/state/remote-replies/ios.cursor" "$FM_DIRECT_CONTINUITY_EVIDENCE/cursor.txt"
cp "$LAB_DIR/result" "$FM_DIRECT_CONTINUITY_EVIDENCE/delta-result.txt"
status_open_decisions "$LAB_DIR/parent/state/ios.status"
pass 'resolved repeated break stays closed; a later break after cursor advance reopens exactly once'

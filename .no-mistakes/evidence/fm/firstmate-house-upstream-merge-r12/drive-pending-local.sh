#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$ROOT/fm-test-phase-temp/pending-local
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config"
trap 'rm -rf "$LAB"' EXIT
export FM_HOME=$LAB FM_STATE_OVERRIDE=$LAB/state FM_DATA_OVERRIDE=$LAB/data FM_CONFIG_OVERRIDE=$LAB/config
export FM_PENDING_REPLY_GRACE_SECS=0
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
. "$ROOT/bin/fm-classify-lib.sh"
printf 'Driver: real pending-reply library; local durable expectation and status protocol. No harness or transport is substituted or launched.\n'
corr=$(fm_pending_reply_create "$LAB" "$LAB/state" proof 'reconcile an unanswered delivery attempt')
status=$LAB/state/proof.status
rec=$(fm_pending_reply_path "$LAB/state" "$corr")
episode() {
  fm_pending_reply_prepare_delivery "$LAB/state" "$corr"
  fm_pending_reply_tick_one "$LAB/state" "$corr" unknown
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ]
  printf '\nPersisted status after reconciliation:\n'
  cat "$status"
  printf 'Open decisions:\n'
  status_open_decisions "$status"
}
episode
[ "$(grep -c 'blocked ' "$status")" = 1 ]
fm_pending_reply_reset_known_undelivered "$LAB/state" "$corr"
episode
[ "$(grep -c 'blocked ' "$status")" = 1 ]
# A resolved line is the owned status protocol consumed by this local fold.
printf '%s\n' "$(status_stamp_line "resolved [key=pending-reply-$corr]: pending-reply-resolved: operator closed the earlier hold")" >> "$status"
[ -z "$(status_open_decisions "$status")" ]
printf '\nAfter operator close, open decisions are empty.\n'
fm_pending_reply_reset_known_undelivered "$LAB/state" "$corr"
episode
[ "$(grep -c 'blocked ' "$status")" = 2 ]
[ "$(status_open_decisions "$status" | cut -f1)" = "pending-reply-$corr" ]
fm_pending_reply_reset_known_undelivered "$LAB/state" "$corr"
episode
[ "$(grep -c 'blocked ' "$status")" = 2 ]
printf '\nThe new episode reopened the same key; retries added no duplicate blocked line.\n'

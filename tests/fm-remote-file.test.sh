#!/usr/bin/env bash
# Direct transfer CLI contracts, without a remote transport or worker runtime.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-file)
TRANSFER="$ROOT/bin/fm-remote-file.sh"

run_transfer() {  # <home> <arguments...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$TRANSFER" "$@"
}

payload_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

test_decimal_limits() {
  local limit home payload hash
  for limit in 8 08 10 010; do
    home="$TMP_ROOT/decimal-$limit"
    mkdir -p "$home"
    case "$limit" in 8|08) payload=complete ;; *) payload=0123456789 ;; esac
    hash=$(printf '%s' "$payload" | payload_hash)
    printf '%s' "$payload" > "$home/expected"
    run_transfer "$home" put state/handoff/probe.outbox.md "$limit" \
      "${#payload}" "$hash" 1 < "$home/expected" > "$home/put.out" \
      || fail "decimal upload limit $limit refused an exact-size payload"
    cmp -s "$home/expected" "$home/state/handoff/probe.outbox.md" \
      || fail "decimal upload limit $limit changed the payload"
    run_transfer "$home" get state/handoff/probe.outbox.md "$limit" > "$home/get.out" \
      || fail "decimal download limit $limit refused an exact-size payload"
    cmp -s "$home/expected" "$home/get.out" || fail "download changed payload bytes"
  done
  pass "transfer byte limits accept zero-padded decimal counts without octal conversion"
}

test_limit_refusals_preserve_payload() {
  local home limit hash
  home="$TMP_ROOT/refusals"
  mkdir -p "$home/data"
  : > "$home/data/empty"
  hash=$(printf complete | payload_hash)
  for limit in 0 00 000 1048577 01048577; do
    if run_transfer "$home" get data/empty "$limit" > "$home/out" 2> "$home/err"; then
      fail "download accepted invalid limit $limit"
    fi
    if printf complete | run_transfer "$home" put state/handoff/probe.outbox.md \
      "$limit" 8 "$hash" 1 > "$home/out" 2> "$home/err"; then
      fail "upload accepted invalid limit $limit"
    fi
  done
  printf complete > "$home/expected"
  run_transfer "$home" put state/handoff/probe.outbox.md 08 8 "$hash" 2 \
    < "$home/expected" > "$home/out" || fail "could not establish committed payload"
  if printf 'completeX' | run_transfer "$home" put state/handoff/probe.outbox.md \
    08 8 "$hash" 3 > "$home/out" 2> "$home/err"; then
    fail "upload accepted an over-limit payload"
  fi
  cmp -s "$home/expected" "$home/state/handoff/probe.outbox.md" \
    || fail "refused upload changed the committed payload"
  if run_transfer "$home" get state/handoff/probe.outbox.md 07 > "$home/out" 2> "$home/err"; then
    fail "download ignored its limit"
  fi
  [ ! -s "$home/out" ] || fail "over-limit download emitted partial content"
  pass "zero and oversized limits are refused and byte bounds preserve committed content"
}

test_decimal_limits
test_limit_refusals_preserve_payload

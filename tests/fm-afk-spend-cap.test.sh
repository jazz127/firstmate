#!/usr/bin/env bash
# The away spend cap counts workers that can still spend, not retained records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-spend-cap)
fm_git_identity fmtest fmtest@example.invalid

test_exited_worker_does_not_fill_cap() {
  local home root out
  home="$TMP_ROOT/home"
  root="$TMP_ROOT/project"
  mkdir -p "$home/state" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "away entry failed"
  fm_write_meta "$home/state/exited.meta" "window=missing:fm-exited" "kind=ship"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-spawn.sh" fresh --mode no-mistakes --yolo off 2>&1) || true
  assert_not_contains "$out" "caps concurrent workers" \
    "an exited worker filled the spend cap: $out"
  pass "an exited worker does not fill the away spend cap"
}

test_only_workers_able_to_spend_count() {
  local dir state count
  dir="$TMP_ROOT/count"
  state="$dir/state"
  mkdir -p "$dir/bin" "$state"
  ln -s "$ROOT/bin/fm-afk-spend-count.sh" "$dir/bin/fm-afk-spend-count.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cat > "$dir/bin/fm-backend.sh" <<'SH'
fm_meta_get() { sed -n "s/^$2=//p" "$1" | tail -1; }
fm_backend_of_meta() { printf 'tmux'; }
fm_backend_target_of_meta() { fm_meta_get "$1" window; }
fm_backend_agent_state() {
  case "$2" in
    gone:*) printf 'missing' ;;
    uncertain:*) printf 'unreadable' ;;
    *) printf 'alive' ;;
  esac
}
SH
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ready) printf 'state: done · source: status-log\n' ;;
  *) printf 'state: blocked · source: status-log\n' ;;
esac
SH
  chmod +x "$dir/bin/fm-crew-state.sh"
  printf 'kind=ship\nwindow=alive:active\n' > "$state/active.meta"
  printf 'working: implementing\n' > "$state/active.status"
  printf 'kind=ship\nwindow=alive:ready\n' > "$state/ready.meta"
  printf 'done: PR waiting on merge\n' > "$state/ready.status"
  printf 'kind=ship\nwindow=alive:invalid\n' > "$state/invalid.meta"
  printf 'done: head not reachable\n' > "$state/invalid.status"
  printf 'kind=scout\nwindow=gone:exited\n' > "$state/exited.meta"
  printf 'kind=ship\nwindow=uncertain:probe\n' > "$state/uncertain.meta"
  printf 'kind=secondmate\nwindow=alive:mate\n' > "$state/mate.meta"

  count=$("$dir/bin/fm-afk-spend-count.sh" "$state") || fail "count failed"
  [ "$count" = 3 ] || fail "counted $count workers, expected active, invalid done, and unreadable endpoint"
  printf 'working: review feedback arrived\n' >> "$state/ready.status"
  count=$("$dir/bin/fm-afk-spend-count.sh" "$state") || fail "recount failed"
  [ "$count" = 4 ] || fail "a resumed worker did not return to the spend count ($count)"
  pass "merge-waiting and exited workers leave cap room; unresolved and resumed work still counts"
}

test_exited_worker_does_not_fill_cap
test_only_workers_able_to_spend_count

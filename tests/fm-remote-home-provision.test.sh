#!/usr/bin/env bash
# Synthetic/offline provisioning through the entrypoint and isolated job worker.
# No remote host, credentials, or multi-GiB repository is exercised.
# shellcheck source=tests/lib.sh
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-provision)
REMOTE_ROOT="$TMP_ROOT/root"
ACCOUNT="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/jobs"
REAL_GIT=$(command -v git)
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT" "$TMP_ROOT/homes"
cleanup() {
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" \
  "$ROOT/bin/fm-remote-job-worker.sh" "$ROOT/bin/fm-remote-home-provision.sh" \
  "$ROOT/bin/fm-project-origin-lib.sh" "$ROOT/bin/fm-wake-lib.sh" \
  "$ROOT/bin/fm-path-lib.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/git" <<SH
#!/bin/bash
if [ "\${1:-}" = clone ]; then
  case "\${!#}" in
    */projects/alpha|*/.fm-provision-projects/alpha)
      printf 'clone\n' >> "$TMP_ROOT/project-clones"
      mkdir -p "\${!#}/.git"
      if [ -f "$TMP_ROOT/fail-clone" ]; then
        printf 'synthetic clone failure\n' >&2
        exit 42
      fi
      sleep 6
      rm -rf -- "\${!#}"
      ;;
  esac
fi
exec "$REAL_GIT" "\$@"
SH
cat > "$REMOTE_ROOT/bin/no-mistakes" <<SH
#!/bin/bash
case "\$1" in
  init)
    pwd -P > .git/nm-path
    [ ! -f "$TMP_ROOT/hold-init" ] || sleep 6
    ;;
  doctor) [ "\$(cat .git/nm-path)" = "\$(pwd -P)" ] || exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$REMOTE_ROOT/bin/git" "$REMOTE_ROOT/bin/no-mistakes"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" -c user.name=Test -c user.email=test@example.com commit -qm fixture
git init -q -b main "$TMP_ROOT/alpha"
printf 'project\n' > "$TMP_ROOT/alpha/README.md"
git -C "$TMP_ROOT/alpha" add .
git -C "$TMP_ROOT/alpha" -c user.name=Test -c user.email=test@example.com commit -qm fixture
b64() { base64 | tr -d '\n'; }
manifest() {
  printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=1\n' \
    "$(printf '%s' "$1" | b64)" "$(printf 'Synthetic charter.\n' | b64)"
  printf 'project=%s|%s|%s|%s\n' "$(printf '%s' "${PROVISION_PROJECT:-alpha}" | b64)" \
    "$(printf 'file://%s/alpha' "$TMP_ROOT" | b64)" \
    "$(printf -- '- %s [%s] - fixture' "${PROVISION_PROJECT:-alpha}" "${PROVISION_MODE:-direct-PR}" | b64)" "$(printf '%s' "${PROVISION_MODE:-direct-PR}" | b64)"
}
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_TIMEOUT=2 FM_REMOTE_JOB_QUEUE_TIMEOUT=30
. "$ROOT/bin/fm-remote-job-lib.sh"
run_provision() {
  local home=$1 id=$2 timeout=$3 rc=0
  manifest "$id" | "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 1 \
    "$(printf '%s' "$REMOTE_ROOT" | b64)" "$(printf '%s' "$home" | b64)" \
    "$(printf '%s\0' fm-remote-home-provision.sh --timeout "$timeout" | b64)" \
    > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || rc=$?
  printf 'synthetic/offline: id=%s timeout=%s exit=%s\n' "$id" "$timeout" "$rc"
  cat "$TMP_ROOT/out" "$TMP_ROOT/err"
  return "$rc"
}
LONG_HOME="$TMP_ROOT/homes/long"
if [ "${FM_PROVISION_REPRO_BASELINE:-0}" = 1 ]; then
  rc=0
  run_provision "$LONG_HOME" long 7200 || rc=$?
  [ "$rc" -eq 124 ] || fail "baseline did not hit its job bound"
  assert_present "$LONG_HOME/projects/alpha/.git" "baseline did not interrupt the clone"
  assert_absent "$LONG_HOME/.fm-secondmate-home" "baseline unexpectedly published"
  [ ! -s "$TMP_ROOT/err" ] || fail "baseline failure was not empty"
  rc=0
  run_provision "$LONG_HOME" long 7200 || rc=$?
  [ "$rc" -ne 0 ] || fail "baseline retry unexpectedly succeeded"
  assert_grep 'unmarked existing remote home contains operational data' "$TMP_ROOT/err" "baseline retry did not reproduce the ownership refusal"
  printf 'synthetic/offline baseline: 3 defect observations in 2 calls: clone killed, empty reason, retry refused. No remote host or 6 GiB clone.\n'
  exit 0
fi
run_provision "$LONG_HOME" long 7200 || fail "provision clone died at the ordinary job bound"
assert_equals long "$(cat "$LONG_HOME/.fm-secondmate-home")" "long clone did not publish"
assert_equals project "$(cat "$LONG_HOME/projects/alpha/README.md")" "long clone was incomplete"
assert_absent "$LONG_HOME/.fm-secondmate-provisioning" "published home retained its incomplete marker"
pass 'synthetic/offline: clone outlives the ordinary remote job bound; no remote host or 6 GiB clone'
SHORT_HOME="$TMP_ROOT/homes/short"
rc=0
run_provision "$SHORT_HOME" short 3 || rc=$?
[ "$rc" -eq 124 ] || fail "provision timeout did not return 124"
assert_grep 'remote job exceeded its 3 s bound (fm-remote-home-provision.sh)' "$TMP_ROOT/err" "timeout reason is missing"
assert_grep 'cloning project alpha' "$TMP_ROOT/err" "failed clone project is missing"
assert_equals short "$(cat "$SHORT_HOME/.fm-secondmate-provisioning")" "killed home has no ownership marker"
rc=0
run_provision "$SHORT_HOME" another 20 || rc=$?
[ "$rc" -ne 0 ] || fail "another id adopted the interrupted home"
assert_grep 'another secondmate' "$TMP_ROOT/err" "wrong-id refusal is missing"
run_provision "$SHORT_HOME" short 20 || fail "same-id retry did not recover"
assert_equals short "$(cat "$SHORT_HOME/.fm-secondmate-home")" "retry did not publish"
assert_equals project "$(cat "$SHORT_HOME/projects/alpha/README.md")" "retry retained a partial clone"
pass 'synthetic/offline: bound diagnostic names project and same-id retry recovers; no remote host or 6 GiB clone'
rc=0
run_provision "$TMP_ROOT/homes/invalid" invalid 86401 || rc=$?
[ "$rc" -ne 0 ] || fail "oversized provision bound was accepted"
assert_absent "$TMP_ROOT/homes/invalid" "invalid bound created a home"
pass 'synthetic/offline: invalid provisioning bound refuses before creating the home; no remote host or 6 GiB clone'
# Completed clones survive retries, including user material outside staging.
printf 'keep\n' > "$SHORT_HOME/projects/alpha/user-note"
clones_before=$(wc -l < "$TMP_ROOT/project-clones" | tr -d ' ')
run_provision "$SHORT_HOME" short 20 || fail "completed home did not converge"
assert_equals keep "$(cat "$SHORT_HOME/projects/alpha/user-note")" "retry discarded completed project work"
assert_equals "$clones_before" "$(wc -l < "$TMP_ROOT/project-clones" | tr -d ' ')" "retry cloned a completed project"
pass 'synthetic/offline: completed clones survive retry; no remote host or 6 GiB clone'
# Ordinary clone failure reports its project and still executes rollback.
touch "$TMP_ROOT/fail-clone"
rc=0
run_provision "$TMP_ROOT/homes/fail" fail 20 || rc=$?
[ "$rc" -ne 0 ] || fail "clone failure was swallowed"
assert_grep 'could not clone project alpha' "$TMP_ROOT/err" "clone failure lost its project"
assert_absent "$TMP_ROOT/homes/fail" "ordinary failure did not roll back the new home"
rm "$TMP_ROOT/fail-clone"
pass 'synthetic/offline: ordinary failure reports project and rolls back; no remote host or 6 GiB clone'
# A provision interrupted after publishing its clone must initialize the gate
# at the final path on retry. The stub cannot validate the actual gate product.
GATE_HOME="$TMP_ROOT/homes/gate"
touch "$TMP_ROOT/hold-init"
rc=0
PROVISION_PROJECT=beta PROVISION_MODE=no-mistakes run_provision "$GATE_HOME" gate 3 || rc=$?
[ "$rc" -eq 124 ] || fail "initialization did not hit the provision bound"
assert_grep 'initializing project beta' "$TMP_ROOT/err" "initialization failure lost its project"
assert_present "$GATE_HOME/projects/beta/README.md" "interrupted gate did not preserve completed clone"
rm "$TMP_ROOT/hold-init"
PROVISION_PROJECT=beta PROVISION_MODE=no-mistakes run_provision "$GATE_HOME" gate 20 || fail "interrupted gate did not recover"
assert_equals "$GATE_HOME/projects/beta" "$(cat "$GATE_HOME/projects/beta/.git/nm-path")" "gate initialized at the staging path"
pass 'synthetic/offline: gate stub resumes initialization at final path; actual no-mistakes gate and remote host not exercised'
# Legacy unmarked operational homes are never adopted or cleaned automatically.
rm "$LONG_HOME/.fm-secondmate-home"
rc=0
run_provision "$LONG_HOME" long 7200 || rc=$?
[ "$rc" -ne 0 ] || fail "legacy unmarked home was adopted"
assert_grep 'unmarked existing remote home contains operational data' "$TMP_ROOT/err" "legacy refusal changed"
assert_present "$LONG_HOME/projects/alpha/README.md" "legacy refusal removed project data"
# Never follow an owned home's staging symlink when recovering.
printf 'short\n' > "$SHORT_HOME/.fm-secondmate-provisioning"
mkdir "$TMP_ROOT/victim"
printf 'keep\n' > "$TMP_ROOT/victim/sentinel"
ln -s "$TMP_ROOT/victim" "$SHORT_HOME/.fm-provision-projects"
rc=0
run_provision "$SHORT_HOME" short 20 || rc=$?
[ "$rc" -ne 0 ] || fail "staging symlink was accepted"
assert_equals keep "$(cat "$TMP_ROOT/victim/sentinel")" "staging refusal removed unrelated data"
pass 'synthetic/offline: unmarked homes and unsafe staging stay refused; no remote host or 6 GiB clone'
printf 'ALL TESTS PASSED (synthetic/offline; no remote host or 6 GiB clone)\n'

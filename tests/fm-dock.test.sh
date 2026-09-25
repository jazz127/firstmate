#!/usr/bin/env bash
# Offline behavior checks for the read-only dock interface and noninheritance.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dock)
CONFIG="$TMP_ROOT/config"
SEAT="$TMP_ROOT/seat with spaces and \$(literal) 'quotes'"
mkdir -p "$CONFIG" "$SEAT"

resolve() {
  FM_CONFIG_OVERRIDE="$CONFIG" "$ROOT/bin/fm-dock.sh" resolve --seat luna --harness codex 2>&1
}
write_record() {
  jq -n --arg home "$1" '{version:1,id:"test-dock",seats:{luna:{harness:"codex",credential_home:$home}}}' > "$CONFIG/dock.json"
}
write_record "$SEAT"
out=$(resolve); rc=$?
expect_code 0 "$rc" "valid dock record should resolve: $out"
assert_contains "$out" "credential_home=$SEAT" "punctuation must remain literal"
assert_contains "$out" 'dock=test-dock' "dock id must be visible"
assert_absent "$TMP_ROOT/literal" "path punctuation must not execute shell text"
pass "valid dock record resolves a literal credential path"

ln -s "$SEAT" "$TMP_ROOT/seat-link"
write_record "$TMP_ROOT/seat-link"
out=$(resolve); rc=$?
expect_code 0 "$rc" "symlinked directory should resolve: $out"
assert_contains "$out" "credential_home=$SEAT" "directory must resolve physically"
pass "symlinked credential directory resolves to one physical identity"

for fixture in \
  '{"version":2,"id":"test","seats":{}}' \
  '{"version":1,"id":"bad id","seats":{}}' \
  '{"version":1,"id":"test","extra":1,"seats":{}}' \
  '{"version":1,"id":"test","seats":{}}' \
  '{"version":1,"id":"test","seats":{"other":{"harness":"codex","credential_home":"/tmp"}}}' \
  '{"version":1,"id":"test","seats":{"luna":{"harness":"claude","credential_home":"/tmp"}}}' \
  '{"version":1,"id":"test","seats":{"luna":{"harness":"codex","credential_home":"relative"}}}' \
  '{"version":1,"id":"test","seats":{"luna":{"harness":"codex","credential_home":"/tmp/line\nfeed"}}}' \
  'not json'; do
  printf '%s\n' "$fixture" > "$CONFIG/dock.json"
  out=$(resolve); rc=$?
  expect_code 1 "$rc" "invalid dock record must refuse: $fixture"
  assert_contains "$out" 'no ambient account selected' "invalid record must not fall back"
done
printf '%s\n' '{"version":1,"id":"test","seats":{"luna":{"harness":"codex","credential_home":"/tmp/line\nfeed"}}}' > "$CONFIG/dock.json"
out=$(resolve); rc=$?
expect_code 1 "$rc" "control-character path must refuse"
assert_contains "$out" 'malformed' "control-character path must fail schema validation"
pass "unsupported, incomplete, and malformed records refuse without fallback"

write_record "$TMP_ROOT/missing"
out=$(resolve); rc=$?
expect_code 1 "$rc" "missing directory must refuse"
assert_contains "$out" 'missing or unreadable' "missing directory should be actionable"
rm "$CONFIG/dock.json"
ln -s "$TMP_ROOT/no-record" "$CONFIG/dock.json"
out=$(resolve); rc=$?
expect_code 1 "$rc" "broken symlink is a present invalid record"
assert_contains "$out" 'ordinary readable JSON file' "broken symlink must not use legacy mapping"
rm "$CONFIG/dock.json"
if [ "$(uname -s)" = Darwin ] && [ "$(id -un)" = jarad ] && [ -d /Users/jarad/.codex-luna ]; then
  out=$(HOME=/Users/jarad resolve); rc=$?
  expect_code 0 "$rc" "the exact legacy Mac identity should resolve"
  assert_contains "$out" 'source=legacy-mac-jarad' "the compatibility source should be visible"
fi
out=$(HOME="$TMP_ROOT/other-home" resolve); rc=$?
expect_code 1 "$rc" "another HOME must not use the legacy mapping"
assert_contains "$out" 'dock record' "missing binding should name the record"
pass "missing and unreadable homes refuse, and legacy fallback is tightly gated"

primary="$TMP_ROOT/primary"
second="$TMP_ROOT/second"
mkdir -p "$primary/config" "$primary/data" "$second/config" "$second/data"
printf '%s\n' '{"rules":[]}' > "$primary/config/crew-dispatch.json"
printf 'primary dock\n' > "$primary/config/dock.json"
printf 'second dock\n' > "$second/config/dock.json"
propagate_secondmate_inheritance "$primary" "$second" >/dev/null || fail "inheritance failed"
cmp -s "$primary/config/crew-dispatch.json" "$second/config/crew-dispatch.json" || fail "dispatch profile did not converge"
assert_grep 'second dock' "$second/config/dock.json" "target dock was overwritten"
rm "$primary/config/dock.json"
propagate_secondmate_inheritance "$primary" "$second" >/dev/null || fail "absence propagation failed"
assert_grep 'second dock' "$second/config/dock.json" "target dock was removed on source absence"
pass "inherited profiles converge while target dock bytes remain local"
echo '# all fm-dock tests passed'

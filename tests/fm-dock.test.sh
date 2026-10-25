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
  FM_CONFIG_OVERRIDE="$CONFIG" "$ROOT/bin/fm-dock.sh" resolve --seat "${1-primary}" --harness codex 2>&1
}
write_record() {
  jq -n --arg home "$1" --arg seat "${2-primary}" '{version:1,id:"test-dock",seats:{($seat):{harness:"codex",credential_home:$home}}}' > "$CONFIG/dock.json"
}
write_record "$SEAT"
out=$(resolve); rc=$?
expect_code 0 "$rc" "valid dock record should resolve: $out"
assert_contains "$out" "credential_home=$SEAT" "punctuation must remain literal"
assert_contains "$out" 'dock=test-dock' "dock id must be visible"
assert_absent "$TMP_ROOT/literal" "path punctuation must not execute shell text"
pass "valid dock record resolves a literal credential path"

SECONDARY_SEAT="$TMP_ROOT/secondary-seat"
mkdir -p "$SECONDARY_SEAT"
write_record "$SECONDARY_SEAT" secondary
out=$(resolve secondary); rc=$?
expect_code 0 "$rc" "valid secondary dock seat should resolve: $out"
assert_contains "$out" "seat=secondary" "secondary seat identity should be visible"
assert_contains "$out" "credential_home=$SECONDARY_SEAT" "secondary seat must resolve its own credential directory"
pass "secondary Codex seat resolves independently by name"

long_name=$(printf '%064d' 0)
for name in a 7 build-2 primary secondary "$long_name"; do
  write_record "$SEAT" "$name"
  out=$(resolve "$name"); rc=$?
  expect_code 0 "$rc" "valid private seat $name should resolve: $out"
  assert_contains "$out" "seat=$name" "resolved seat identity must match configuration"
done
pass "arbitrary safe seat names resolve, including digits, dashes, and the length limit"

for name in '' '-leading' 'Upper' 'under_score' 'dot.name' 'slash/name' 'space name' "$long_name"0 $'line\n' $'tab\tname'; do
  write_record "$SEAT" "$name"
  out=$(resolve "$name"); rc=$?
  expect_code 1 "$rc" "invalid selected seat name must refuse: $name"
  assert_contains "$out" 'no ambient account selected' "unsafe selected name must not fall back"
  jq --arg home "$SEAT" '.seats.primary = {harness:"codex",credential_home:$home}' "$CONFIG/dock.json" > "$CONFIG/updated.json"
  mv "$CONFIG/updated.json" "$CONFIG/dock.json"
  out=$(resolve primary); rc=$?
  expect_code 1 "$rc" "an invalid unselected dock key must also refuse: $name"
done
pass "invalid seat names refuse both as selections and as unselected dock keys"

write_record "$SEAT"
out=$(resolve unconfigured); rc=$?
expect_code 1 "$rc" "a safe name absent from the dock must refuse"
assert_contains "$out" 'does not bind seat unconfigured to codex' "unknown seat should identify the missing binding"
pass "unconfigured names cannot borrow another seat"

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
  '{"version":1,"id":"test","seats":{"primary":{"harness":"claude","credential_home":"/tmp"}}}' \
  '{"version":1,"id":"test","seats":{"primary":{"harness":"codex","credential_home":"relative"}}}' \
  '{"version":1,"id":"test","seats":{"primary":{"harness":"codex","credential_home":"/tmp/line\nfeed"}}}' \
  'not json'; do
  printf '%s\n' "$fixture" > "$CONFIG/dock.json"
  out=$(resolve); rc=$?
  expect_code 1 "$rc" "invalid dock record must refuse: $fixture"
  assert_contains "$out" 'no ambient account selected' "invalid record must not fall back"
done
printf '%s\n' '{"version":1,"id":"test","seats":{"primary":{"harness":"codex","credential_home":"/tmp/line\nfeed"}}}' > "$CONFIG/dock.json"
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
assert_contains "$out" 'ordinary readable JSON file' "broken symlink must refuse without fallback"
rm "$CONFIG/dock.json"
out=$(resolve); rc=$?
expect_code 1 "$rc" "an absent record must refuse for the current host and HOME"
assert_contains "$out" 'is absent' "missing binding should name the absent record"
out=$(HOME="$TMP_ROOT/other-home" resolve); rc=$?
expect_code 1 "$rc" "another HOME must also refuse without a record"
assert_contains "$out" 'is absent' "missing binding should name the absent record"
pass "missing and unreadable homes refuse without host-specific fallback"

primary="$TMP_ROOT/primary"
second="$TMP_ROOT/second"
mkdir -p "$primary/config" "$primary/data" "$second/config" "$second/data"
printf '%s\n' '{"rules":[]}' > "$primary/config/crew-dispatch.json"
jq -n '{version:1,id:"primary-dock",seats:{}}' > "$primary/config/dock.json"
jq -n '{version:1,id:"second-dock",seats:{}}' > "$second/config/dock.json"
propagate_secondmate_inheritance "$primary" "$second" >/dev/null || fail "inheritance failed"
cmp -s "$primary/config/crew-dispatch.json" "$second/config/crew-dispatch.json" || fail "dispatch profile did not converge"
jq -e '.id == "second-dock"' "$second/config/dock.json" >/dev/null || fail "target dock was overwritten"
rm "$primary/config/dock.json"
propagate_secondmate_inheritance "$primary" "$second" >/dev/null || fail "absence propagation failed"
jq -e '.id == "second-dock"' "$second/config/dock.json" >/dev/null || fail "target dock was removed on source absence"
pass "inherited profiles converge while target dock bytes remain local"
echo '# all fm-dock tests passed'

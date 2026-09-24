#!/usr/bin/env bash
# Exercise the public one-frame renderer with an isolated local house ref.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-tab)
CLONE="$TMP_ROOT/quota-axi"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
mkdir -p "$CLONE" "$TMP_ROOT/source"
git -C "$TMP_ROOT/source" init --quiet
git -C "$TMP_ROOT/source" config user.name Test
git -C "$TMP_ROOT/source" config user.email test@example.invalid
echo house > "$TMP_ROOT/source/README"
git -C "$TMP_ROOT/source" add README
git -C "$TMP_ROOT/source" commit --quiet -m 'Quota house line'
git clone --quiet "$TMP_ROOT/source" "$CLONE"
git -C "$CLONE" remote add jazz127 "$TMP_ROOT/source"
git -C "$CLONE" fetch --quiet jazz127 HEAD:refs/remotes/jazz127/house

cat > "$FAKEBIN/quota-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$QUOTA_ARGS"
printf 'Codex home card: $72 credit\nCodex Luna card: weekly headroom 41%%\n'
EOF
chmod +x "$FAKEBIN/quota-axi"

OUTPUT=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_CLONE="$CLONE" FM_QUOTA_TAB_INTERVAL=17 \
  QUOTA_ARGS="$TMP_ROOT/quota-args" \
  TERM=dumb "$ROOT/bin/fm-quota-tab.sh" once 2>&1) \
  || fail "one-frame render failed: $OUTPUT"
assert_contains "$OUTPUT" 'quota-axi view of the fleet house line' 'heading is missing'
assert_equals '--tui --once' "$(cat "$TMP_ROOT/quota-args")" 'TUI was not requested for one frame'
assert_contains "$OUTPUT" 'House tip: ' 'house tip is missing'
assert_contains "$OUTPUT" 'Quota house line' 'house subject is missing'
assert_contains "$OUTPUT" "quota-axi executable: $FAKEBIN/quota-axi" 'executable path is missing'
assert_contains "$OUTPUT" "Codex home card: \$72 credit" 'first Codex seat card is missing'
assert_contains "$OUTPUT" 'Codex Luna card: weekly headroom 41%' 'second Codex seat card is missing'
assert_contains "$OUTPUT" 'interval: 17 seconds' 'refresh interval is missing'
report_line=$(printf '%s\n' "$OUTPUT" | rg -n 'Codex home card' | cut -d: -f1)
house_line=$(printf '%s\n' "$OUTPUT" | rg -n 'House tip:' | cut -d: -f1)
[ "$report_line" -lt "$house_line" ] || fail 'house block appeared before the TUI report'
pass 'one frame shows the house commit, executable, account rows, and interval'

cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *fetch*) exit 1 ;;
esac
exec /usr/bin/git "$@"
EOF
chmod +x "$FAKEBIN/git"
OUTPUT=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_CLONE="$CLONE" QUOTA_ARGS="$TMP_ROOT/quota-args" TERM=dumb \
  "$ROOT/bin/fm-quota-tab.sh" once 2>&1) \
  || fail "frame aborted after fetch failure: $OUTPUT"
assert_contains "$OUTPUT" 'Quota house line' 'fetch failure hid the existing house tip'
pass 'a quiet fetch failure leaves the current remote-tracking house tip readable'

if "$ROOT/bin/fm-quota-tab.sh" unsupported >/dev/null 2>&1; then
  fail 'an unsupported mode was accepted'
fi
pass 'unsupported modes are rejected'

echo 'ALL TESTS PASSED'

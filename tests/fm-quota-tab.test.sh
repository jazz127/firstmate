#!/usr/bin/env bash
# Exercise the public one-frame renderer with an isolated local house ref.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-tab)
CLONE="$TMP_ROOT/quota-axi"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$CLONE" "$TMP_ROOT/source" "$HOME_FIXTURE/bin" "$HOME_FIXTURE/projects"
git -C "$TMP_ROOT/source" init --quiet
git -C "$TMP_ROOT/source" config user.name Test
git -C "$TMP_ROOT/source" config user.email test@example.invalid
echo house > "$TMP_ROOT/source/README"
git -C "$TMP_ROOT/source" add README
git -C "$TMP_ROOT/source" commit --quiet -m 'Quota house line'
git clone --quiet "$TMP_ROOT/source" "$CLONE"
git -C "$CLONE" remote add jazz127 "$TMP_ROOT/source"
git -C "$CLONE" fetch --quiet jazz127 HEAD:refs/remotes/jazz127/house

# A second fixture clone rooted in a fake home, for the clone-resolution cases.
git clone --quiet "$TMP_ROOT/source" "$HOME_FIXTURE/projects/quota-axi"
git -C "$HOME_FIXTURE/projects/quota-axi" remote add jazz127 "$TMP_ROOT/source"
git -C "$HOME_FIXTURE/projects/quota-axi" fetch --quiet jazz127 HEAD:refs/remotes/jazz127/house
cp "$ROOT/bin/fm-quota-tab.sh" "$HOME_FIXTURE/bin/"

cat > "$FAKEBIN/quota-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$QUOTA_ARGS"
printf 'Codex home card: $72 credit\nCodex Luna card: weekly headroom 41%%\n'
EOF
chmod +x "$FAKEBIN/quota-axi"

# line_of <marker> prints the 1-based line of the first <marker> hit in $OUTPUT.
line_of() {
  printf '%s\n' "$OUTPUT" | rg -n "$1" | head -n1 | cut -d: -f1
}

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
title_line=$(line_of 'quota-axi view of the fleet house line')
report_line=$(line_of 'Codex home card')
label_line=$(line_of 'Fleet house line:')
house_line=$(line_of 'House tip:')
exec_line=$(line_of 'quota-axi executable:')
refresh_line=$(line_of 'Refreshed: ')
for pos in "$title_line" "$report_line" "$label_line" "$house_line" "$exec_line" "$refresh_line"; do
  [ -n "$pos" ] || fail "output position check lost a marker line: $OUTPUT"
done
[ "$title_line" -lt "$report_line" ] || fail 'TUI report appeared before the frame heading'
[ "$report_line" -lt "$label_line" ] || fail 'fleet block appeared before the TUI report'
[ "$label_line" -lt "$house_line" ] || fail 'house tip appeared before the fleet block heading'
[ "$house_line" -lt "$exec_line" ] || fail 'executable line appeared before the house tip'
[ "$exec_line" -lt "$refresh_line" ] || fail 'refresh line appeared before the executable line'
pass 'one frame shows the house commit, executable, account rows, and interval'

OUTPUT=$(env -u FM_HOME -u FM_QUOTA_CLONE \
  PATH="$FAKEBIN:$PATH" QUOTA_ARGS="$TMP_ROOT/quota-args" TERM=dumb \
  "$HOME_FIXTURE/bin/fm-quota-tab.sh" once 2>&1) \
  || fail "plain run without FM_HOME failed: $OUTPUT"
assert_contains "$OUTPUT" 'Quota house line' 'plain run lost the home-local house tip'
assert_not_contains "$OUTPUT" 'clone is absent' 'plain run expanded the empty home to /projects/quota-axi'
pass 'a plain run with FM_HOME unset resolves the clone from the home the script lives in'

OUTPUT=$(env -u FM_QUOTA_CLONE FM_HOME="$HOME_FIXTURE" \
  PATH="$FAKEBIN:$PATH" QUOTA_ARGS="$TMP_ROOT/quota-args" TERM=dumb \
  "$ROOT/bin/fm-quota-tab.sh" once 2>&1) \
  || fail "explicit FM_HOME run failed: $OUTPUT"
assert_contains "$OUTPUT" 'Quota house line' 'explicit FM_HOME was not honored'
assert_not_contains "$OUTPUT" 'clone is absent' 'explicit FM_HOME lost its clone'
pass 'an explicit FM_HOME still resolves the clone from that home'

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

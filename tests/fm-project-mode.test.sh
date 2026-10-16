#!/usr/bin/env bash
# tests/fm-project-mode.test.sh - unit tests for the `forgejo` value of
# bin/fm-project-mode.sh's closed `forge=` registry binding. The binding's
# grammar, its Gerrit value, and its refusals are pinned in
# tests/fm-task-delivery.test.sh; this file covers only what forgejo adds: it
# binds in any token order, keeps +yolo (unlike gerrit), is refused on
# local-only like every forge, and the plain (no --forge/--raw) output stays
# exactly two words, because tests/fm-secondmate-safety.test.sh and
# tests/fm-secondmate-lifecycle-e2e.test.sh assert that shape with strict
# string equality.
# Also covers literal project names when AWK would otherwise decode backslashes,
# and conflicting forge tokens that cannot resolve by token order.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode-tests)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"

cat > "$DATA/projects.md" <<'EOF'
## Projects
- legacy - a project registered before any bracket token existed (added 2026-01-01)
- flagged [direct-PR +yolo] - mode and yolo, no forge token (added 2026-01-01)
- lab [no-mistakes forge=forgejo] - forge token after mode (added 2026-01-01)
- lead [forge=forgejo direct-PR +yolo] - forge token first, order must not matter (added 2026-01-01)
- kept [local-only forge=forgejo] - a forge on a mode that publishes nothing (added 2026-01-01)
- colon [no-mistakes forge:forgejo] - a colon-spelled token is not a forge binding (added 2026-01-01)
- glabbed [no-mistakes forge=gitlab] - gitlab is not a forge value (added 2026-01-01)
- tools\new [local-only branch=private/] - a literal backslash-n in the name (added 2026-01-01)
- tools\tree [local-only branch=private/] - a literal backslash-t in the name (added 2026-01-01)
- tools\branch [direct-PR forge=forgejo +yolo] - a literal backslash-b in the name (added 2026-01-01)
- unterminated [no-mistakes - description mentions +yolo without granting it (added 2026-01-01)
- prose-bracket [no-mistakes - description mentions +yolo and a [label] (added 2026-01-01)
- unfinished-policy [direct-PR +yolo branch=custom/ forge=forgejo - missing closing bracket (added 2026-01-01)
EOF

run_mode() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" "$1" 2>/dev/null
}
run_forge() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge "$1" 2>/dev/null
}

[ "$(run_mode legacy)" = "no-mistakes off" ] || fail "legacy entry's default output changed: $(run_mode legacy)"
[ "$(run_forge legacy)" = "none" ] || fail "an entry with no forge token must report forge none: $(run_forge legacy)"
[ "$(run_mode flagged)" = "direct-PR on" ] || fail "flagged entry's mode/yolo output changed: $(run_mode flagged)"
[ "$(run_forge flagged)" = "none" ] || fail "mode and +yolo with no forge token must report forge none: $(run_forge flagged)"
pass "fm-project-mode: an entry with no forge token reports forge none and keeps its two-word default output"

[ "$(run_mode lab)" = "no-mistakes off" ] || fail "lab entry's mode output changed: $(run_mode lab)"
[ "$(run_forge lab)" = "forgejo" ] || fail "forge=forgejo after the mode token did not resolve: $(run_forge lab)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" lab 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered forge=forgejo warned: $err"
pass "fm-project-mode: forge=forgejo placed after the mode token binds forgejo without a warning"

[ "$(run_mode lead)" = "direct-PR on" ] || fail "forge=forgejo must keep +yolo, which only gerrit deactivates: $(run_mode lead)"
[ "$(run_forge lead)" = "forgejo" ] || fail "forge=forgejo placed before the mode token did not resolve: $(run_forge lead)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" lead 2>&1 >/dev/null)
[ -z "$err" ] || fail "+yolo on a forge=forgejo project was refused or warned: $err"
pass "fm-project-mode: forge=forgejo binds in any token order and keeps +yolo"

for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag kept 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "local-only with forge=forgejo did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused local-only forge still handed the caller a posture: '$out'"
done
pass "fm-project-mode: forge=forgejo on local-only is refused like every forge"

[ "$(run_mode colon)" = "no-mistakes off" ] || fail "a colon-spelled token changed the posture: $(run_mode colon)"
[ "$(run_forge colon)" = "none" ] || fail "forge:forgejo must not bind a forge; only forge=forgejo does: $(run_forge colon)"
pass "fm-project-mode: the colon spelling forge:forgejo is not a forge binding"

for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag glabbed 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "forge=gitlab did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused forge=gitlab still handed the caller a posture: '$out'"
done
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" glabbed 2>&1 >/dev/null) || true
assert_contains "$err" 'forge=forgejo' "the unknown-forge refusal did not name forge=forgejo as an accepted value"
pass "fm-project-mode: a value outside none|gerrit|forgejo is refused and the refusal names forge=forgejo"

[ "$(run_forge missing-project)" = "none" ] || fail "a missing project must default --forge to none: $(run_forge missing-project)"
[ "$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --forge legacy 2>/dev/null)" = "none" ] \
  || fail "an absent registry file must default --forge to none"
pass "fm-project-mode: a missing project or absent registry defaults --forge to none"

for name in 'tools\new' 'tools\tree'; do
  [ "$(run_mode "$name")" = 'local-only off' ] || fail "literal backslash name lost its local-only posture: $name"
  [ "$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --branch-prefix "$name")" = private/ ] \
    || fail "literal backslash name lost its branch prefix: $name"
done
[ "$(run_mode 'tools\branch')" = 'direct-PR on' ] || fail "literal backslash name lost its registered posture"
[ "$(run_forge 'tools\branch')" = forgejo ] || fail "literal backslash name lost its registered forge"
pass "fm-project-mode: backslashes in project names remain literal across posture, prefix, and forge queries"

for name in unterminated prose-bracket unfinished-policy; do
  for flag in '' --raw --forge --branch-prefix; do
    # shellcheck disable=SC2086 # An empty flag must expand to nothing.
    out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag "$name" 2> "$TMP_ROOT/error") \
      || fail "unterminated annotation no longer retains the tolerant default for $name $flag"
    case "$flag" in
      --forge) expected=none ;;
      --branch-prefix) expected=fm/ ;;
      *) expected='no-mistakes off' ;;
    esac
    [ "$out" = "$expected" ] || fail "unterminated annotation changed the default for $name $flag: $out"
    assert_contains "$(cat "$TMP_ROOT/error")" 'unterminated posture annotation' 'annotation warning did not name the malformed record'
  done
done
pass "fm-project-mode: an unterminated annotation never interprets description text as policy"

cat >> "$DATA/projects.md" <<'EOF'
- conflict-forward [direct-PR +yolo forge=gerrit forge=forgejo branch=review/] - conflicting providers
- conflict-reverse [direct-PR +yolo forge=forgejo forge=gerrit branch=review/] - reversed providers
- conflict-empty [direct-PR forge= forge=forgejo branch=review/] - hidden empty binding
- conflict-unknown [direct-PR forge=other forge=forgejo branch=review/] - hidden unknown binding
- conflict-final-empty [direct-PR forge=forgejo forge= branch=review/] - empty final binding
- conflict-final-unknown [direct-PR forge=forgejo forge=other branch=review/] - unknown final binding
- repeat-forgejo [direct-PR +yolo forge=forgejo forge=forgejo] - same binding repeated
- repeat-gerrit [direct-PR +yolo forge=gerrit forge=gerrit] - same binding repeated
EOF
for name in conflict-forward conflict-reverse conflict-empty conflict-unknown conflict-final-empty conflict-final-unknown; do
  for flag in '' --raw --forge; do
    status=0
    # shellcheck disable=SC2086 # An empty flag expands to no option.
    out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag "$name" 2> "$TMP_ROOT/forge-conflict-error") || status=$?
    [ "$status" -eq 3 ] && [ -z "$out" ] || fail "$name $flag resolved a conflicting forge binding"
    assert_contains "$(cat "$TMP_ROOT/forge-conflict-error")" 'conflicting forge bindings' "forge conflict refusal did not explain the ambiguity"
  done
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --branch-prefix "$name" 2> "$TMP_ROOT/forge-conflict-error") \
    || fail "a forge conflict prevented the orthogonal prefix query"
  [ "$out" = review/ ] && [ ! -s "$TMP_ROOT/forge-conflict-error" ] || fail "a forge conflict changed the registered prefix"
done
[ "$(run_mode repeat-forgejo)" = 'direct-PR on' ] && [ "$(run_forge repeat-forgejo)" = forgejo ] \
  || fail "repeating one Forgejo binding changed its meaning"
[ "$(run_mode repeat-gerrit)" = 'direct-PR off' ] && [ "$(run_forge repeat-gerrit)" = gerrit ] \
  || fail "repeating one Gerrit binding changed its meaning or enabled yolo"
pass "fm-project-mode: conflicting forge bindings refuse while identical repeats and prefix queries retain their meaning"

echo "# fm-project-mode.test.sh: all assertions passed"

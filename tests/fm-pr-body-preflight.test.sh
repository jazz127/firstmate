#!/usr/bin/env bash
# Exercise the draft-body command through its public CLI and pin the reporting
# boundary's exact evidence refusals before a PR is published.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-body-preflight)
worktree="$TMP_ROOT/worktree"
task_tmp="$TMP_ROOT/task-temp"
outside="$TMP_ROOT/outside"
draft="$worktree/draft.md"
artifact="$worktree/evidence.txt"
mkdir -p "$worktree" "$task_tmp" "$outside"
printf '%s\n' 'captured output' > "$artifact"
printf '%s\n' 'outside output' > "$outside/evidence.txt"

preflight() {
  "$ROOT/bin/fm-pr-body-preflight.sh" "$draft" "$worktree" "$task_tmp" 2>&1
}

refuses() {  # <case> <exact-checker-message>
  local name=$1 expected=$2 output rc
  output=$(preflight)
  rc=$?
  [ "$rc" -eq 1 ] || fail "$name: expected refusal, got exit $rc: $output"
  [ "$output" = "$expected" ] || fail "$name: expected '$expected', got '$output'"
  pass "$name: preflight preserves the evidence validator refusal"
}

cat > "$draft" <<EOF
## Testing

External validation passed.
evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
output=$(preflight) || fail "valid body was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "valid body did not report success: $output"
pass "valid draft body passes preflight"

printf '%s\n' 'External validation passed.' > "$draft"
refuses 'missing artifact' 'evidence claim refused: missing evidence-artifact: path'

cat > "$draft" <<EOF
External validation passed.
- evidence-artifact: $artifact
- evidence-command: cat $artifact
- evidence-captured: 2026-09-25T00:39:26Z
EOF
refuses 'bullet-prefixed metadata' 'evidence claim refused: missing evidence-artifact: path'

printf '%s\n' '2 of 3 mocked-fetch scenarios driven live against the product.' > "$draft"
refuses 'mocked fetch labelled live without provenance' 'evidence claim refused: missing evidence-artifact: path'

cat > "$draft" <<EOF
External validation passed.
evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25 08:39:26 UTC
EOF
refuses 'non-ISO capture time' 'evidence claim refused: invalid evidence-captured timestamp: 2026-09-25 08:39:26 UTC'

cat > "$draft" <<EOF
External validation passed.
evidence-artifact: $outside/evidence.txt
evidence-command: cat $outside/evidence.txt
evidence-captured: 2026-09-25T00:39:26Z
EOF
refuses 'artifact outside allowed roots' "evidence claim refused: artifact is outside the worker worktree or task temp directory: $outside/evidence.txt"

cat > "$draft" <<EOF
External validation passed.
evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25T00:39:26Z
evidence-artifact: $artifact
EOF
refuses 'duplicate metadata blocks' 'evidence claim refused: duplicate evidence-artifact metadata'

cat > "$draft" <<EOF
## Testing

- Live validation: inconclusive - 0 of 5 scenarios driven live against the product

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| Synthetic fixture run | pass | no | local fixture |

evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25T00:39:26Z
EOF
output=$(preflight) || fail "pipeline-shaped body with one metadata block was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "pipeline-shaped body did not report success: $output"
pass "pipeline-shaped body can mechanically pass with one metadata block"

# These fixture bodies model the split between an honest scenario table and a
# generated appendix. The readback boundary must name the contradiction even
# when the appendix has no provenance block of its own.
cat > "$draft" <<EOF
## Testing

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| Account A | pass | yes | captured account output |
| Account B | pass | fixture-based | local fixture |
| Account C | pass | fixture-based | local fixture |
| Account D | pass | fixture-based | local fixture |

1 of 4 scenarios driven live against the product.
evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25T00:39:26Z
EOF
output=$(preflight) || fail "consistent scenario body was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "consistent scenario body did not pass: $output"
pass "one consistent driven-scenario statement passes"

cat >> "$draft" <<'EOF'

Generated appendix: 0 of 4 scenarios driven live against the product.
EOF
output=$(preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "contradictory appendix was accepted: $output"
assert_contains "$output" 'evidence claim refused: contradictory driven-scenario results:' "contradiction reason was missing"
assert_contains "$output" '1 of 4 scenarios driven live against the product.' "honest count was not quoted"
assert_contains "$output" 'Generated appendix: 0 of 4 scenarios driven live against the product.' "generated count was not quoted"
pass "split appendix count is refused with both conflicting lines"

sed '/^evidence-/d' "$draft" > "$task_tmp/no-metadata.md"
mv "$task_tmp/no-metadata.md" "$draft"
output=$(preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "contradictory appendix without metadata was accepted: $output"
assert_contains "$output" 'evidence claim refused: contradictory driven-scenario results:' "contradiction was hidden by missing metadata"
pass "contradiction takes precedence over a generic missing-metadata refusal"

sed '/^Generated appendix:/d' "$draft" > "$task_tmp/corrected.md"
mv "$task_tmp/corrected.md" "$draft"
cat >> "$draft" <<EOF
evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25T00:39:26Z
EOF
output=$(preflight) || fail "corrected scenario body was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "corrected scenario body did not pass: $output"
pass "corrected scenario body passes"

sed 's/1 of 4 scenarios driven live/0 of 4 scenarios driven live/' "$draft" > "$task_tmp/pr30.md"
mv "$task_tmp/pr30.md" "$draft"
output=$(preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "table-contradicting appendix was accepted: $output"
assert_contains "$output" 'evidence claim refused: contradictory driven-scenario results:' "table contradiction reason was missing"
assert_contains "$output" '0 of 4 scenarios driven live against the product.' "contradicting count was not quoted"
assert_contains "$output" '| Account A | pass | yes | captured account output |' "conflicting table row was not quoted"
pass "table and count contradiction is refused"

sed 's/0 of 4 scenarios driven live/1 of 4 scenarios driven live/' "$draft" > "$task_tmp/corrected.md"
mv "$task_tmp/corrected.md" "$draft"
output=$(preflight) || fail "corrected table count was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "corrected table count did not pass: $output"
pass "corrected table and count pass"

sed 's/1 of 4 scenarios driven live/3 of 5 scenarios driven live/' "$draft" > "$task_tmp/total-mismatch.md"
mv "$task_tmp/total-mismatch.md" "$draft"
output=$(preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "table and incompatible total were accepted: $output"
assert_contains "$output" 'evidence claim refused: contradictory driven-scenario results:' "total mismatch reason was missing"
assert_contains "$output" '3 of 5 scenarios driven live against the product.' "incompatible total was not quoted"
assert_contains "$output" '| Account A | pass | yes | captured account output |' "table rows were not quoted for total mismatch"
pass "table and incompatible driven-scenario total is refused"

sed 's/3 of 5 scenarios driven live/1 of 4 scenarios driven live/' "$draft" > "$task_tmp/corrected-total.md"
mv "$task_tmp/corrected-total.md" "$draft"

sed 's/1 of 4 scenarios driven live/Live validation: passed - 1 of 4 scenarios driven live/' "$draft" > "$task_tmp/verdict.md"
mv "$task_tmp/verdict.md" "$draft"
output=$(preflight) || fail "partly live passed verdict was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "partly live passed verdict did not pass: $output"
pass "passed verdict with a driven scenario remains consistent"

sed -e 's/| Account A | pass | yes | captured account output |/| Account A | pass | fixture-based | local fixture |/' \
  -e 's/Live validation: passed - 1 of 4 scenarios driven live/Live validation: passed - unrelated API smoke check/' \
  "$draft" > "$task_tmp/unrelated-passed.md"
mv "$task_tmp/unrelated-passed.md" "$draft"
output=$(preflight) || fail "fixture-only table with unrelated passed validation was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "unrelated passed validation did not pass: $output"
pass "unrelated passed validation beside a fixture-only table is accepted"

fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
[ "$1" = pr ] && [ "$2" = view ] && [ "$3" = 19 ] && [ "$4" = -R ] && [ "$5" = owner/repo ] && [ "$6" = --hostname ] && [ "$7" = github.com ] && [ "$8" = --full ] || exit 2
printf 'pull_request:\n  body: %s\n' "$(jq -Rs . "$FAKE_PR_BODY")"
EOF
chmod +x "$fakebin/gh-axi"
published_fixture="$TMP_ROOT/published.md"
readback="$task_tmp/pr-body-readback.md"
printf '%s\n' 'External validation passed.' > "$published_fixture"
output=$(PATH="$fakebin:$PATH" FAKE_PR_BODY="$published_fixture" "$ROOT/bin/fm-pr-body-preflight.sh" \
  --gh-url https://github.com/owner/repo/pull/19 "$readback" "$worktree" "$task_tmp" 2>&1)
rc=$?
[ "$rc" -eq 1 ] || fail "published-body readback accepted missing metadata: $output"
[ "$output" = 'evidence claim refused: missing evidence-artifact: path' ] \
  || fail "published-body readback changed the validator refusal: $output"
cmp -s "$published_fixture" "$readback" || fail "published-body readback did not save the exact body"
pass "published-body readback refuses a bad body and saves it for correction"

cat > "$readback" <<EOF
External validation passed.
evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25T00:39:26Z
EOF
output=$("$ROOT/bin/fm-pr-body-preflight.sh" "$readback" "$worktree" "$task_tmp" 2>&1) \
  || fail "corrected draft was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "corrected draft did not pass: $output"
cp "$readback" "$published_fixture"
output=$(PATH="$fakebin:$PATH" FAKE_PR_BODY="$published_fixture" "$ROOT/bin/fm-pr-body-preflight.sh" \
  --gh-url https://github.com/owner/repo/pull/19 "$readback" "$worktree" "$task_tmp" 2>&1) \
  || fail "corrected published-body readback was refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "corrected published body did not pass: $output"
pass "corrected published-body readback passes the same validator"

printf '%s\n' 'all fm-pr-body-preflight tests passed'

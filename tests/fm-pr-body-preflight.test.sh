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
artifact=evidence.txt
mkdir -p "$worktree" "$task_tmp" "$outside"
printf '%s\n' 'captured output' > "$worktree/$artifact"
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
evidence-artifact: ../outside/evidence.txt
evidence-command: cat ../outside/evidence.txt
evidence-captured: 2026-09-25T00:39:26Z
EOF
refuses 'artifact outside allowed roots' "evidence claim refused: artifact is outside the worker worktree or task temp directory: $worktree/../outside/evidence.txt"

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

sed 's/1 of 4 scenarios driven live/1 of 5 scenarios driven live/' "$draft" > "$task_tmp/total-only-mismatch.md"
mv "$task_tmp/total-only-mismatch.md" "$draft"
output=$(preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "table and incompatible total-only mismatch were accepted: $output"
assert_contains "$output" 'evidence claim refused: contradictory driven-scenario results:' "total-only mismatch reason was missing"
assert_contains "$output" '1 of 5 scenarios driven live against the product.' "total-only mismatch was not quoted"
pass "table and incompatible total-only mismatch is refused"

sed 's/1 of 5 scenarios driven live/1 of 4 scenarios driven live/' "$draft" > "$task_tmp/corrected-total-only.md"
mv "$task_tmp/corrected-total-only.md" "$draft"

sed -e 's/| Account A | pass | yes | captured account output |/| Account A | pass | fixture-based | local fixture |/' \
  -e 's/1 of 4 scenarios driven live/0 of 5 scenarios driven live/' \
  "$draft" > "$task_tmp/fixture-total-mismatch.md"
mv "$task_tmp/fixture-total-mismatch.md" "$draft"
output=$(preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "fixture table and incompatible total were accepted: $output"
assert_contains "$output" 'evidence claim refused: contradictory driven-scenario results:' "fixture total mismatch reason was missing"
assert_contains "$output" '0 of 5 scenarios driven live against the product.' "fixture total mismatch was not quoted"
pass "fully classified fixture table rejects an incompatible total"

sed -e 's/| Account A | pass | fixture-based | local fixture |/| Account A | pass | yes | captured account output |/' \
  -e 's/0 of 5 scenarios driven live/1 of 4 scenarios driven live/' \
  "$draft" > "$task_tmp/corrected-fixture-total.md"
mv "$task_tmp/corrected-fixture-total.md" "$draft"

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

cat > "$fakebin/tea" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = login ] && [ "$2" = list ]; then
  printf '[{"name":"fixture","url":"https://forge.example.test"}]\n'
else
  [ "$*" = 'api --login fixture --repo owner/repo /repos/{owner}/{repo}/pulls/19' ] || exit 2
  jq -n --rawfile body "$FAKE_PR_BODY" '{state:"open",merged:false,head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},body:$body}'
fi
EOF
chmod +x "$fakebin/tea"
printf '%s' 'External validation passed.' > "$published_fixture"
output=$(PATH="$fakebin:$PATH" FAKE_PR_BODY="$published_fixture" "$ROOT/bin/fm-pr-body-preflight.sh" \
  --forgejo-url https://forge.example.test/owner/repo/pulls/19 "$readback" "$worktree" "$task_tmp" 2>&1)
rc=$?
expect_code 1 "$rc" "Forgejo readback must apply evidence enforcement"
assert_contains "$output" 'evidence claim refused: missing evidence-artifact: path' "Forgejo lost evidence validation"
cmp -s "$published_fixture" "$readback" || fail "Forgejo did not save the readback for correction"
printf 'External validation passed.\nevidence-artifact: %s\nevidence-command: cat %s\nevidence-captured: 2026-09-25T00:39:26Z' \
  "$artifact" "$artifact" > "$published_fixture"
output=$(PATH="$fakebin:$PATH" FAKE_PR_BODY="$published_fixture" "$ROOT/bin/fm-pr-body-preflight.sh" \
  --forgejo-url https://forge.example.test/owner/repo/pulls/19 "$readback" "$worktree" "$task_tmp" 2>&1) \
  || fail "valid Forgejo published evidence refused: $output"
[ "$output" = 'evidence preflight ok' ] || fail "Forgejo evidence did not pass: $output"
cmp -s "$published_fixture" "$readback" || fail "Forgejo valid readback differs"
pass "Forgejo published-body readback preserves evidence validation"

scratch_repo="$TMP_ROOT/scratch-repo"
mkdir -p "$scratch_repo"
git -C "$scratch_repo" init -q -b main || fail "could not create the synthetic scratch checkout"
git -C "$scratch_repo" config user.name Fixture
git -C "$scratch_repo" config user.email fixture@example.test
printf '%s\n' 'product' > "$scratch_repo/product.txt"
git -C "$scratch_repo" add product.txt
git -C "$scratch_repo" commit -qm 'fixture base'
scratch_preflight() {
  "$ROOT/bin/fm-pr-body-preflight.sh" --scratch "$scratch_repo" 2>&1
}
output=$(scratch_preflight) || fail "clean synthetic checkout was refused: $output"
[ "$output" = 'scratch preflight ok' ] || fail "clean synthetic checkout did not pass: $output"
printf '%s\n' '.codex-live-check/' > "$scratch_repo/.gitignore"
mkdir -p "$scratch_repo/.codex-live-check/cache/node/corepack/v1/pnpm/11.1.1"
printf '%s\n' 'bundle' > "$scratch_repo/.codex-live-check/cache/node/corepack/v1/pnpm/11.1.1/package.json"
output=$(scratch_preflight)
rc=$?
[ "$rc" -eq 0 ] || fail "ignored untracked scratch changed the publication preflight: $output"
git -C "$scratch_repo" checkout -q -b feature
git -C "$scratch_repo" add -f .codex-live-check
output=$(scratch_preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "staged Corepack bundle passed the scratch preflight"
assert_contains "$output" '.codex-live-check/cache/node/corepack/v1/pnpm/11.1.1/package.json' \
  "staged scratch refusal did not name its path"
git -C "$scratch_repo" commit -qm 'fixture scratch bundle'
git -C "$scratch_repo" reset -q -- .codex-live-check
output=$(scratch_preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "committed Corepack bundle passed the publication preflight"
assert_contains "$output" '.codex-live-check/cache/node/corepack/v1/pnpm/11.1.1/package.json' \
  "committed scratch refusal did not name its path"
git -C "$scratch_repo" reset --hard -q HEAD^ \
  || fail "could not remove the temporary committed scratch fixture"
rm -rf "$scratch_repo/.codex-live-check"
mkdir -p "$scratch_repo/feature/.pnpm-store"
printf '%s\n' 'cache' > "$scratch_repo/feature/.pnpm-store/item"
git -C "$scratch_repo" add -f feature/.pnpm-store
output=$(scratch_preflight)
rc=$?
[ "$rc" -eq 1 ] || fail "nested pnpm store passed the scratch preflight"
assert_contains "$output" 'feature/.pnpm-store/item' \
  "nested scratch refusal did not name its path"
git -C "$scratch_repo" reset -q -- feature/.pnpm-store
rm -rf "$scratch_repo/feature"
output=$(scratch_preflight) || fail "cleaned synthetic checkout was refused: $output"
[ "$output" = 'scratch preflight ok' ] || fail "cleaned synthetic checkout did not pass"
pass "scratch preflight refuses staged and committed cache bundles by path"

# These are synthetic publication fixtures, not external verification claims.
for raw in '/tmp/fm-other/proof.txt' '/private/tmp/fm-other/proof.txt' \
  '/home/worker/proof.txt' '/Users/worker/proof.txt' "$worktree/proof.txt" "$task_tmp/proof.txt"; do
  # shellcheck disable=SC2016 # Literal Markdown backticks in a synthetic body.
  printf 'Synthetic output: `%s`\n' "$raw" > "$draft"
  output=$(preflight)
  expect_code 1 "$?" "raw path without an evidence claim passed: $raw"
  assert_contains "$output" '<task-output>/' 'raw-path refusal omitted the scratch convention'
  assert_contains "$output" '<firstmate-home>/' 'raw-path refusal omitted the home convention'
  assert_contains "$output" 'config/published-path-prefixes' 'refusal omitted the host-doc override'
done
printf 'Synthetic output: %s\n' "$outside/result.txt" > "$draft"
output=$(FM_HOME="$outside" preflight)
expect_code 1 "$?" 'nonstandard Firstmate home path passed'
pass 'publication refuses raw task, user-home and configured-home paths in ordinary prose'

printf '%s\n' 'captured task output' > "$task_tmp/proof.txt"
for portable in '<task-output>/proof.txt' '<firstmate-home>/task-temp/proof.txt' evidence.txt; do
  cat > "$draft" <<EOF
External validation passed.
evidence-artifact: $portable
evidence-command: cat '$portable'
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
  output=$(FM_HOME="$TMP_ROOT" preflight) || fail "portable artifact refused: $portable: $output"
  assert_equals 'evidence preflight ok' "$output" 'descriptor round trip did not pass'
done
# Commands are publication text too, even when the artifact uses a descriptor.
printf 'evidence-command: cat %s\n' "$task_tmp/proof.txt" > "$draft"
output=$(preflight)
expect_code 1 "$?" 'raw command path passed without a claim'
assert_contains "$output" 'worker-local absolute path' 'raw command refusal was unclear'
pass 'portable artifacts resolve to readable worktree/task files and commands cannot leak raw paths'

for portable in fixtures/home/proof.txt fixtures/Users/proof.txt fixtures/tmp/fm-task/proof.txt \
  fixtures/private/tmp/fm-task/proof.txt fixtures/srv/firstmate/proof.txt \
  ./fixtures/home/proof.txt; do
  mkdir -p "$worktree/$(dirname "$portable")"
  printf '%s\n' 'synthetic fixture output' > "$worktree/$portable"
  cat > "$draft" <<EOF
Synthetic output: $portable.
External validation passed.
evidence-artifact: $portable
evidence-command: cat '$portable'
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
  output=$(FM_HOME=/srv/firstmate preflight) || fail "relative path was misclassified: $portable: $output"
  assert_equals 'evidence preflight ok' "$output" 'relative artifact, command and prose did not pass'
done
pass 'relative paths containing worker-root names stay repository-relative in every body field'

mkdir -p "$task_tmp/home" "$task_tmp/tmp/fm-fixture"
printf '%s\n' 'synthetic fixture output' > "$task_tmp/home/proof.txt"
printf '%s\n' 'synthetic fixture output' > "$task_tmp/tmp/fm-fixture/proof.txt"
for portable in '<task-output>/home/proof.txt' '<task-output>/tmp/fm-fixture/proof.txt' \
  '<firstmate-home>/task-temp/home/proof.txt'; do
  cat > "$draft" <<EOF
Synthetic output: $portable.
External validation passed.
evidence-artifact: $portable
evidence-command: cat '$portable'
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
  output=$(FM_HOME="$TMP_ROOT" preflight) || fail "descriptor suffix was misclassified: $portable: $output"
done
pass 'descriptor suffixes containing worker-root names stay portable in every body field'

for raw in /srv/firstmate /srv/worktree /srv/task-output /srv/user-home; do
  for suffix in '' . '!' '?' : , ';' ')' ']' '}'; do
    for field in 'Synthetic output' evidence-artifact evidence-command; do
      printf '%s: %s%s\n' "$field" "$raw" "$suffix" > "$draft"
      output=$(HOME=/srv/user-home FM_HOME=/srv/firstmate "$ROOT/bin/fm-pr-body-preflight.sh" \
        "$draft" /srv/worktree /srv/task-output 2>&1)
      expect_code 1 "$?" "punctuated worker root passed: $field: $raw$suffix"
      assert_contains "$output" 'worker-local absolute path' 'punctuated root refusal was unclear'
    done
  done
done
printf '%s\n' 'Synthetic output: /srv/firstmate-other.' > "$draft"
output=$(FM_HOME=/srv/firstmate preflight) || fail "custom home matched an unrelated path: $output"
pass 'custom roots are refused before punctuation with consistent prose, artifact and command boundaries'

for portable in '<task-output>/../outside/evidence.txt' '<firstmate-home>/outside/evidence.txt' \
  '<task-output>/missing.txt' '<unknown>/proof.txt' '<task-output>/escape.txt' '<task-output>/nested/evidence.txt'; do
  ln -sf "$outside/evidence.txt" "$task_tmp/escape.txt"
  [ -L "$task_tmp/nested" ] || ln -s "$outside" "$task_tmp/nested"
  cat > "$draft" <<EOF
External validation passed.
evidence-artifact: $portable
evidence-command: ./collect
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
  output=$(FM_HOME="$TMP_ROOT" preflight)
  expect_code 1 "$?" "descriptor bypassed evidence integrity: $portable"
  case "$portable" in
    *../*|'<firstmate-home>/outside/'*) expected='outside the worker worktree or task temp directory' ;;
    *missing*) expected='missing or unreadable' ;;
    '<unknown>'*) expected='unknown artifact descriptor' ;;
    *) expected='resolved artifact is outside the allowed roots' ;;
  esac
  assert_contains "$output" "$expected" 'descriptor lost the expected evidence integrity guard'
done
pass 'descriptors preserve missing-file, unknown-descriptor, traversal and symlink refusals'

# A project key is the Git common directory, shared with linked worktrees.
policy_repo="$TMP_ROOT/policy-repo"
policy_home="$TMP_ROOT/policy-home"
mkdir -p "$policy_repo" "$policy_home/config"
git -C "$policy_repo" init -q -b main || fail 'policy project fixture init failed'
common=$(cd "$policy_repo/.git" && pwd -P)
policy_preflight() {
  FM_HOME="$policy_home" "$ROOT/bin/fm-pr-body-preflight.sh" "$draft" "$policy_repo" "$task_tmp" 2>&1
}
printf '%s\n' 'Host config: /home/ops/estate/config.toml' > "$draft"
output=$(policy_preflight)
expect_code 1 "$?" 'absent override allowed a home path'
printf '%s %s %s' "$common" /home/ops/host-config /home/ops/estate > "$policy_home/config/published-path-prefixes"
for raw in '/home/ops/estate/config.toml' '/home/ops/host-config' "'/home/ops/estate'"; do
  printf 'Host config: %s\n' "$raw" > "$draft"
  output=$(policy_preflight) || fail "allowed host prefix refused: $raw: $output"
done
for raw in '/home/ops/estate-other/config.toml' '/home/ops/estate/../secret' \
  '/home/ops/unlisted' '/tmp/fm-other/proof.txt' '/home/ops/estate/tmp/fm-other/proof.txt'; do
  printf 'Host config: %s\n' "$raw" > "$draft"
  output=$(policy_preflight)
  expect_code 1 "$?" "override allowed an unapproved path: $raw"
done
printf '\n%s %s\n' "$common" "$task_tmp" >> "$policy_home/config/published-path-prefixes"
printf 'Output: %s/proof.txt\n' "$task_tmp" > "$draft"
output=$(policy_preflight)
expect_code 1 "$?" 'override allowed the recorded scratch root'
printf '%s %s\n' "$TMP_ROOT/another-project/.git" /home/ops/estate > "$policy_home/config/published-path-prefixes"
printf '%s\n' 'Host config: /home/ops/estate/config.toml' > "$draft"
output=$(policy_preflight)
expect_code 1 "$?" 'override escaped its project key'
printf '%s /\n' "$common" > "$policy_home/config/published-path-prefixes"
output=$(policy_preflight)
expect_code 1 "$?" 'root override did not fail closed'
pass 'project-scoped home prefixes allow host docs, with component boundaries and no scratch exemption'

printf '%s\n' 'all fm-pr-body-preflight tests passed'

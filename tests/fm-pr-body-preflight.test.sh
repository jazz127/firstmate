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

scratch_repo="$TMP_ROOT/scratch-repo"
mkdir -p "$scratch_repo"
git -C "$scratch_repo" init -q || fail "could not create the synthetic scratch checkout"
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

printf '%s\n' 'all fm-pr-body-preflight tests passed'

#!/usr/bin/env bash
# Bosun routing, memory, authorization, and merge-hook behavior.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-bosun)
CLI="$ROOT/bin/fm-bosun.py"

call() { FM_HOME="$1" python3 "$CLI" "${@:2}"; }

new_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/data" "$dir/config" "$dir/state"
  printf '%s\n' "$dir"
}

routes_fixture() {
  cat > "$1/config/bosun-routes.json" <<'EOF'
{"schema":"fm-bosun-routes.v1","routes":[
  {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository_pattern":"*","fork_owner":"captain","fork_repository":"sample","upstream_default_branch":"main"},
  {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository":"special","fork_owner":"captain","fork_repository":"special","upstream_default_branch":"main"}
]}
EOF
}

setup_bosun() {
  local dir=$1
  routes_fixture "$dir"
  printf '%s\n' bosun-kun > "$dir/.fm-secondmate-home"
  call "$dir" configure-home --bosun bosun-kun >/dev/null || fail 'Bosun home setup failed'
}

test_routing() {
  local dir out unsupported
  dir=$(new_home routing)
  setup_bosun "$dir"
  out=$(call "$dir" route --forge github --owner kunchenguid --repository special) || fail 'exact route failed'
  [ "$out" = bosun-kun ] || fail 'exact route picked another Bosun'
  out=$(call "$dir" route --forge github --owner kunchenguid --repository sample) || fail 'pattern route failed'
  [ "$out" = bosun-kun ] || fail 'pattern route picked another Bosun'
  if call "$dir" route --forge github --owner other --repository sample > "$dir/out" 2>&1; then
    fail 'unmatched route silently selected a Bosun'
  fi
  assert_grep 'ask whether to create one' "$dir/out" 'no match did not request Bosun creation'
  unsupported=$(new_home unsupported-forge)
  cat > "$unsupported/config/bosun-routes.json" <<'EOF'
{"schema":"fm-bosun-routes.v1","routes":[{"bosun":"bosun-kun","forge":"gerrit","owner":"kunchenguid"}]}
EOF
  if call "$unsupported" route --forge github --owner kunchenguid --repository sample > "$unsupported/out" 2>&1; then
    fail 'unsupported forge route was accepted'
  fi
  assert_grep "unsupported Bosun forge 'gerrit'; supported: github" "$unsupported/out" 'unsupported forge diagnostic missing'
  pass 'route precedence, no match, and unsupported forge refusal'
}

test_memory_and_paths() {
  local dir outside
  dir=$(new_home memory)
  setup_bosun "$dir"
  printf '{"format":"policy"}\n' > "$dir/policy.json"
  call "$dir" convention --bosun bosun-kun --forge github --owner kunchenguid --repository sample \
    --scope shared --key format --value shared --confirmed --evidence CONTRIBUTING.md \
    --showed format --read-at 2026-09-25T00:00:00Z || fail 'convention recording failed'
  printf '%s' "$(call "$dir" conventions --bosun bosun-kun --forge github --owner kunchenguid --repository sample --policy "$dir/policy.json")" \
    | jq -e '.format.source == "current_repository_policy"' >/dev/null || fail 'policy precedence failed'
  outside="$TMP_ROOT/outside"
  mkdir -p "$outside"
  rm -f "$dir/data/bosun-role.json"
  mv "$dir/data" "$outside/data"
  ln -s "$outside/data" "$dir/data"
  if call "$dir" configure-home --bosun bosun-kun > "$dir/out" 2>&1; then
    fail 'symlinked FM_HOME ancestor was accepted'
  fi
  [ ! -e "$outside/data/bosun-role.json" ] || fail 'symlinked ancestor received state'
  pass 'evidence memory and FM_HOME path safety'
}

fake_github() {
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${FM_FAKE_GH_CASE:-accepted}" in
accepted) printf '%s\n' '{"headRepositoryOwner":{"login":"captain"},"headRepository":{"name":"sample"},"baseRepository":{"nameWithOwner":"kunchenguid/sample"},"baseRefName":"main","headRefOid":"0123456789012345678901234567890123456789"}' ;;
unrelated) printf '%s\n' '{"headRepositoryOwner":{"login":"other"},"headRepository":{"name":"sample"},"baseRepository":{"nameWithOwner":"kunchenguid/sample"},"baseRefName":"main","headRefOid":"0123456789012345678901234567890123456789"}' ;;
wrong-base) printf '%s\n' '{"headRepositoryOwner":{"login":"captain"},"headRepository":{"name":"sample"},"baseRepository":{"nameWithOwner":"other/sample"},"baseRefName":"main","headRefOid":"0123456789012345678901234567890123456789"}' ;;
unreadable) exit 1 ;;
esac
EOF
  chmod +x "$1/fakebin/gh"
}

ordered_home() {
  local dir=$1
  setup_bosun "$dir"
  call "$dir" order --task maneuver --bosun bosun-kun --maneuver maneuver \
    --forge github --owner kunchenguid --repository sample --source housefeature/maneuver \
    --branch contribution/maneuver --captain-words 'Contribute maneuver' --path feature.txt \
    --commit 0123456789012345678901234567890123456789 >/dev/null || fail 'order recording failed'
  fake_github "$dir"
}

test_registration_and_merge() {
  local dir accepted_dir url case_dir out response head base branch pr_head
  url=https://github.com/kunchenguid/sample/pull/12
  dir=$(new_home accepted)
  accepted_dir=$dir
  ordered_home "$dir"
  response=$(FM_FAKE_GH_CASE=accepted PATH="$dir/fakebin:$PATH" gh pr view "$url") || fail 'accepted forge response unreadable'
  head=$(printf '%s' "$response" | jq -r '.headRepositoryOwner.login + "/" + .headRepository.name')
  base=$(printf '%s' "$response" | jq -r '.baseRepository.nameWithOwner')
  branch=$(printf '%s' "$response" | jq -r '.baseRefName')
  pr_head=$(printf '%s' "$response" | jq -r '.headRefOid')
  call "$dir" registration-check --task maneuver --url "$url" --forge github --head "$head" \
    --base "$base" --branch "$branch" --pr-head "$pr_head" --validation-head "$pr_head" --validation-mode no-mistakes \
    --upstream-base upstream-sha --changed-path feature.txt || fail 'accepted registration failed'
  jq -e '.state == "published" and .upstream_pr == "'"$url"'" and .validation_evidence.pr_head == "'"$pr_head"'" and .upstream_changed_paths == ["feature.txt"]' "$dir/data/maneuver/bosun-contribution.json" >/dev/null \
    || fail 'accepted forge response was not durably registered'
  for case_name in unrelated wrong-base unreadable; do
    case_dir=$(new_home "$case_name")
    ordered_home "$case_dir"
    export FM_FAKE_GH_CASE="$case_name"
    if response=$(PATH="$case_dir/fakebin:$PATH" gh pr view "$url" 2>"$case_dir/out"); then
      head=$(printf '%s' "$response" | jq -r '.headRepositoryOwner.login + "/" + .headRepository.name')
      base=$(printf '%s' "$response" | jq -r '.baseRepository.nameWithOwner')
      branch=$(printf '%s' "$response" | jq -r '.baseRefName')
      pr_head=$(printf '%s' "$response" | jq -r '.headRefOid')
      call "$case_dir" registration-check --task maneuver --url "$url" --forge github --head "$head" \
        --base "$base" --branch "$branch" --pr-head "$pr_head" --validation-head "$pr_head" --validation-mode no-mistakes \
        --upstream-base upstream-sha --changed-path feature.txt >"$case_dir/out" 2>&1 && fail "$case_name forge response was accepted"
    fi
    unset FM_FAKE_GH_CASE
    jq -e '.state == "ordered" and .upstream_pr == null' "$case_dir/data/maneuver/bosun-contribution.json" >/dev/null \
      || fail "$case_name response changed the durable record"
  done
  dir=$(new_home missing-validation)
  ordered_home "$dir"
  if call "$dir" registration-check --task maneuver --url "$url" --forge github --head captain/sample \
    --base kunchenguid/sample --branch main --pr-head "$pr_head" --validation-head "$pr_head" --validation-mode '' \
    --upstream-base upstream-sha --changed-path feature.txt >"$dir/out" 2>&1; then
    fail 'missing validation evidence was accepted'
  fi
  dir=$(new_home stale-validation)
  ordered_home "$dir"
  if call "$dir" registration-check --task maneuver --url "$url" --forge github --head captain/sample \
    --base kunchenguid/sample --branch main --pr-head "$pr_head" --validation-head stale --validation-mode no-mistakes \
    --upstream-base upstream-sha --changed-path feature.txt >"$dir/out" 2>&1; then
    fail 'stale validation head was accepted'
  fi
  dir=$(new_home out-of-scope)
  ordered_home "$dir"
  if call "$dir" registration-check --task maneuver --url "$url" --forge github --head captain/sample \
    --base kunchenguid/sample --branch main --pr-head "$pr_head" --validation-head "$pr_head" --validation-mode no-mistakes \
    --upstream-base upstream-sha --changed-path secret.txt >"$dir/out" 2>&1; then
    fail 'out-of-scope path was accepted'
  fi
  FM_HOME="$accepted_dir" python3 "$CLI" merged --task maneuver --url "$url" || fail 'merge hook failed'
  jq -e '.state == "admirals-maneuver"' "$accepted_dir/data/maneuver/bosun-contribution.json" >/dev/null \
    || fail 'Admiral maneuver was not recorded'
  pass 'forge-backed authorization and merge completion'
}

test_routing
test_memory_and_paths
test_registration_and_merge

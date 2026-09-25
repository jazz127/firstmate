#!/usr/bin/env bash
# Bosun routing, memory, authorization, and merge-hook behavior.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-bosun)
CLI="$ROOT/bin/fm-bosun.py"

call() {
  local dir=$1
  if [ -n "${FORK_BARE:-}" ]; then
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="url.file://$FORK_BARE.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/captain/sample.git \
    FM_HOME="$dir" python3 "$CLI" "${@:2}"
  else
    FM_HOME="$dir" python3 "$CLI" "${@:2}"
  fi
}

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

prepare_project() {
  local dir=$1 maneuver=${2:-maneuver} project="$1/projects/sample" base source
  export FORK_BARE="$dir/fork.git"
  mkdir -p "$project"
  if [ ! -e "$FORK_BARE" ]; then
    git init --bare -q "$FORK_BARE"
  fi
  if [ ! -e "$project/.git" ]; then
    git -C "$project" init -q
    git -C "$project" config user.email test@example.com
    git -C "$project" config user.name test
    printf '%s\n' fixture > "$project/README.md"
    git -C "$project" add README.md
    git -C "$project" commit -qm fixture
    git -C "$project" remote add fork https://github.com/captain/sample.git
    git -C "$project" remote add upstream https://github.com/kunchenguid/sample.git
  fi
  base=$(git -C "$project" rev-parse --abbrev-ref HEAD)
  if ! git -C "$project" show-ref --verify --quiet "refs/heads/housefeature/$maneuver"; then
    git -C "$project" checkout -qb "housefeature/$maneuver" "$base"
    printf '%s\n' "$maneuver" > "$project/$maneuver.txt"
    git -C "$project" add "$maneuver.txt"
    git -C "$project" commit -qm "$maneuver"
    source=$(git -C "$project" rev-parse HEAD)
    git -C "$project" -c "url.file://$FORK_BARE.insteadOf=https://github.com/captain/sample.git" \
      push -q fork "HEAD:refs/heads/housefeature/$maneuver"
    git -C "$project" checkout -q "$base"
  fi
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

test_order_accepts_dotfiles() {
  local dir commit
  dir=$(new_home dotfiles)
  setup_bosun "$dir"
  prepare_project "$dir" dotfiles
  commit=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/dotfiles)
  call "$dir" order --task dotfiles --bosun bosun-kun --maneuver dotfiles \
    --forge github --owner kunchenguid --repository sample --source housefeature/dotfiles \
    --branch contribution/dotfiles --captain-words 'Contribute dotfiles' \
    --path .github/workflows/ci.yml --path .editorconfig \
    --commit "$commit" >/dev/null || fail 'dotfile order was rejected'
  jq -e '.allowed_paths == [".github/workflows/ci.yml", ".editorconfig"]' \
    "$dir/data/dotfiles/bosun-contribution.json" >/dev/null || fail 'dotfile order paths were not preserved'
  pass 'ordered dotfiles remain valid scoped paths'
}

test_order_rejects_invalid_commit_selection() {
  local dir commit base
  dir=$(new_home invalid-commits)
  setup_bosun "$dir"
  prepare_project "$dir" invalid
  commit=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/invalid)
  if call "$dir" order --task invalid --bosun bosun-kun --maneuver invalid \
    --forge github --owner kunchenguid --repository sample --source housefeature/invalid \
    --branch contribution/invalid --captain-words 'Contribute invalid' --path feature.txt \
    --commit not-a-commit >"$dir/out" 2>&1; then
    fail 'invalid source commit was accepted'
  fi
  if call "$dir" order --task duplicate --bosun bosun-kun --maneuver duplicate \
    --forge github --owner kunchenguid --repository sample --source housefeature/duplicate \
    --branch contribution/duplicate --captain-words 'Contribute duplicate' --path feature.txt \
    --commit "$commit" --commit "$commit" >"$dir/out" 2>&1; then
    fail 'duplicate source commits were accepted'
  fi
  base=$(git -C "$dir/projects/sample" rev-parse HEAD)
  commit=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/invalid)
  if call "$dir" order --task reversed --bosun bosun-kun --maneuver invalid \
    --forge github --owner kunchenguid --repository sample --source housefeature/invalid \
    --branch contribution/reversed --captain-words 'Contribute reversed' --path feature.txt \
    --commit "$commit" --commit "$base" >"$dir/out" 2>&1; then
    fail 'reverse-ordered source commits were accepted'
  fi
  pass 'invalid and duplicate source commits are refused'
}

test_intake_delegates_to_ship_lifecycle() {
  local dir fake_root commit
  dir=$(new_home intake)
  setup_bosun "$dir"
  prepare_project "$dir"
  ordered_home "$dir"
  commit=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/maneuver)
  fake_root="$dir/fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-project-mode.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'no-mistakes off'
EOF
  cat > "$fake_root/bin/fm-brief.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$FM_HOME/data/$1"
printf '%s\n' '{TASK}' '{FIRSTMATE_SPEC}' > "$FM_HOME/data/$1/brief.md"
EOF
  cat > "$fake_root/bin/fm-spawn.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "spawned $1 worktree=$FM_HOME/projects/sample/task-worktree"
EOF
  chmod +x "$fake_root/bin"/*.sh
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$fake_root" python3 "$CLI" intake --task maneuver > "$dir/intake.out" \
    || fail 'intake did not delegate to ordinary ship lifecycle'
  jq -e '.state == "assigned" and .task_mode == "no-mistakes" and .task_yolo == "off" and (.task_worktree | endswith("task-worktree"))' \
    "$dir/data/maneuver/bosun-contribution.json" >/dev/null || { cat "$dir/data/maneuver/bosun-contribution.json" >&2; fail 'intake did not persist assigned task'; }
  if grep -qE '\{TASK\}|\{FIRSTMATE_SPEC\}' "$dir/data/maneuver/brief.md"; then
    fail 'intake left brief placeholders unresolved'
  fi
  assert_grep 'Fetch the latest upstream default branch' "$dir/data/maneuver/brief.md" 'intake omitted clean upstream extraction'
  assert_grep "$commit" "$dir/data/maneuver/brief.md" 'intake omitted ordered source commit'
  assert_grep 'needs-decision' "$dir/data/maneuver/brief.md" 'intake omitted review escalation'
  assert_grep 'spawned maneuver worktree=' "$dir/intake.out" 'intake did not return spawned task'
  pass 'ordered maneuvers delegate exactly once through brief and spawn'
}

test_intake_retries_existing_task() {
  local dir fake_root
  dir=$(new_home intake-retry)
  ordered_home "$dir"
  fake_root="$dir/fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-project-mode.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'no-mistakes off'
EOF
  cat > "$fake_root/bin/fm-brief.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$FM_HOME/data/$1"
printf '%s\n' '{TASK}' '{FIRSTMATE_SPEC}' > "$FM_HOME/data/$1/brief.md"
EOF
  cat > "$fake_root/bin/fm-spawn.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
count_file="$FM_HOME/state/spawn-count"
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
printf '%s\n' $((count + 1)) > "$count_file"
mkdir -p "$FM_HOME/projects/sample/retry-worktree"
git -C "$FM_HOME/projects/sample/retry-worktree" init -q
printf '%s\n' "endpoint_task_id=$1" "worktree=$FM_HOME/projects/sample/retry-worktree" "project=$FM_HOME/projects/sample" "kind=ship" "mode=no-mistakes" "yolo=off" > "$FM_HOME/state/$1.meta"
if [ ! -e "$FM_HOME/state/spawn-failed" ]; then
  : > "$FM_HOME/state/spawn-failed"
  exit 1
fi
printf '%s\n' "spawned $1 worktree=$FM_HOME/projects/sample/retry-worktree"
EOF
  chmod +x "$fake_root/bin"/*.sh
  if FM_HOME="$dir" FM_ROOT_OVERRIDE="$fake_root" python3 "$CLI" intake --task maneuver >"$dir/first.out" 2>&1; then
    fail 'simulated post-spawn failure unexpectedly succeeded'
  fi
  jq -e '.state == "ordered" and .assignment_task == "maneuver"' \
    "$dir/data/maneuver/bosun-contribution.json" >/dev/null || fail 'assignment identity was not persisted'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$fake_root" python3 "$CLI" intake --task maneuver >"$dir/retry.out" \
    || fail 'retry did not adopt the existing task'
  [ "$(cat "$dir/state/spawn-count")" = 1 ] || fail 'retry spawned a second task'
  jq -e '.state == "assigned" and (.task_worktree | endswith("retry-worktree"))' \
    "$dir/data/maneuver/bosun-contribution.json" >/dev/null || fail 'retry did not persist adopted task'
  pass 'intake retries adopt the deterministic existing task'
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
  local dir=$1 commit
  setup_bosun "$dir"
  prepare_project "$dir"
  commit=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/maneuver)
  call "$dir" order --task maneuver --bosun bosun-kun --maneuver maneuver \
    --forge github --owner kunchenguid --repository sample --source housefeature/maneuver \
    --branch contribution/maneuver --captain-words 'Contribute maneuver' --path feature.txt \
    --commit "$commit" >/dev/null || fail 'order recording failed'
  fake_github "$dir"
}

test_fork_source_validation() {
  local dir commit tree off
  dir=$(new_home fork-source)
  setup_bosun "$dir"
  prepare_project "$dir" fork-only
  commit=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/fork-only)
  call "$dir" order --task fork-only --bosun bosun-kun --maneuver fork-only \
    --forge github --owner kunchenguid --repository sample --source housefeature/fork-only \
    --branch contribution/fork-only --captain-words 'Contribute fork-only' --path feature.txt \
    --commit "$commit" >/dev/null || fail 'fork-only source commit was rejected'
  tree=$(git -C "$dir/projects/sample" rev-parse HEAD^{tree})
  off=$(printf '%s\n' unrelated | git -C "$dir/projects/sample" commit-tree "$tree")
  dir=$(new_home fork-off-branch)
  setup_bosun "$dir"
  prepare_project "$dir" fork-off-branch
  if call "$dir" order --task fork-off-branch --bosun bosun-kun --maneuver fork-off-branch \
    --forge github --owner kunchenguid --repository sample --source housefeature/fork-off-branch \
    --branch contribution/fork-off-branch --captain-words 'Contribute off branch' --path feature.txt \
    --commit "$off" >"$dir/out" 2>&1; then
    fail 'off-branch source commit was accepted'
  fi
  pass 'source commits are validated against the configured fork branch'
}

test_fork_source_freshness() {
  local dir a b tree
  dir=$(new_home fork-freshness)
  setup_bosun "$dir"
  prepare_project "$dir" fresh
  a=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/fresh)
  tree=$(git -C "$dir/projects/sample" rev-parse HEAD^{tree})
  b=$(printf '%s\n' replacement | git -C "$dir/projects/sample" commit-tree "$tree")
  git -C "$dir/projects/sample" -c "url.file://$FORK_BARE.insteadOf=https://github.com/captain/sample.git" \
    push -q --force fork "$b:refs/heads/housefeature/fresh"
  if call "$dir" order --task stale --bosun bosun-kun --maneuver fresh \
    --forge github --owner kunchenguid --repository sample --source housefeature/fresh \
    --branch contribution/stale --captain-words 'Contribute stale' --path feature.txt \
    --commit "$a" >"$dir/out" 2>&1; then
    fail 'stale fork source commit was accepted'
  fi
  call "$dir" order --task fresh --bosun bosun-kun --maneuver fresh \
    --forge github --owner kunchenguid --repository sample --source housefeature/fresh \
    --branch contribution/fresh --captain-words 'Contribute fresh' --path feature.txt \
    --commit "$b" >/dev/null || fail 'fresh fork source commit was rejected'

  dir=$(new_home unreachable-fork)
  setup_bosun "$dir"
  prepare_project "$dir" unreachable
  a=$(git --git-dir "$FORK_BARE" rev-parse refs/heads/housefeature/unreachable)
  rm -rf "$FORK_BARE"
  if call "$dir" order --task unreachable --bosun bosun-kun --maneuver unreachable \
    --forge github --owner kunchenguid --repository sample --source housefeature/unreachable \
    --branch contribution/unreachable --captain-words 'Contribute unreachable' --path feature.txt \
    --commit "$a" >"$dir/out" 2>&1; then
    fail 'unreachable fork remote was accepted'
  fi
  pass 'fork source validation refreshes and fails closed'
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

test_registration_requires_role() {
  local dir
  dir=$(new_home missing-role)
  ordered_home "$dir"
  rm "$dir/data/bosun-role.json"
  if call "$dir" registration-check --task maneuver --url https://github.com/kunchenguid/sample/pull/12 \
    --forge github --head captain/sample --base kunchenguid/sample --branch main \
    --pr-head 0123456789012345678901234567890123456789 \
    --validation-head 0123456789012345678901234567890123456789 --validation-mode no-mistakes \
    --upstream-base upstream-sha --changed-path feature.txt >"$dir/out" 2>&1; then
    fail 'registration without a role record was accepted'
  fi
  pass 'registration requires a valid Bosun role record'
}

test_routing
test_memory_and_paths
test_order_accepts_dotfiles
test_order_rejects_invalid_commit_selection
test_fork_source_validation
test_fork_source_freshness
test_intake_delegates_to_ship_lifecycle
test_intake_retries_existing_task
test_registration_and_merge
test_registration_requires_role

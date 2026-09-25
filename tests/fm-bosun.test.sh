#!/usr/bin/env bash
# Bosun routing, memory, scoped extraction, publication guard, and merge record.
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
  {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository_pattern":"*"},
  {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository":"special"}
]}
EOF
}

test_routing() {
  local dir out
  dir=$(new_home routing)
  printf '%s\n' '- bosun-kun - Kun contributions (home: /tmp/kun; scope: Kun; projects: sample; added 2026-09-25)' > "$dir/data/secondmates.md"
  routes_fixture "$dir"
  call "$dir" configure-home --bosun bosun-kun || fail 'role setup failed'
  out=$(call "$dir" route --forge github --owner kunchenguid --repository special) || fail 'exact route failed'
  [ "$out" = bosun-kun ] || fail 'exact route picked another Bosun'
  out=$(call "$dir" route --forge github --owner kunchenguid --repository sample) || fail 'pattern route failed'
  [ "$out" = bosun-kun ] || fail 'pattern route picked another Bosun'
  if call "$dir" route --forge github --owner other --repository sample > "$dir/out" 2>&1; then
    fail 'unmatched route silently selected a Bosun'
  fi
  assert_grep 'ask whether to create one' "$dir/out" 'no match did not request Bosun creation'
  python3 - "$dir/config/bosun-routes.json" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
d['routes'].append(dict(d['routes'][0]))
open(p,'w').write(json.dumps(d))
PY
  if call "$dir" route --forge github --owner kunchenguid --repository sample > "$dir/out" 2>&1; then
    fail 'ambiguous same-rank route was guessed'
  fi
  assert_grep 'ambiguous Bosun route' "$dir/out" 'tie did not refuse'
  pass 'route precedence, no match, and tie refusal'
}

setup_bosun() {
  local dir=$1
  routes_fixture "$dir"
  printf '%s\n' bosun-kun > "$dir/.fm-secondmate-home"
  call "$dir" configure-home --bosun bosun-kun || fail 'Bosun home setup failed'
}

test_memory() {
  local dir out
  dir=$(new_home memory)
  setup_bosun "$dir"
  printf '{"format":"policy"}\n' > "$dir/policy.json"
  call "$dir" convention --bosun bosun-kun --forge github --owner kunchenguid --repository sample \
    --scope shared --key format --value shared --confirmed \
    --evidence 'https://github.com/kunchenguid/sample/pull/1' --showed 'merged with shared format' \
    --read-at 2026-09-25T00:00:00Z || fail 'shared convention recording failed'
  call "$dir" convention --bosun bosun-kun --forge github --owner kunchenguid --repository sample \
    --scope repository --key format --value repository --confirmed \
    --evidence CONTRIBUTING.md --showed 'repository format' \
    --read-at 2026-09-25T00:00:00Z || fail 'repository convention recording failed'
  out=$(call "$dir" conventions --bosun bosun-kun --forge github --owner kunchenguid \
    --repository sample --policy "$dir/policy.json") || fail 'precedence resolution failed'
  printf '%s' "$out" | jq -e '.format == {value:"policy",source:"current_repository_policy"}' >/dev/null \
    || fail 'current policy did not win'
  printf '{}\n' > "$dir/policy.json"
  out=$(call "$dir" conventions --bosun bosun-kun --forge github --owner kunchenguid \
    --repository sample --policy "$dir/policy.json") || fail 'overlay resolution failed'
  printf '%s' "$out" | jq -e '.format.value == "repository" and .format.source == "repository"' >/dev/null \
    || fail 'repository overlay did not win'
  if call "$dir" convention --bosun bosun-kun --forge github --owner kunchenguid --repository sample \
    --scope shared --key unproven --value yes --confirmed > "$dir/out" 2>&1; then
    fail 'unsupported learned convention became policy'
  fi
  printf '{"format":"policy"}\n' > "$dir/policy.json"
  printf '{"format":"captain"}\n' > "$dir/decisions.json"
  if call "$dir" conventions --bosun bosun-kun --forge github --owner kunchenguid \
    --repository sample --policy "$dir/policy.json" --decisions "$dir/decisions.json" > "$dir/out" 2>&1; then
    fail 'captain policy conflict was silently resolved'
  fi
  assert_grep 'needs-decision' "$dir/out" 'policy conflict was not escalated'
  pass 'evidence requirement and convention precedence'
}

git_fixture() {
  local dir=$1
  git init -q -b main "$dir/source"
  git -C "$dir/source" config user.name 'Fixture Author'
  git -C "$dir/source" config user.email 'fixture@example.test'
  printf 'base\n' > "$dir/source/feature.txt"
  git -C "$dir/source" add feature.txt
  git -C "$dir/source" commit -qm base
  git clone -q --bare "$dir/source" "$dir/upstream.git"
  git -C "$dir/source" remote add upstream "$dir/upstream.git"
  git -C "$dir/source" switch -qc housefeature/maneuver
  mkdir -p "$dir/source/config"
  printf 'private=true\n' > "$dir/source/config/private.env"
  git -C "$dir/source" add config/private.env
  git -C "$dir/source" commit -qm 'fork-only setup'
  printf 'public change\n' >> "$dir/source/feature.txt"
  printf 'secret=fixture-only\n' >> "$dir/source/config/private.env"
  git -C "$dir/source" add feature.txt config/private.env
  GIT_AUTHOR_NAME='Original Author' GIT_AUTHOR_EMAIL='original@example.test' \
    git -C "$dir/source" commit -qm 'Add maneuver'
  git -C "$dir/source" rev-parse HEAD
}

test_contribution() {
  local dir selected branch url merge_home
  dir=$(new_home contribution)
  setup_bosun "$dir"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" guard-brief sample --mode no-mistakes \
    >/dev/null || fail 'Bosun ship brief did not scaffold'
  assert_grep 'Bosun publication authorization' "$dir/data/guard-brief/brief.md" \
    'Bosun worker brief omitted the publication guard'
  selected=$(git_fixture "$dir") || fail 'git fixture failed'
  branch=contribution/maneuver
  url=https://github.com/kunchenguid/sample/pull/12
  if call "$dir" guard --task maneuver --forge github --owner kunchenguid \
    --repository sample --repo "$dir/source" > "$dir/out" 2>&1; then
    fail 'publication without captain order was accepted'
  fi
  call "$dir" order --task maneuver --bosun bosun-kun --maneuver maneuver \
    --forge github --owner kunchenguid --repository sample --source housefeature/maneuver \
    --branch "$branch" --captain-words 'Contribute maneuver to kunchenguid/sample' \
    --path feature.txt --commit "$selected" >/dev/null || fail 'order recording failed'
  if call "$dir" guard --task maneuver --forge github --owner other \
    --repository sample --repo "$dir/source" > "$dir/out" 2>&1; then
    fail 'changed target was authorized'
  fi
  git -C "$dir/source" worktree add -q --detach "$dir/extracted" main \
    || fail 'isolated worker worktree setup failed'
  call "$dir" extract --task maneuver --repo "$dir/source" --worktree "$dir/extracted" \
    --upstream-remote upstream --default-branch main >/dev/null || fail 'clean extraction failed'
  [ "$(cat "$dir/extracted/feature.txt")" = $'base\npublic change' ] || fail 'maneuver content missing'
  [ ! -e "$dir/extracted/config/private.env" ] || fail 'private fork content crossed extraction'
  [ "$(git -C "$dir/extracted" log -1 --format=%ae)" = original@example.test ] \
    || fail 'source author attribution was lost'
  [ "$(git -C "$dir/extracted" rev-list --count upstream/main..HEAD)" = 1 ] \
    || fail 'fork-only history crossed extraction'
  call "$dir" guard --task maneuver --forge github --owner kunchenguid \
    --repository sample --repo "$dir/extracted" >/dev/null || fail 'clean contribution refused'
  call "$dir" published --task maneuver --repo "$dir/extracted" --url "$url" \
    --validation 'offline fixture validation artifact' >/dev/null || fail 'publication record refused'
  call "$dir" registration-check --task maneuver --url "$url" \
    || fail 'matching Bosun PR registration was refused'
  if call "$dir" registration-check --task maneuver \
    --url https://github.com/kunchenguid/sample/pull/13 > "$dir/out" 2>&1; then
    fail 'unrelated upstream PR was registered'
  fi
  if call "$dir" review --task maneuver --kind scope-change --source "$url#issuecomment-1" \
    --summary 'please expand scope' > "$dir/out" 2>&1; then
    fail 'scope-changing review was accepted'
  fi
  assert_grep 'needs-decision' "$dir/out" 'review escalation missing'
  call "$dir" review --task maneuver --kind routine --source "$url#discussion_r2" \
    --summary 'typo fixed' || fail 'routine review evidence refused'
  # A closed-unmerged fake forge state never calls the confirmed-merge path.
  printf 'closed\n' > "$dir/fake-forge-state"
  jq -e '.state == "published"' "$dir/data/maneuver/bosun-contribution.json" >/dev/null \
    || fail 'closed-unmerged contribution was promoted'
  merge_home=$(new_home merged)
  mkdir -p "$merge_home/data/maneuver"
  cp "$dir/data/maneuver/bosun-contribution.json" "$merge_home/data/maneuver/"
  printf 'merged\n' > "$merge_home/fake-forge-state"
  [ "$(cat "$merge_home/fake-forge-state")" = merged ] || fail 'fake forge state failed'
  FM_HOME="$merge_home" bash -c '. "$1"; fm_merge_outcome_report "$2" "$2/state" maneuver "$3" poll' \
    _ "$ROOT/bin/fm-merge-outcome-lib.sh" "$merge_home" "$url" \
    || fail 'existing confirmed-merge outcome did not update Bosun record'
  jq -e '.state == "admirals-maneuver" and .upstream_pr == "https://github.com/kunchenguid/sample/pull/12"' \
    "$merge_home/data/maneuver/bosun-contribution.json" >/dev/null || fail 'Admiral maneuver record missing'
  pass 'clean extraction, authorization, review escalation, and merge completion'
}

test_routing
test_memory
test_contribution

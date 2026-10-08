#!/usr/bin/env bash
# Published-contribution behavior through Bearings and the authenticated checks.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  chmod +x "$home/fakebin/"*
  printf '%s\n' "$home"
}

bearings() {
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_BEARINGS_NOW="$NOW" "$ROOT/bin/fm-bearings-snapshot.sh" --json
}

record() { # home id number forge-state mergeability [hold]
  local home=$1 id=$2 number=$3 state=$4 mergeable=$5 hold=${6:-}
  mkdir -p "$home/data/$id"
  printf -- '- [ ] %s - Contribution %s https://github.com/o/r/pull/%s (repo: sample) (kind: ship) %s\n' \
    "$id" "$id" "$number" "$hold" >> "$home/data/backlog.md"
  jq -n --arg task "$id" --arg url "https://github.com/o/r/pull/$number" \
    --arg head "$HEAD_A" --arg at "$NOW" --arg state "$state" --arg mergeable "$mergeable" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:$state,draft:false,mergeable:$mergeable,
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$home/data/$id/contributions.json"
}

mutate_record() {
  jq "$3" "$1/data/$2/contributions.json" > "$1/update.json" || fail 'fixture mutation failed'
  mv "$1/update.json" "$1/data/$2/contributions.json"
}

test_actor_coverage() {
  local home out
  home=$(new_home actors)
  record "$home" own 1 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" repair 2 open conflicting
  record "$home" external 3 open mergeable
  record "$home" landed 4 merged mergeable
  out=$(bearings "$home") || fail 'Bearings could not read contribution fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 4 and .contributions.checked == 4
    and .contributions.counts == {captain:1,fleet:1,maintainer:1,nobody:1}
    and (.contributions.captain | length) == 1
    and .contributions.captain[0].url == "https://github.com/o/r/pull/1"
    and .contributions.complete == true and .contributions.proven_clear == false' >/dev/null \
    || fail "published deliveries must report actors and measured coverage: $out"
  pass 'only required-captain contributions are rows; other actors are counted'
}

test_stale_verdict() {
  local home out
  home=$(new_home stale)
  record "$home" changed 5 open mergeable
  mutate_record "$home" changed ".records[0].verdict = {head:\"$HEAD_B\",actor:\"captain\",source:\"https://github.com/o/r/pull/5#issuecomment-8\",summary:\"choose contract\"}"
  out=$(bearings "$home") || fail 'Bearings could not read stale verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.stale_verdicts == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail "a verdict on a replaced head must be STALE, not current captain work: $out"
  pass 'replaced-head verdict is stale and cannot create a captain requirement'
}

test_unchecked_is_not_silence() {
  local home out
  home=$(new_home unchecked)
  printf -- '- [ ] unseen - Unchecked https://github.com/o/r/pull/6 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(bearings "$home") || fail 'Bearings could not read unchecked fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail "no observation must not become a proven empty actionable set: $out"
  pass 'unchecked ownership is disclosed and cannot prove silence'
}

test_newest_check_has_no_verdict() {
  local home out
  home=$(new_home no-verdict)
  record "$home" missing 7 open mergeable
  mutate_record "$home" missing '.records[0].observation.checks += [{name:"test",id:2,status:"completed",conclusion:null,started_at:"2026-09-16T08:00:01Z"}]'
  out=$(bearings "$home") || fail 'Bearings could not read missing verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1
    and .contributions.counts.maintainer == 0' >/dev/null \
    || fail "newest distinct check must not inherit an earlier success: $out"
  pass 'newest check with no verdict is distinct from passing and pending'
}


forge_home() {
  local home=$1
  mkdir -p "$home/forge" "$home/root/bin" "$home/wt"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  git -C "$home/wt" init -q
  git -C "$home/wt" config user.name Fixture
  git -C "$home/wt" config user.email fixture@example.invalid
  printf 'clean\n' > "$home/wt/tracked"
  git -C "$home/wt" add tracked
  GIT_AUTHOR_DATE=2026-09-16T08:00:00Z GIT_COMMITTER_DATE=2026-09-16T08:00:00Z \
    git -C "$home/wt" commit -qm initial
  record "$home" delivery 8 open mergeable
  git -C "$home/wt" rev-parse HEAD > "$home/forge/head"
  printf 'owner/r\n' > "$home/forge/base-repo"
  printf 'fork/r\n' > "$home/forge/head-repo"
  printf '%s\n' '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]' > "$home/forge/checks.json"
  printf '[]\n' > "$home/forge/comments.json"
  printf '[]\n' > "$home/forge/reviews.json"
  printf '[]\n' > "$home/forge/inline.json"
  printf '[]\n' > "$home/forge/labels.json"
  printf '[]\n' > "$home/forge/events.json"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*"--json body --jq .body"*) printf 'Fixture body\n' ;;
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" --arg decision "$(cat "$FORGE/review-decision" 2>/dev/null || printf APPROVED)" '{headRefOid:$head,reviewDecision:$decision}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8'|'api repos/o/r/pulls/9'|'api repos/o/r/pulls/10')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" \
      --arg head_repo "$(cat "$FORGE/head-repo")" --arg base_repo "$(cat "$FORGE/base-repo")" \
      --arg timestamp "$(cat "$FORGE/pr-time" 2>/dev/null || true)" \
      --arg created "$(cat "$FORGE/pr-created-time" 2>/dev/null || true)" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},
       updated_at:(if $timestamp == "" then null else $timestamp end),
       created_at:(if $created == "" then null else $created end),
       head:{sha:$head,repo:{full_name:$head_repo}},base:{repo:{full_name:$base_repo}},draft:false,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end)}' ;;
  'api repos/o/r/issues/9')
    jq -n --slurpfile labels "$FORGE/labels.json" '{state:"open",user:{login:"author"},labels:$labels[0]}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -s . "$FORGE/events.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api repos/o/r/pulls/'*'/files?'*) : ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    cat "$FORGE/checks.json" ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api graphql '*viewerPermission*)
    requested_owner= requested_repo=
    for argument; do
      case "$argument" in owner=*) requested_owner=${argument#owner=} ;; repo=*) requested_repo=${argument#repo=} ;; esac
    done
    [ "$requested_owner/$requested_repo" = "$(cat "$FORGE/base-repo")" ] || exit 1
    [ ! -f "$FORGE/permission-error" ] || { printf 'HTTP 403\n' >&2; exit 1; }
    if [ -f "$FORGE/permission-response.json" ]; then
      cat "$FORGE/permission-response.json"
    else
      jq -n --arg permission "$(cat "$FORGE/permission" 2>/dev/null || printf READ)" '{data:{repository:{viewerPermission:$permission}}}'
    fi ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

registered_checks() {
  local home=$1 check
  for check in "$home/state/"*.check.sh; do
    [ -f "$check" ] || continue
    with_home "$home" bash "$check" || fail 'registered check failed'
  done
}

test_incoming_signal() { # comment|review|inline
  local type=$1 home out count fixture wake_count
  case "$type" in comment) fixture=comments ;; review) fixture=reviews ;; *) fixture=inline ;; esac
  home=$(new_home "incoming-$type")
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" --arg type "$type" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}
    + (if $type == "comment" then {} else {commit_id:$head,state:"CHANGES_REQUESTED"} end)]' \
    > "$home/forge/$fixture.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 1' "$home/data/delivery/contributions.json" >/dev/null \
    || fail "new maintainer $type must survive as a pending outward signal"
  [ -s "$home/state/.wake-queue" ] || fail "new maintainer $type must enqueue an ordinary durable wake"
  count=$(wc -l < "$home/state/.wake-queue")
  wake_count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$wake_count" = 1 ] || fail "new maintainer $type must enqueue exactly one ordinary durable wake"
  registered_checks "$home" >/dev/null
  [ "$(wc -l < "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued event'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$wake_count" ] || fail 're-poll duplicated an already enqueued event'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 1 and .[0].author == "maintainer"' >/dev/null \
    || fail 'supervisor cannot retrieve captured signal'
  pass "new maintainer $type wakes once and stays pending until acknowledged"
}

test_ready_issue_wake() {
  local home count
  home=$(new_home ready)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery'
  registered_checks "$home" >/dev/null
  printf '[{"name":"ready-for-pr"}]\n' > "$home/forge/labels.json"
  registered_checks "$home" >/dev/null
  if [ ! -f "$home/data/filed/contributions.json" ] \
    || ! jq -e 'any(.records[].pending[]; .type == "ready-for-pr")' "$home/data/filed/contributions.json" >/dev/null; then
    fail 'ready-for-pr on an explicitly filed issue must become a planning wake'
  fi
  [ -s "$home/state/.wake-queue" ] || fail 'ready-for-pr signal never reached the durable wake path'
  count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$count" = 1 ] || fail 'ready-for-pr signal must enqueue exactly one durable wake'
  registered_checks "$home" >/dev/null
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued ready-for-pr wake'
  pass 'ready-for-pr on a filed issue becomes a planning wake'
}

test_fresh_issue_requires_maintainer() {
  local home
  home=$(new_home fresh-issue)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not observe filed issue'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 2
    and .contributions.counts.maintainer == 2 and .contributions.counts.fleet == 0
    and .contributions.complete == true and .contributions.proven_clear == true' >/dev/null \
    || fail 'a fresh open issue did not remain measured maintainer triage'
  pass 'a fresh open issue remains measured maintainer triage'
}

test_comment_wake() { test_incoming_signal comment; }
test_review_wake() { test_incoming_signal review; }
test_inline_wake() { test_incoming_signal inline; }

test_missing_lane_remains_missing() {
  local home out
  home=$(new_home absent-lane)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the current PR for missing CI lanes'
  printf '%s\n' '[{"check_runs":[
    {"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"},
    {"name":"required-extra","id":2,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]' > "$home/forge/checks.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'baseline CI poll failed'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  printf '%s\n' '[{"check_runs":[{"name":"test","id":3,"status":"completed","conclusion":"success","started_at":"2026-09-16T10:00:00Z"}]}]' > "$home/forge/checks.json"
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'replacement head CI poll failed'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'missing lane expiry poll failed'
  case "$out" in *'state=ci'*) ;; *) fail "a missing CI lane allowed closeout: $out" ;; esac
  case "$out" in *'state=ready'*) fail 'missing CI lane counted as green' ;; esac
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'repeated missing lane poll failed'
  [ -z "$out" ] || fail "a stable missing lane repeated its closeout hold: $out"
  NOW=2026-09-16T12:05:00Z bearings "$home" | jq -e '.contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'repeated polling erased the absent lane from measured readiness'
  printf '%s\n' '[{"check_runs":[
    {"name":"test","id":1,"status":"completed","conclusion":"failure","started_at":"2026-09-16T07:00:00Z"},
    {"name":"test","id":3,"status":"completed","conclusion":"neutral","started_at":"2026-09-16T10:00:00Z"},
    {"name":"required-extra","id":4,"status":"completed","conclusion":"skipped","started_at":"2026-09-16T12:10:00Z"}]}]' > "$home/forge/checks.json"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:10:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'restored lane poll failed'
  case "$out" in *'state=ready'*) ;; *) fail "restored passing lanes did not permit closeout: $out" ;; esac
  NOW=2026-09-16T12:10:00Z bearings "$home" | jq -e '.contributions.missing_verdicts == 0 and .contributions.counts.maintainer == 1' >/dev/null \
    || fail 'restored latest lanes did not restore contribution readiness'
  pass 'absent CI lanes hold closeout until every latest lane reports a passing verdict'
}

test_partial_freshness_keeps_measured_rows() {
  local home
  home=$(new_home mixed-age)
  record "$home" current 10 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" expired 11 open mergeable
  mutate_record "$home" expired '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.counts.captain == 1 and (.contributions.captain | length) == 1
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'one expired observation erased the independently measured captain row'
  pass 'mixed freshness retains measured captain work and discloses the gap'
}

test_malformed_record_cannot_prove_silence() {
  local home
  home=$(new_home malformed)
  record "$home" invalid 12 open mergeable
  mutate_record "$home" invalid '.records[0].observation.state="not-a-forge-state"'
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'malformed durable evidence was counted as checked'
  pass 'malformed durable evidence cannot prove silence'
}

test_issue_timeline_and_exact_ack() {
  local home token
  home=$(new_home issue-timeline)
  forge_home "$home"
  printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial poll failed'
  printf '[{"event":"labeled","id":88,"label":{"name":"ready-for-pr"}}]\n' > "$home/forge/events.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'timeline poll failed'
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er '.[] | select(.type=="ready-for-pr") | .token') \
    || fail 'add/remove between polls lost ready-for-pr transition'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack filed https://github.com/o/r/issues/9 "$token" || fail 'exact ack failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'post-ack poll failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null || fail 'acknowledged timeline event replayed'
  pass 'a transient ready-for-pr label wakes and its exact acknowledgement survives replay'
}

test_closed_backlog_pr_owns_landed_contribution() {
  local home url token
  home=$(new_home closed-backlog-owner)
  forge_home "$home"
  url=https://github.com/o/r/pull/8
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  rm -rf "$home/data/delivery" "$home/state/delivery.meta"
  printf -- '- [ ] landed - Landed upstream contribution (repo: sample) (kind: ship)\n' \
    >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-tasks-axi.sh" 'done' landed >/dev/null \
    || fail 'could not close the originating backlog task'
  with_home "$home" "$ROOT/bin/fm-tasks-axi.sh" 'done' landed --pr "$url" >/dev/null \
    || fail 'could not backfill the contribution URL onto the closed backlog task'
  [ ! -e "$home/state/landed.meta" ] || fail 'fixture unexpectedly retained live task metadata'
  jq -n '[{id:44,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-44",
    updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'observer did not accept the closed structured backlog link as an owner'
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -er '.[] | select(.url == "https://github.com/o/r/pull/8") | .token') \
    || fail 'closed backlog owner did not receive the maintainer event'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict landed "$url" "$HEAD_A" \
    "$url#issuecomment-44" maintainer 'awaiting maintainer' \
    || fail 'closed backlog owner could not record the contribution verdict'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack landed "$url" "$token" \
    || fail 'closed backlog owner could not acknowledge the contribution event'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'length == 0' >/dev/null \
    || fail 'acknowledged contribution event remained pending without task metadata'
  jq -e --arg head "$HEAD_A" --arg url "$url" \
    '.records[0].url == $url and .records[0].verdict.head == $head' \
    "$home/data/landed/contributions.json" >/dev/null \
    || fail 'closed backlog owner did not retain its verdict after acknowledgement'
  pass 'closed structured backlog PR link owns verdict and acknowledgement after task metadata cleanup'
}


test_verdict_retains_judged_head() {
  local home
  home=$(new_home verdict-roundtrip)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before judging its head'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-99 maintainer 'awaiting maintainer' || fail 'could not record judged head'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  printf 'pr=https://github.com/o/r/pull/8\npr_head=%s\n' "$HEAD_B" >> "$home/state/delivery.meta"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.stale_verdicts == 1 and .contributions.checked == 0' >/dev/null \
    || fail 'changed published head reused a current verdict'
  jq -e --arg head "$HEAD_A" '.records[0].verdict.head==$head' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'projection rewrote the judged head'
  pass 'recorded judgment keeps its exact head and is stale immediately on a published replacement'
}

test_verdict_actor_values_are_discoverable() {
  local home help out actor
  home=$(new_home verdict-actors)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before judging its head'
  help=$("$ROOT/bin/fm-contributions.sh" --help) || fail 'verdict help did not print'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-99 bogus 'no such actor' 2>&1) \
    && fail 'an unknown actor was accepted'
  [ "$(printf '%s\n' "$help" | sed -n '/^  fm-contributions.sh verdict /p')" = \
    '  fm-contributions.sh verdict <task> <url> <judged-head> <source-url> <captain|fleet|maintainer|nobody> <summary>' ] \
    || fail "help usage does not name exactly the accepted actors: $help"
  [ "$(printf '%s\n' "$help" | sed -n '/^actor is exactly one of /p')" = \
    'actor is exactly one of captain, fleet, maintainer or nobody; any other value' ] \
    || fail "help explanation does not name exactly the accepted actors: $help"
  [ "$out" = "fm-contributions: invalid required actor 'bogus'; expected one of: captain, fleet, maintainer, nobody" ] \
    || fail "refusal does not name exactly the accepted actors: $out"
  for actor in captain fleet maintainer nobody; do
    with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
      https://github.com/o/r/pull/8#issuecomment-99 "$actor" 'documented actor' >/dev/null \
      || fail "documented actor $actor was refused"
  done
  pass 'verdict help and refusal name exactly the actors the command accepts'
}

test_observed_replacement_refreshes_verdict() {
  local home
  home=$(new_home observed-replacement)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before replacement'
  registered_checks "$home" >/dev/null
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_B" \
    https://github.com/o/r/pull/8#issuecomment-100 maintainer 'awaiting maintainer' \
    || fail 'could not record verdict on the observed replacement'
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.stale_verdicts == 0
    and .contributions.counts.maintainer == 1 and .contributions.counts.fleet == 0' >/dev/null \
    || fail 'a current forge observation did not refresh a verdict on its observed head'
  pass 'a current forge observation refreshes a verdict after a replacement'
}

test_unobserved_head_leaves_verdict_unknown() {
  local home out
  home=$(new_home unobserved-head)
  record "$home" delivery 17 open mergeable
  mutate_record "$home" delivery ".records[0].error=\"forge unavailable\" | .records[0].verdict={head:\"$HEAD_B\",actor:\"maintainer\",source:\"https://github.com/o/r/pull/17#issuecomment-101\",summary:\"awaiting maintainer\"}"
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input without a forge read'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project unavailable forge observation'
  printf '%s' "$out" | jq -e '.stale_verdicts == 0 and .checked == 0
    and .rows[0].verdict.freshness == "unverified"' >/dev/null \
    || fail 'an unavailable current head became a fresh or stale verdict'
  pass 'an unavailable current head leaves verdict freshness unknown'
}

test_away_yolo_is_fleet_work() {
  local home out
  home=$(new_home away-yolo)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register away delivery'
  printf 'yolo=on\n' >> "$home/state/delivery.meta"
  with_home "$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
    || fail 'could not enter away posture'
  mutate_record "$home" delivery '.records[0].observation.can_merge=true'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input for away posture'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project away delivery'
  printf '%s' "$out" | jq -e '.checked == 1 and .counts.captain == 0 and .counts.fleet == 1' >/dev/null \
    || fail 'away yolo delivery requiring a merge remained captain work'
  pass 'away yolo delivery is fleet work without granting merge authority'
}

test_away_yolo_cross_home_is_fleet_work() {
  local home child
  home=$(new_home away-yolo-parent)
  child=$(new_home away-yolo-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  forge_home "$child"
  with_home "$child" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register child away delivery'
  printf 'yolo=on\n' >> "$child/state/delivery.meta"
  with_home "$child" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
    || fail 'could not enter child away posture'
  mutate_record "$child" delivery '.records[0].observation.can_merge=true'
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child contribution summary'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'cross-home away yolo delivery requiring a merge remained captain work'
  pass 'cross-home away yolo delivery is fleet work'
}

test_retired_and_unsupported_coverage() {
  local home
  home=$(new_home retained)
  record "$home" retained 14 open mergeable
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true and .contributions.counts.maintainer == 1' >/dev/null \
    || fail 'endpoint retirement lost published ownership or proved nothing'
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'unsupported forge silently disappeared from coverage'
  pass 'retired ownership persists and unsupported forge remains visibly unmeasured'
}

test_unsupported_forge_is_not_fleet_work() {
  local home
  home=$(new_home unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.fleet == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unsupported forge was classified as fleet work instead of unmeasured coverage'
  pass 'unsupported forge coverage is disclosed without inventing fleet work'
}

test_held_unsupported_forge_is_not_captain_work() {
  local home
  home=$(new_home held-unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship) (hold: choose scope) (hold-kind: captain)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and (.contributions.captain | length) == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'a held unsupported forge was classified as captain or fleet work'
  pass 'held unsupported forge coverage remains unmeasured'
}

test_shared_contribution_signal_wakes_once() {
  local home token pending wakes
  home=$(new_home shared-contribution-signal)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register shared contribution owner'
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 1 ] || fail "one shared contribution signal created $wakes durable wakes"
  pending=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending) || fail 'shared contribution pending view failed'
  printf '%s' "$pending" | jq -e 'length == 2 and ([.[].task] | sort) == ["delivery","duplicate"]' >/dev/null \
    || fail 'shared contribution owners did not retain their separate acknowledgements'
  token=$(printf '%s' "$pending" | jq -er '.[0].token') || fail 'shared contribution signal had no acknowledgement token'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the first shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack duplicate https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the second shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'shared contribution acknowledgements did not remain independent'
  pass 'shared contribution signal wakes once while retaining both acknowledgements'
}

test_watcher_keeps_diagnostics_separate_from_contribution_wakes() {
  local home out rc wakes diagnostic
  home=$(new_home watcher-diagnostics)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for diagnostic watcher wake'
  registered_checks "$home" >/dev/null
  mkdir -p "$home/data/unreadable"
  printf 'incomplete JSON\n' > "$home/data/unreadable/contributions.json"
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher-diagnostics.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 > "$out" 2> "$home/watcher-diagnostics.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface contribution diagnostics: $(cat "$home/watcher-diagnostics.err")"
  diagnostic=$(awk -F '\t' -v key="$home/state/contributions.check.sh" '$3 == "check" && $4 == key { print $5 }' "$home/state/.wake-queue")
  [ "$diagnostic" = "check: $home/state/contributions.check.sh: contributions: 1 unreadable durable record(s)" ] \
    || fail "watcher wrapped a durable contribution wake into diagnostics: $diagnostic"
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 2 ] || fail "signal plus observer failure created $wakes durable wakes"
  pass 'watcher keeps observer diagnostics separate from contribution wakes'
}

test_expired_child_unsupported_forge_stays_unmeasured() {
  local home child
  home=$(new_home expired-unsupported-parent)
  child=$(new_home expired-unsupported-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$child/data/backlog.md"
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child unsupported-forge coverage'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and .contributions.complete == false
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'expired child unsupported-forge coverage became fleet work'
  pass 'expired child unsupported-forge coverage remains unmeasured'
}

test_watcher_surfaces_new_contribution_once() {
  local home out rc rows
  home=$(new_home watcher-contribution)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for watcher wake'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface the new contribution signal: $(cat "$home/watcher.err")"
  grep -E '^check: contributions delivery [0-9a-f]{64}$' "$out" >/dev/null \
    || fail "watcher did not surface the durable contribution wake: $(cat "$out")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "one contribution signal created $rows durable check wakes"
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$home/watcher-repeat.out" 2> "$home/watcher-repeat.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "an already durable contribution signal re-rang the watcher: $(cat "$home/watcher-repeat.out")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "repeat contribution observation created $rows durable check wakes"
  pass 'watcher surfaces one newly durable contribution signal without re-ringing it'
}

test_home_summary_coverage() {
  local home child
  home=$(new_home parent)
  child=$(new_home child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  record "$child" child-work 15 open mergeable
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'child summary failed'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true' >/dev/null || fail 'measured child coverage did not reach parent'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.proven_clear == false' >/dev/null || fail 'expired child evidence proved parent silence'
  pass 'parent consumes measured child coverage and refuses expired child silence'
}

test_unreadable_pending_is_not_empty() {
  local home
  home=$(new_home unreadable-pending)
  record "$home" invalid 16 open mergeable
  printf 'incomplete JSON\n' > "$home/data/invalid/contributions.json"
  if with_home "$home" "$ROOT/bin/fm-contributions.sh" pending > "$home/pending.json" 2> "$home/pending.err"; then
    fail 'an unreadable signal record was presented as an empty inbox'
  fi
  pass 'unreadable pending signals refuse an empty-inbox claim'
}

# Each record's durable task identity is the directory the snapshot loop finds
# it in, exactly as `basename "$(dirname "$file")"` named it, however the data
# root is spelled and whatever bytes the directory name carries.
test_record_task_identity_matches_dirname_basename() {
  local home data name file want n=0 names=() tasks=() expected actual
  home=$(new_home task-identity)
  names=(plain dot.ted 'two words' -dash $'caf\xc3\xa9' $'nl\n' '*')
  for data in "$home/data" "$home/data/" "$home/data//"; do
    for name in "${names[@]}"; do
      n=$((n + 1))
      mkdir -p "$home/data/$name"
      file="$data/$name/contributions.json"
      want=$(basename "$(dirname "$file")")
      jq -n --arg task "$want" --arg url "https://github.com/o/r/pull/$n" --arg token "t$n" \
        '{schema:"fm-contributions.v1",task:$task,records:[{url:$url,kind:"pr",checked_at:null,error:null,
          pending:[{token:$token}],seen:[],verdict:null,observation:null}]}' > "$file"
      tasks+=("$want")
    done
    expected=$(printf '%s\0' "${tasks[@]}" | jq -Rs 'split("\u0000")[:-1] | sort')
    actual=$(with_home "$home" env FM_DATA_OVERRIDE="$data" "$ROOT/bin/fm-contributions.sh" pending | jq '[.[].task] | sort') \
      || fail "records under data root '$data' were refused"
    [ "$actual" = "$expected" ] || fail "data root '$data' named tasks $actual, expected $expected"
    rm -rf "${home:?}/data/"*/
    tasks=()
  done
  mkdir -p "$home/data/named"
  jq -n '{schema:"fm-contributions.v1",task:"other",records:[]}' > "$home/data/named/contributions.json"
  if with_home "$home" "$ROOT/bin/fm-contributions.sh" pending > /dev/null 2>&1; then
    fail 'a record naming another task was accepted'
  fi
  pass 'record task identity is the directory dirname/basename named'
}

# snapshot and pending are read-only: reading saved records never creates the
# state directory or anything else, even in a home that has none.
test_read_only_views_create_no_state() {
  local home before after
  home=$(new_home read-only-views)
  record "$home" delivery 8 open mergeable
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$TMP_ROOT/read-only-input.json" \
    || fail 'could not collect contribution input'
  rm -rf "${home:?}/state"
  before=$(find "$home" | sort)
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$TMP_ROOT/read-only-input.json" --all \
    | jq -e '.checked == 1' >/dev/null || fail 'snapshot did not read the saved record without a state directory'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'pending did not read the saved record without a state directory'
  after=$(find "$home" | sort)
  [ ! -e "$home/state" ] || fail 'a read-only contribution view created the state directory'
  [ "$after" = "$before" ] || fail "a read-only contribution view created files: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  pass 'snapshot and pending create nothing in a home without state'
}

wrap_forge() { # home: log gh calls and apply per-call faults from $FORGE/fault
  local home=$1
  mv "$home/fakebin/gh" "$home/fakebin/gh-fixture"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FORGE/calls"
fault=$(cat "$FORGE/fault" 2>/dev/null || true)
case "$fault" in latency) sleep "${FORGE_LATENCY:-2}" ;; esac
# Concurrent forge callers each advance one shared clock. Truncating it in
# place races with the other callers and the fake date: an interleaved write
# can publish a half-written value (or the 6 an emptied read computes), and a
# caller then evaluates DEADLINE against torn arithmetic. Publish every new
# value by rename so each reader always sees one complete old-or-new clock.
clock_bump() {
  local tmp
  tmp=$(mktemp "$FORGE/clock.XXXXXX")
  printf '%s\n' "$(( $(cat "$FORGE/clock") + $1 ))" > "$tmp"
  mv -f "$tmp" "$FORGE/clock"
}
case "$fault:$*" in
  # Advance once before the parallel read wave; its readers share this clock.
  reserve:'api repos/o/r/issues/9') clock_bump 6 ;;
  slow-wave:'api repos/o/r/pulls/8') sleep 3 ;;
  slow-wave:'api repos/o/r/pulls/8/reviews?'*) sleep 6 ;;
  exhaust:'api repos/o/r/issues/8/comments?'*) clock_bump 100 ;;
  fail-late:'api repos/o/r/pulls/8/reviews?'*) clock_bump 100; printf 'HTTP 502\n' >&2; exit 1 ;;
  fail:'api repos/o/r/pulls/8/reviews?'*) printf 'HTTP 502\n' >&2; exit 1 ;;
  down:*) printf 'HTTP 502\n' >&2; exit 1 ;;
  not-found:'api repos/o/r/'*) printf 'HTTP 404\n' >&2; exit 1 ;;
  hang:'api repos/o/r/pulls/8') sleep 4 ;;
  head:'pr view '*) printf '{"headRefOid":"%s","reviewDecision":"APPROVED"}\n' "$(printf 'b%.0s' $(seq 40))"; exit 0 ;;
esac
exec "$(dirname "$0")/gh-fixture" "$@"
SH
  # A controllable clock lets the budget expire between two forge calls.
  cat > "$home/fakebin/date" <<'SH'
#!/bin/sh
if [ "$*" = +%s ] && [ -f "$FORGE/clock" ]; then cat "$FORGE/clock"; else exec /bin/date "$@"; fi
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/date"
}

test_budget_exhaustion_keeps_prior_record() { # exhaust|hang
  local mode=$1 home out
  home=$(new_home "budget-$mode")
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  # Both modes freeze the clock: an unfrozen one can tick past a one-second
  # budget before the first forge call, so nothing is ever observed.
  /bin/date +%s > "$home/forge/clock"
  printf '%s\n' "$mode" > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=1 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail "poll failed when its budget ran out ($mode)"
  [ -z "$out" ] || fail "budget exhaustion ($mode) printed a wake line: $out"
  grep -F 'api repos/o/r/pulls/8' "$home/forge/calls" >/dev/null \
    || fail "budget exhaustion ($mode) never started the observation"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
    || fail "budget exhaustion ($mode) rewrote the prior record: $(cat "$home/data/delivery/contributions.json")"
  [ ! -s "$home/state/.wake-queue" ] || fail "budget exhaustion ($mode) enqueued a wake"
  pass "budget exhausted mid-observation ($mode) keeps the prior record and stays silent"
}

test_budget_refusal_between_calls() { test_budget_exhaustion_keeps_prior_record exhaust; }
test_budget_bounded_call_timeout() { test_budget_exhaustion_keeps_prior_record hang; }

test_genuine_failure_near_deadline_is_unavailable() {
  local home out
  home=$(new_home genuine-failure)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  /bin/date +%s > "$home/forge/clock"
  printf 'fail-late\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed on a genuine forge failure'
  [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
    || fail "a genuine forge failure past the deadline was swallowed: $out"
  jq -e --arg now "$NOW" '.records[0].checked_at == $now
    and .records[0].error == "forge observation unavailable or changed during read"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'a genuine forge failure left no error evidence'
  pass 'a genuine forge failure inside the budget still records the error and wakes'
}

test_shared_url_observed_once() {
  local mode home out calls expected
  for mode in ok fail head; do
    home=$(new_home "shared-once-$mode")
    forge_home "$home"
    wrap_forge "$home"
    printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
    printf '%s\n' "$mode" > "$home/forge/fault"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail "shared-owner poll failed ($mode)"
    calls=$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")
    [ "$calls" = 1 ] || fail "a URL owned by two tasks was observed $calls times in one poll ($mode)"
    if [ "$mode" = ok ]; then
      expected=null
      [ -z "$out" ] || fail "a healthy shared observation printed: $out"
    else
      expected='"forge observation unavailable or changed during read"'
      [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
        || fail "a shared unavailable observation did not wake exactly once ($mode): $out"
    fi
    for task in delivery duplicate; do
      jq -e --arg now "$NOW" --argjson error "$expected" '.records[0].checked_at == $now and .records[0].error == $error' \
        "$home/data/$task/contributions.json" >/dev/null || fail "owner $task did not receive the shared result ($mode)"
    done
  done
  pass 'a URL owned by two tasks is observed once and every owner receives the result'
}

test_terminal_contribution_settles() {
  local mode home out later=2026-09-17T08:00:00Z
  for mode in merged closed; do
    home=$(new_home "terminal-$mode")
    forge_home "$home"
    wrap_forge "$home"
    printf '%s\n' "$mode" > "$home/forge/state"
    mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail "terminal observation poll failed ($mode)"
    [ -z "$out" ] || fail "a $mode observation printed: $out"
    jq -e --arg now "$NOW" --arg mode "$mode" '.records[0] | .checked_at == $now and .error == null and .observation.state == $mode' \
      "$home/data/delivery/contributions.json" >/dev/null || fail "a $mode observation was not recorded once without error"
    cp "$home/data/delivery/contributions.json" "$home/prior.json"
    : > "$home/forge/calls"
    printf 'down\n' > "$home/forge/fault"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "poll after a $mode observation failed"
    [ -z "$out" ] || fail "a $mode contribution woke again when a later read would fail: $out"
    [ ! -s "$home/forge/calls" ] || fail "a $mode contribution was re-read: $(cat "$home/forge/calls")"
    cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
      || fail "a $mode contribution record changed after it settled: $(cat "$home/data/delivery/contributions.json")"
    [ ! -s "$home/state/.wake-queue" ] || fail "a $mode contribution enqueued a wake"
    NOW=$later bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.nobody == 1
      and .contributions.complete == true' >/dev/null \
      || fail "a settled $mode contribution expired into fleet work"
  done
  home=$(new_home terminal-legacy-error)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].observation.state="merged" | .records[0].error="forge observation unavailable or changed during read"'
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll of an error-stamped merged record failed'
  [ -z "$out" ] || fail "an error-stamped merged record woke again: $out"
  [ ! -s "$home/forge/calls" ] || fail 'an error-stamped merged record was re-read'
  jq -e --arg at "$NOW" '.records[0] | .error == null and .checked_at == $at and .observation.state == "merged"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an error-stamped merged record did not settle'
  pass 'a merged or closed contribution settles once, is not re-read, and never wakes again'
}

test_late_owner_inherits_terminal_observation() {
  local home out later=2026-09-17T08:00:00Z
  home=$(new_home terminal-late-owner)
  forge_home "$home"
  wrap_forge "$home"
  printf 'merged\n' > "$home/forge/state"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial terminal observation poll failed'
  cp "$home/data/delivery/contributions.json" "$home/final.json"
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  : > "$home/forge/calls"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'late-owner terminal poll failed'
  [ -z "$out" ] || fail "a late owner reactivated a terminal contribution: $out"
  [ ! -s "$home/forge/calls" ] || fail 'a late owner triggered a terminal forge read'
  jq -e --slurpfile final "$home/final.json" '
    .records[0] as $late | $final[0].records[0] as $terminal
    | $late.error == null and $late.pending == [] and $late.notified == []
    and $late.checked_at == $terminal.checked_at and $late.observation == $terminal.observation' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail 'a late owner did not inherit the settled terminal observation'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a late owner terminal record enqueued a wake'
  pass 'a late owner inherits a terminal observation without a forge read or wake'
}

test_interrupted_multi_owner_poll_settles_every_owner() {
  local home later=2026-09-17T08:00:00Z
  home=$(new_home multi-owner-open)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" duplicate 8 open mergeable
  mutate_record "$home" duplicate '.records[0].pending=[{token:"evt-1"}] | .records[0].notified=["evt-0"]
    | .records[0].checked_at="2026-09-15T08:00:00Z"'
  mutate_record "$home" delivery ".records[0].observation.state=\"merged\" | .records[0].observation.head=\"$HEAD_B\""
  printf 'down\n' > "$home/forge/fault"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'interrupted multi-owner poll failed'
  [ ! -s "$home/forge/calls" ] || fail 'a known terminal URL triggered a forge read'
  jq -e --slurpfile terminal "$home/data/delivery/contributions.json" '.records[0] | .observation.state == "merged"
    and .observation == $terminal[0].records[0].observation
    and .error == null and .checked_at == $terminal[0].records[0].checked_at
    and .pending == [{token:"evt-1"}] and .notified == ["evt-0"]' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail "an owner whose saved row stayed open did not converge on the known terminal observation: $(cat "$home/data/duplicate/contributions.json")"

  home=$(new_home multi-owner-errored)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" duplicate 8 open mergeable
  mutate_record "$home" duplicate '.records[0].error="forge observation unavailable or changed during read"'
  mutate_record "$home" delivery ".records[0].observation.state=\"merged\" | .records[0].observation.head=\"$HEAD_B\""
  printf 'down\n' > "$home/forge/fault"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'interrupted multi-owner poll (errored owner) failed'
  [ ! -s "$home/forge/calls" ] || fail 'a known terminal URL triggered a forge read (errored owner)'
  jq -e --slurpfile terminal "$home/data/delivery/contributions.json" '.records[0] | .observation.state == "merged"
    and .observation == $terminal[0].records[0].observation and .error == null' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail "an errored owner did not converge on the known terminal observation: $(cat "$home/data/duplicate/contributions.json")"
  pass 'a retry converges every owner whose saved row is not terminal, keeping its own acknowledgement state'
}

test_done_task_open_pr_still_observed() {
  local home later=2026-09-17T08:00:00Z
  home=$(new_home done-open)
  forge_home "$home"
  wrap_forge "$home"
  rm "$home/data/delivery/contributions.json"
  printf '# Backlog\n\n## Queued\n\n## Done\n- [x] delivery - Shipped https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
    > "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'poll of a done task failed'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'second poll of a done task failed'
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 2 ] \
    || fail 'an open PR linked from a done task was not observed on every poll'
  jq -e --arg head "$HEAD_B" --arg at "$later" '.records[0] | .checked_at == $at and .error == null
    and .observation.state == "open" and .observation.head == $head' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an open PR on a done task did not track its current head'
  pass 'an open PR linked from a done task keeps being observed'
}

test_reservation_defers_later_url_when_fifteen_seconds_do_not_remain() {
  local home out
  home=$(new_home reservation)
  forge_home "$home"
  wrap_forge "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  /bin/date +%s > "$home/forge/clock"
  printf 'reserve\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=20 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'reservation poll failed'
  [ -z "$out" ] || fail "reservation poll printed an unavailable wake: $out"
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/filed/contributions.json" >/dev/null \
    || fail 'the first issue was not observed before reserving the remaining budget'
  grep -F 'api repos/o/r/pulls/8' "$home/forge/calls" >/dev/null \
    && fail 'a later PR began without the fifteen-second observation reservation'
  jq -e '.records[0].checked_at == "2026-09-15T08:00:00Z"' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a later PR record changed when the poll deferred it for budget'
  pass 'a later URL waits when fewer than fifteen seconds remain for its observation'
}

test_three_second_pr_reads_complete_fresh_in_one_cycle() { # 3-second reads: 8 sequential > 20s budget, parallel waves fit
  local home out
  home=$(new_home three-second-pr)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z" | .records[0].error="forge observation unavailable or changed during read"'
  printf 'latency\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=20 FORGE_LATENCY=3 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'a 3-second-read PR observation failed'
  [ -z "$out" ] || fail "a fresh 3-second-read PR observation woke: $out"
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a 3-second-read PR observation was not fresh within one cycle'
  pass 'eight 3-second PR reads complete fresh within one 20-second poll cycle'
}

test_slow_read_deadline_kill_is_budget_refusal() {
  local home out
  home=$(new_home slow-kill)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  /bin/date +%s > "$home/forge/clock"
  printf 'latency\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=20 FORGE_LATENCY=6 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed on a deadline-killed slow read'
  [ -z "$out" ] || fail "a deadline-killed slow read printed an unavailable wake: $out"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
    || fail 'a deadline-killed slow read rewrote the prior record'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a deadline-killed slow read enqueued a wake'
  pass 'a read killed at the five-second bound is budget refusal and stays silent'
}

test_unmeasured_url_does_not_starve_the_tail() {
  local home out cycle at started elapsed task
  home=$(new_home unmeasured-tail)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" second 9 open mergeable
  record "$home" third 10 open mergeable
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  printf 'slow-wave\n' > "$home/forge/fault"
  for cycle in 0 1 2; do
    at=$(jq -nr --arg now "$NOW" --argjson cycle "$cycle" '(($now | fromdateiso8601) + ($cycle + 1) * 300) | todateiso8601')
    started=$(/bin/date +%s)
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$at" FM_CONTRIBUTIONS_BUDGET=20 "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'poll failed after an unmeasured first URL'
    elapsed=$(( $(/bin/date +%s) - started ))
    [ -z "$out" ] || fail "a poll after an unmeasured URL printed a wake: $out"
    [ "$elapsed" -le 23 ] || fail "poll exceeded its elapsed budget: $elapsed seconds"
    if [ "$cycle" -eq 0 ]; then
      [ "$elapsed" -ge 8 ] || fail 'the slow head did not consume its core and parallel-wave budget'
      if grep -Eq '^api repos/o/r/pulls/(9|10)$' "$home/forge/calls"; then
        fail 'a tail PR began without its observation reserve'
      fi
    fi
    cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
      || fail 'a timed-out observation changed its prior freshness or record'
  done
  for task in second third; do
    jq -e --arg prior "$NOW" '.records[0] | .checked_at != $prior and .error == null' \
      "$home/data/$task/contributions.json" >/dev/null \
      || fail "successive polls starved $task behind the slow head"
  done
  [ ! -s "$home/state/.wake-queue" ] || fail 'routine slow reads enqueued a wake'
  home=$(new_home sustained-slow-refresh)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" second 9 open mergeable
  record "$home" third 10 open mergeable
  record "$home" merged-one 90 merged mergeable
  record "$home" closed-one 91 closed mergeable
  record "$home" merged-two 92 merged mergeable
  record "$home" closed-two 93 closed mergeable
  mutate_record "$home" closed-two '.records[0].error="forge observation unavailable or changed during read"'
  cp "$home/data/closed-two/contributions.json" "$home/terminal.json"
  printf -- '- [ ] late-owner - Shared https://github.com/o/r/pull/93 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  for task in delivery second third; do
    mutate_record "$home" "$task" '.records[0].checked_at="2026-09-16T07:55:00Z"'
  done
  printf 'latency\n' > "$home/forge/fault"
  for cycle in 0 1 2 3 4 5; do
    at=$(jq -nr --arg now "$NOW" --argjson cycle "$cycle" '(($now | fromdateiso8601) + $cycle * 300) | todateiso8601')
    started=$(/bin/date +%s)
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$at" FM_CONTRIBUTIONS_BUDGET=20 FORGE_LATENCY=3 "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'sustained slow-read poll failed'
    elapsed=$(( $(/bin/date +%s) - started ))
    [ "$elapsed" -ge 9 ] && [ "$elapsed" -le 23 ] \
      || fail "slow successful poll did not respect its elapsed budget: $elapsed seconds"
    [ -z "$out" ] || fail "slow successful reads printed a wake: $out"
    for task in closed-two late-owner; do
      jq -e --slurpfile prior "$home/terminal.json" '.records[0] | .error == null
        and .checked_at == $prior[0].records[0].checked_at
        and .observation == $prior[0].records[0].observation' \
        "$home/data/$task/contributions.json" >/dev/null \
        || fail "terminal settlement or freshness changed for $task"
    done
    if grep -Eq '^api repos/o/r/pulls/9[0-3]($|/)' "$home/forge/calls"; then
      fail 'a retained terminal PR was read from the forge'
    fi
    if [ "$cycle" -ge 2 ]; then
      for task in delivery second third; do
        jq -e --arg at "$at" '.records[0] | .error == null
          and (($at | fromdateiso8601) - (.checked_at | fromdateiso8601) <= 600)' \
          "$home/data/$task/contributions.json" >/dev/null \
          || fail "$task was not refreshed within three consecutive slow polls at $at"
      done
    fi
  done
  [ ! -s "$home/state/.wake-queue" ] || fail 'slow successful reads enqueued a wake'
  pass 'rotation preserves timed-out records and refreshes every slow PR on successive cycles'
}

test_budget_is_cut_down_to_the_watcher_check_bound() {
  local home out
  home=$(new_home check-bound-budget)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  /bin/date +%s > "$home/forge/clock"
  printf 'hang\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CHECK_TIMEOUT=6 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed under a small watcher check bound'
  [ -z "$out" ] || fail "a check-bound-capped poll printed a wake: $out"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
    || fail 'a poll observed with the full budget despite a six-second check bound'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a check-bound-capped poll enqueued a wake'
  pass 'the effective budget is cut down to the watcher per-check bound with margin'
}

test_arm_plumbs_a_configured_budget_into_the_check_shim() {
  local home out mode
  for mode in configured inherited; do
    home=$(new_home "arm-budget-$mode")
    forge_home "$home"
    wrap_forge "$home"
    mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
    cp "$home/data/delivery/contributions.json" "$home/prior.json"
    # Freeze the clock: an unfrozen one can tick past the one-second budget
    # before the first forge call, so nothing is ever observed.
    /bin/date +%s > "$home/forge/clock"
    printf 'hang\n' > "$home/forge/fault"
    if [ "$mode" = configured ]; then
      with_home "$home" env FM_CONTRIBUTIONS_BUDGET=3 "$ROOT/bin/fm-contributions.sh" arm >/dev/null \
        || fail 'arm with a configured budget failed'
      out=$(with_home "$home" env -u FM_CONTRIBUTIONS_BUDGET bash "$home/state/contributions.check.sh") \
        || fail 'configured check shim failed'
    else
      with_home "$home" env -u FM_CONTRIBUTIONS_BUDGET "$ROOT/bin/fm-contributions.sh" arm >/dev/null \
        || fail 'arm without a configured budget failed'
      out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=3 bash "$home/state/contributions.check.sh") \
        || fail 'inherited-budget check shim failed'
    fi
    [ -z "$out" ] || fail "generated check printed an unavailable wake: $out"
    grep -Fxq 'api repos/o/r/pulls/8' "$home/forge/calls" || fail 'generated check did not attempt a read'
    cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
      || fail "generated check failed to preserve the $mode one-second budget"
  done
  pass 'generated checks enforce configured and inherited budgets at runtime'
}

test_unavailable_forge_records_error_and_wakes_once_per_episode() { # genuine outage, two consecutive cycles
  local home out line='contributions: observation unavailable for https://github.com/o/r/pull/8'
  local error='"forge observation unavailable or changed during read"'
  home=$(new_home failure-episode)
  forge_home "$home"
  wrap_forge "$home"
  printf 'down\n' > "$home/forge/fault"
  poll_at() { with_home "$home" env FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll || fail "poll at $1 failed"; }
  out=$(poll_at 2026-09-16T09:00:00Z)
  [ "$out" = "$line" ] || fail "the first failure of an episode did not wake: $out"
  out=$(poll_at 2026-09-16T10:00:00Z)
  [ -z "$out" ] || fail "an unchanged read failure woke again on the next cycle: $out"
  jq -e --argjson error "$error" '.records[0] | .checked_at == "2026-09-16T10:00:00Z" and .error == $error' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'a repeated read failure stopped recording its error'
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 2 ] || fail 'a failing open PR stopped being observed'
  : > "$home/forge/fault"
  out=$(poll_at 2026-09-16T11:00:00Z)
  [ -z "$out" ] || fail "a successful read printed: $out"
  jq -e '.records[0].error == null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a successful read did not end the failure episode'
  printf 'down\n' > "$home/forge/fault"
  out=$(poll_at 2026-09-16T12:00:00Z)
  [ "$out" = "$line" ] || fail "a new failure after a successful read did not wake: $out"
  pass 'a genuinely unavailable forge records an error and wakes once per failure episode'
}

test_late_owner_keeps_failure_episode_suppressed() {
  local home out line='contributions: observation unavailable for https://github.com/o/r/pull/8'
  local error='forge observation unavailable or changed during read' task
  home=$(new_home late-owner-failure-episode)
  forge_home "$home"
  wrap_forge "$home"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial failing poll failed'
  [ "$out" = "$line" ] || fail "the initial failure did not wake: $out"
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'late-owner failing poll failed'
  [ -z "$out" ] || fail "a late owner restarted an unchanged failure episode: $out"
  for task in delivery duplicate; do
    jq -e --arg error "$error" '.records[0].error == $error' "$home/data/$task/contributions.json" >/dev/null \
      || fail "owner $task did not retain the shared failure evidence"
  done
  : > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'successful shared poll failed'
  [ -z "$out" ] || fail "a successful shared poll printed: $out"
  for task in delivery duplicate; do
    jq -e '.records[0].error == null' "$home/data/$task/contributions.json" >/dev/null \
      || fail "owner $task did not end the shared failure episode"
  done
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'new shared failing poll failed'
  [ "$out" = "$line" ] || fail "a failure after shared recovery did not wake: $out"
  pass 'a late owner does not restart a shared forge failure episode'
}

test_outside_pr_closeout_window_and_green_ci() {
  local home out
  home=$(new_home outside-closeout-window)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register outside PR'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial outside PR observation failed'
  [ -z "$out" ] || fail "a new outside PR closed out immediately: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:59:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'inside-window outside PR poll failed'
  [ -z "$out" ] || fail "an outside PR woke before its two-hour window: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'expired outside PR poll failed'
  case "$out" in *'state=ready'*) ;; *) fail "green clean outside PR did not become cleanup-due: $out" ;; esac
  [ "$(awk -F '\t' '$3 == "check" {n++} END {print n+0}' "$home/state/.wake-queue")" = 1 ] \
    || fail 'cleanup due was not durably enqueued exactly once'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'repeat closeout observation failed'
  [ -z "$out" ] && [ "$(awk -F '\t' '$3 == "check" {n++} END {print n+0}' "$home/state/.wake-queue")" = 1 ] \
    || fail "a stable closeout episode woke more than once: $out"
  rm "$home/state/delivery.meta"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:10:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'post-cleanup contribution observation failed'
  [ -z "$out" ] || fail "a retained contribution was treated as another cleanup: $out"
  pass 'outside PR closeout waits two hours, then signals once for green clean work'
}

test_own_repository_pr_is_unchanged() {
  local home out head_repo permission
  for permission in ADMIN MAINTAIN WRITE; do
    for head_repo in owner/r fork/r; do
      home=$(new_home "owned-$permission-${head_repo%%/*}")
      forge_home "$home"
      printf '%s\n' "$permission" > "$home/forge/permission"
      printf '2026-09-16T08:00:00Z\n' > "$home/forge/pr-time"
      printf '%s\n' "$head_repo" > "$home/forge/head-repo"
      with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
        || fail 'could not register owned PR'
      out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
        || fail 'owned PR observation failed'
      [ -z "$out" ] && [ ! -s "$home/state/.wake-queue" ] \
        || fail "$permission base permission gained a closeout wake: $out"
      jq -e --arg permission "$permission" '.records[0].observation | .viewer_permission == $permission and .can_merge == true' \
        "$home/data/delivery/contributions.json" >/dev/null || fail 'write-or-higher permission did not establish merge readiness'
    done
  done
  pass 'write-or-higher forge permissions retain merge-based cleanup across PR topologies'
}

test_registered_clones_do_not_establish_ownership() {
  local home out head_repo permission
  for permission in READ TRIAGE; do
    for head_repo in owner/r fork/r; do
      home=$(new_home "registered-outside-$permission-${head_repo%%/*}")
      forge_home "$home"
      with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
        || fail 'could not register outside PR'
      printf '%s\n' "$permission" > "$home/forge/permission"
      printf '%s\n' "$head_repo" > "$home/forge/head-repo"
      printf '2026-09-16T08:00:00Z\n' > "$home/forge/pr-time"
      mkdir -p "$home/projects/registered"
      git -C "$home/projects/registered" init -q
      git -C "$home/projects/registered" remote add origin https://alice@github.com/Owner/r.git
      printf -- '- registered [no-mistakes] - Third-party repository (added 2026-09-16)\n' > "$home/data/projects.md"
      out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
        || fail 'registered outside repository observation failed'
      case "$out" in *'state=ready'*) ;; *) fail "a registered clone with $permission permission suppressed closeout: $out" ;; esac
      jq -e --arg permission "$permission" '.records[0].observation | .viewer_permission == $permission and .can_merge == false' \
        "$home/data/delivery/contributions.json" >/dev/null || fail 'read-or-triage permission incorrectly established merge readiness'
    done
  done
  pass 'registered third-party clones remain outside according to forge permissions'
}

test_unreadable_permission_blocks_closeout() {
  local home out scenario
  for scenario in missing null unknown wrong-type inaccessible request-error; do
    home=$(new_home "permission-unavailable-$scenario")
    forge_home "$home"
    with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
      || fail 'could not register PR before permission failure'
    printf '0\n' > "$home/config/outside-pr-review-window-hours"
    case "$scenario" in
      missing) printf '{"data":{"repository":{}}}\n' ;;
      null) printf '{"data":{"repository":{"viewerPermission":null}}}\n' ;;
      unknown) printf '{"data":{"repository":{"viewerPermission":"UNKNOWN"}}}\n' ;;
      wrong-type) printf '{"data":{"repository":{"viewerPermission":false}}}\n' ;;
      inaccessible) printf '{"data":{"repository":null},"errors":[{"message":"Not accessible"}]}\n' ;;
      request-error) : > "$home/forge/permission-error" ;;
    esac > "$home/forge/permission-response.json"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'permission failure poll failed'
    [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
      || fail "$scenario permission did not block and report closeout: $out"
    jq -e '.records[0].error != null and .records[0].closeout_notice == null' \
      "$home/data/delivery/contributions.json" >/dev/null || fail 'unreadable permission authorized closeout'
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'repeat permission failure poll failed'
    [ -z "$out" ] || fail "unchanged permission failure repeated its diagnostic: $out"
    rm -f "$home/forge/permission-response.json" "$home/forge/permission-error"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'permission recovery poll failed'
    case "$out" in *'state=ready'*) ;; *) fail "readable outside permission did not restore closeout: $out" ;; esac
  done
  pass 'unreadable permissions report once and never authorize closeout before recovery'
}

# Contract: docs/configuration.md requires readable permissions at closeout.
# A prior READ observation must not authorize cleanup after a lookup fails.
test_permission_lookup_failure_after_readable_observation() {
  local home out
  home=$(new_home permission-lost-at-expiry)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register PR before permission lookup failure'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'readable permission baseline failed'
  jq -e '.records[0].observation.viewer_permission == "READ" and .records[0].error == null' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'baseline did not establish outside permission'
  : > "$home/forge/permission-error"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'permission lookup failure at expiry failed'
  [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
    || fail "unreadable permission reused prior cleanup authority: $out"
  jq -e '.records[0] | .checked_at == "2026-09-16T10:00:00Z" and .error != null and .closeout_notice == null' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'failed permission read authorized closeout'
  [ -f "$home/state/delivery.meta" ] && [ -d "$home/wt" ] || fail 'unreadable permission removed the task'
  [ ! -s "$home/state/.wake-queue" ] \
    || [ "$(awk -F '\t' 'index($0, "contributions closeout") {n++} END {print n+0}' "$home/state/.wake-queue")" = 0 ] \
    || fail 'unreadable permission enqueued a closeout wake'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'repeat unreadable permission poll failed'
  [ -z "$out" ] || fail "unreadable permission repeated its diagnostic or authorized cleanup: $out"
  rm "$home/forge/permission-error"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:10:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'permission lookup recovery failed'
  case "$out" in *'state=ready'*) ;; *) fail "restored outside permission did not permit closeout: $out" ;; esac
  pass 'an unreadable permission lookup cannot reuse prior outside cleanup authority'
}

test_initial_observation_uses_forge_timestamp() {
  local home out timestamp_kind
  for timestamp_kind in pr-time pr-created-time; do
    home=$(new_home "initial-forge-timestamp-$timestamp_kind")
    forge_home "$home"
    with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
      || fail 'could not register the current closeout PR'
    printf '2026-09-16T08:00:00Z\n' > "$home/forge/$timestamp_kind"
    printf 'owner/r\n' > "$home/forge/head-repo"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'delayed observation failed'
    case "$out" in *'state=ready'*) ;; *) fail "PR timestamp 08:00 first seen at 11:00 was not already due: $out" ;; esac
    jq -e '.records[0].closeout_since == "2026-09-16T08:00:00Z"' "$home/data/delivery/contributions.json" >/dev/null \
      || fail 'initial forge timestamp did not supply the saved review-window start'
    printf '2026-09-16T11:30:00Z\n' > "$home/forge/pr-time"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'CI rerun observation failed'
    [ -z "$out" ] || fail "CI rerun restarted closeout or repeated its wake: $out"
  done
  pass 'initial observation uses an available PR timestamp and later updates preserve the window'
}


test_missing_forge_timestamp_falls_back_to_observation() {
  local home out
  home=$(new_home missing-forge-timestamp)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the current closeout PR'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'observation without forge timestamp failed'
  [ -z "$out" ] || fail "missing forge timestamp expired the window immediately: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:59:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'fallback inside-window observation failed'
  [ -z "$out" ] || fail "fallback window ended early: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'fallback expiry observation failed'
  case "$out" in *'state=ready'*) ;; *) fail "fallback did not expire two hours after first observation: $out" ;; esac
  pass 'missing forge timestamps use the first observation without extending its window'
}

test_worker_head_can_precede_published_head() {
  local home out
  home=$(new_home pipeline-descendant-head)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the current closeout PR'
  printf '2026-09-16T08:00:00Z\n' > "$home/forge/pr-time"
  git -C "$home/wt" update-ref refs/remotes/fork/offer HEAD
  printf 'pipeline fix\n' >> "$home/wt/tracked"
  git -C "$home/wt" add tracked
  git -C "$home/wt" commit -qm 'pipeline fix'
  git -C "$home/wt" rev-parse HEAD > "$home/forge/head"
  git -C "$home/wt" reset --hard -q HEAD~1
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'pipeline descendant observation failed'
  case "$out" in *'state=ready'*) ;; *) fail "clean pushed worker head behind pipeline head was held: $out" ;; esac
  pass 'a clean pushed worker checkout behind the PR head remains eligible for guarded teardown'
}

test_red_ci_holds_closeout() {
  local home out
  home=$(new_home red-ci-closeout)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register outside PR for red CI case'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial outside PR observation failed'
  printf '%s\n' '[{"check_runs":[{"name":"test","id":2,"status":"completed","conclusion":"failure","started_at":"2026-09-16T10:00:00Z"}]}]' \
    > "$home/forge/checks.json"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'red CI outside PR poll failed'
  case "$out" in *'state=ci'*) ;; *) fail "red CI was not reported as a closeout hold: $out" ;; esac
  case "$out" in *'state=ready'*) fail 'red CI was marked ready for cleanup' ;; esac
  pass 'red CI notifies firstmate and holds the task in place'
}

# Contract: docs/configuration.md requires every previously observed CI lane.
# Losing one lane must revoke readiness even while the remaining lane is green.
test_ci_lane_disappearing_after_ready_holds_closeout() {
  local home out head
  home=$(new_home disappearing-lane-closeout)
  forge_home "$home"
  head=$(cat "$home/forge/head")
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register PR before CI lane disappearance'
  printf '%s\n' '[{"check_runs":[
    {"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"},
    {"name":"required-extra","id":2,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]' > "$home/forge/checks.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'complete CI baseline failed'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'complete CI expiry poll failed'
  case "$out" in *'state=ready'*) ;; *) fail "complete green CI did not establish readiness: $out" ;; esac
  printf '%s\n' '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]' \
    > "$home/forge/checks.json"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'disappearing CI lane poll failed'
  [ "$out" = "contribution-wake: check: contributions closeout delivery https://github.com/o/r/pull/8 head=$head state=ci" ] \
    || fail "disappearing lane retained cleanup readiness: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:10:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'repeated disappearing CI lane poll failed'
  [ -z "$out" ] || fail "missing lane repeated its hold or authorized cleanup: $out"
  jq -e --arg head "$head" '.records[0] | .observation.head == $head
    and .observation.absent_checks == ["required-extra"] and .closeout_notice == ($head + ":ci")' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'repeated polling lost the disappeared CI lane'
  [ -f "$home/state/delivery.meta" ] && [ -d "$home/wt" ] || fail 'missing CI lane removed the task'
  [ "$(awk -F '\t' '$3 == "check" {n++} END {print n+0}' "$home/state/.wake-queue")" = 2 ] \
    || fail 'lane disappearance did not enqueue exactly one new hold'
  pass 'a disappearing CI lane revokes closeout readiness and keeps the task held'
}

test_new_push_restarts_closeout_window() {
  local home out
  home=$(new_home pushed-fix-closeout)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register outside PR for push case'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial outside PR observation failed'
  printf 'fixed\n' >> "$home/wt/tracked"
  git -C "$home/wt" add tracked
  GIT_AUTHOR_DATE=2026-09-16T10:00:00Z GIT_COMMITTER_DATE=2026-09-16T10:00:00Z \
    git -C "$home/wt" commit -qm fix
  git -C "$home/wt" rev-parse HEAD > "$home/forge/head"
  printf '2026-09-16T08:00:00Z\n' > "$home/forge/pr-time"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'new pushed head observation failed'
  [ -z "$out" ] || fail "new push did not restart its review window: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:59:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'post-push inside-window poll failed'
  [ -z "$out" ] || fail "new head closed out before two hours: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'post-push expiry poll failed'
  case "$out" in *'state=ready'*) ;; *) fail "new head did not become closeout-due after its own window: $out" ;; esac
  pass 'a changed PR head restarts the closeout window'
}

# Contract: docs/configuration.md gives each observed head change two hours.
# Reject both inheriting an expired window and reusing a returned SHA's old window.
test_returned_head_restarts_closeout_window() {
  local home out initial_head replacement_head
  home=$(new_home returned-head-closeout)
  forge_home "$home"
  git init --bare -q "$home/fork.git"
  git -C "$home/wt" remote add fork "$home/fork.git"
  git -C "$home/wt" push -q fork HEAD:refs/heads/offer || fail 'initial offer push failed'
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the current closeout PR'
  printf '2026-09-16T08:00:00Z\n' > "$home/forge/pr-time"
  initial_head=$(cat "$home/forge/head")
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial head observation failed'
  [ -z "$out" ] || fail "initial head did not receive a review window: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial head expiry poll failed'
  case "$out" in *"head=$initial_head state=ready"*) ;; *) fail "initial head did not expire after two hours: $out" ;; esac
  printf 'fix\n' >> "$home/wt/tracked"
  git -C "$home/wt" add tracked
  git -C "$home/wt" commit -qm fix
  git -C "$home/wt" push -q fork HEAD:refs/heads/offer || fail 'replacement offer push failed'
  git --git-dir="$home/fork.git" rev-parse refs/heads/offer > "$home/forge/head"
  replacement_head=$(cat "$home/forge/head")
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'replacement head observation failed'
  [ -z "$out" ] || fail "replacement head inherited the expired window: $out"
  jq -e --arg head "$replacement_head" '.records[0] | .closeout_head == $head and .closeout_since == "2026-09-16T11:00:00Z"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'replacement head did not persist a fresh window'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:59:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'replacement head inside-window poll failed'
  [ -z "$out" ] || fail "replacement head closed out before its new window expired: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'replacement head expiry poll failed'
  case "$out" in *"head=$replacement_head state=ready"*) ;; *) fail "replacement head did not expire after two hours: $out" ;; esac
  git -C "$home/wt" reset --hard -q "$initial_head"
  git -C "$home/wt" push --force -q fork HEAD:refs/heads/offer || fail 'returned offer push failed'
  git --git-dir="$home/fork.git" rev-parse refs/heads/offer > "$home/forge/head"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T14:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'returned head observation failed'
  [ -z "$out" ] || fail "an older SHA reused its historical window: $out"
  jq -e --arg head "$initial_head" '.records[0] | .closeout_head == $head and .closeout_since == "2026-09-16T14:00:00Z"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'returned head did not persist a fresh window'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T15:59:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'returned head inside-window poll failed'
  [ -z "$out" ] || fail "returned head closed out before its new window expired: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T16:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'returned head expiry poll failed'
  case "$out" in *"head=$initial_head state=ready"*) ;; *) fail "returned head did not close out after its new two-hour window: $out" ;; esac
  pass 'A to B to A starts a new window for every observed head change'
}

test_zero_and_malformed_closeout_window() {
  local home out
  home=$(new_home closeout-window-config)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register outside PR for config cases'
  printf '0\n' > "$home/config/outside-pr-review-window-hours"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'zero-hour closeout poll failed'
  case "$out" in *'state=ready'*) ;; *) fail "zero did not mean immediate closeout: $out" ;; esac
  printf 'two\n' > "$home/config/outside-pr-review-window-hours"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll failed while reporting malformed config'
  [[ "$out" == *'invalid config/outside-pr-review-window-hours'* ]] \
    || fail "malformed closeout config was not reported: $out"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'repeat malformed-config poll failed'
  [ -z "$out" ] || fail "same malformed-config episode woke more than once: $out"
  pass 'zero means immediate closeout and malformed configuration fails visibly'
}

test_unacknowledged_feedback_with_observation_fallback() {
  local home out type fixture token
  for type in review comment inline; do
    home=$(new_home "feedback-fallback-$type")
    forge_home "$home"
    with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
      || fail 'could not register the current closeout PR'
    case "$type" in review) fixture=reviews ;; comment) fixture=comments ;; inline) fixture=inline ;; esac
    jq -n --arg head "$(cat "$home/forge/head")" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
      body:"Please clarify",html_url:"https://github.com/o/r/pull/8#feedback-12",
      updated_at:"2026-09-16T10:30:00Z",submitted_at:"2026-09-16T10:30:00Z",commit_id:$head,state:"COMMENTED"}]' > "$home/forge/$fixture.json"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'initial feedback observation without forge timestamp failed'
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'fallback feedback expiry poll failed'
    case "$out" in *'state=review'*) ;; *) fail "observation fallback dismissed unacknowledged $type feedback: $out" ;; esac
    token=$(jq -r '.records[0].pending[0].token' "$home/data/delivery/contributions.json")
    with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" \
      || fail 'fallback feedback acknowledgement failed'
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'acknowledged fallback feedback observation failed'
    case "$out" in *'state=ready'*) ;; *) fail "acknowledged $type feedback still blocked the fallback window: $out" ;; esac
  done
  pass 'observation fallback never dismisses unacknowledged feedback'
}

test_unanswered_feedback_and_dirty_worktree_hold_closeout() {
  local home out type token fixture
  for type in review comment inline; do
    home=$(new_home "feedback-closeout-$type")
    forge_home "$home"
    with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
      || fail 'could not register the current closeout PR'
    printf '2026-09-16T08:00:00Z\n' > "$home/forge/pr-time"
    printf 'CHANGES_REQUESTED\n' > "$home/forge/review-decision"
    case "$type" in review) fixture=reviews ;; comment) fixture=comments ;; inline) fixture=inline ;; esac
    jq -n --arg head "$(cat "$home/forge/head")" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
      body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#feedback-12",
      updated_at:"2026-09-16T07:59:00Z",submitted_at:"2026-09-16T07:59:00Z",commit_id:$head,state:"CHANGES_REQUESTED"}]' > "$home/forge/$fixture.json"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'feedback expiry observation failed'
    case "$out" in *'state=review'*) ;; *) fail "older unacknowledged $type feedback was not held: $out" ;; esac
    token=$(jq -r '.records[0].pending[0].token' "$home/data/delivery/contributions.json")
    with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" \
      || fail 'feedback acknowledgement failed'
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'acknowledged feedback observation failed'
    case "$out" in *'state=ready'*) ;; *) fail "acknowledged $type feedback or review decision still blocked cleanup: $out" ;; esac
    jq '.[0].updated_at="2026-09-16T10:06:00Z" | .[0].submitted_at="2026-09-16T10:06:00Z"' \
      "$home/forge/$fixture.json" > "$home/forge/new-feedback.json"
    mv "$home/forge/new-feedback.json" "$home/forge/$fixture.json"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:10:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'renewed feedback observation failed'
    case "$out" in *'state=review'*) ;; *) fail "edited $type feedback did not hold closeout again: $out" ;; esac
    printf 'fix\n' >> "$home/wt/tracked"
    git -C "$home/wt" add tracked
    git -C "$home/wt" commit -qm fix
    git -C "$home/wt" rev-parse HEAD > "$home/forge/head"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'pushed fix observation failed'
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'post-feedback pushed fix observation failed'
    case "$out" in *'state=review'*) ;; *) fail "a pushed fix dismissed unacknowledged $type feedback: $out" ;; esac
    jq -e '(.records[0].pending | length) == 1' "$home/data/delivery/contributions.json" >/dev/null \
      || fail 'closeout consumed feedback instead of retaining observer acknowledgement'
    token=$(jq -r '.records[0].pending[0].token' "$home/data/delivery/contributions.json")
    with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" \
      || fail 'post-push feedback acknowledgement failed'
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:05:00Z "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'acknowledged post-push observation failed'
    case "$out" in *'state=ready'*) ;; *) fail "acknowledged $type feedback blocked post-push closeout: $out" ;; esac
  done
  home=$(new_home dirty-closeout)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register outside PR for dirty workspace case'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'clean baseline observation failed'
  printf 'uncommitted\n' >> "$home/wt/tracked"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:01:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'dirty workspace expiry poll failed'
  case "$out" in *'state=workspace'*) ;; *) fail "dirty worktree was not held: $out" ;; esac
  pass 'unanswered review feedback and dirty worktrees hold closeout'
}

test_replaced_pr_cannot_closeout_current_task() {
  local home out token
  home=$(new_home replaced-pr-closeout)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register original PR'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'original PR observation failed'
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/9 >/dev/null \
    || fail 'could not replace task PR'
  printf 'control_relaunch_tx=relaunch-fixture\ntraceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n' >> "$home/state/delivery.meta"
  printf '2026-09-16T11:00:00Z\n' > "$home/forge/pr-time"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'replacement PR observation failed'
  [ -z "$out" ] && [ ! -s "$home/state/.wake-queue" ] \
    || fail "the expired original PR bypassed the current PR window: $out"
  jq -e '(.records | length) == 2 and any(.records[]; .url == "https://github.com/o/r/pull/8"
    and .closeout_since == "2026-09-16T08:00:00Z" and .closeout_notice == null)
    and any(.records[]; .url == "https://github.com/o/r/pull/9" and .closeout_since == "2026-09-16T11:00:00Z")' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'replacement discarded the original contribution or reused its window'
  printf '%s\n' '[{"id":12,"user":{"login":"maintainer"},"author_association":"OWNER",
    "body":"Please clarify","html_url":"https://github.com/o/r/pull/8#issuecomment-12","updated_at":"2026-09-16T11:30:00Z"}]' > "$home/forge/comments.json"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:30:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'retained PR feedback observation failed'
  jq -e 'any(.records[]; .url == "https://github.com/o/r/pull/8" and (.pending | length) == 1)' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'replaced PR stopped observing feedback'
  case "$out" in *'contributions closeout'*) fail "retained PR feedback emitted a closeout signal: $out" ;; esac
  token=$(jq -r '.records[] | select(.url == "https://github.com/o/r/pull/9") | .pending[0].token' "$home/data/delivery/contributions.json")
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/9 "$token" \
    || fail 'current PR feedback acknowledgement failed'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T13:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'current PR expiry observation failed'
  [ "$out" = "contribution-wake: check: contributions closeout delivery https://github.com/o/r/pull/9 head=$(cat "$home/forge/head") state=ready" ] \
    || fail "expiry did not select only the current PR: $out"
  pass 'replaced PRs retain feedback observation while only the current PR can close out a ship'
}

test_closeout_requires_current_ship_metadata() {
  local home out scenario
  for scenario in scout secondmate missing-kind missing-pr invalid-pr duplicate-pr; do
    home=$(new_home "closeout-metadata-$scenario")
    forge_home "$home"
    printf '0\n' > "$home/config/outside-pr-review-window-hours"
    case "$scenario" in
      scout|secondmate) printf 'worktree=%s/wt\nkind=%s\npr=https://github.com/o/r/pull/8\n' "$home" "$scenario" ;;
      missing-kind) printf 'worktree=%s/wt\npr=https://github.com/o/r/pull/8\n' "$home" ;;
      missing-pr) printf 'worktree=%s/wt\nkind=ship\n' "$home" ;;
      invalid-pr) printf 'worktree=%s/wt\nkind=ship\npr=https://github.com/o/r/pull/8?bad\n' "$home" ;;
      duplicate-pr) printf 'worktree=%s/wt\nkind=ship\npr=https://github.com/o/r/pull/8\npr=https://github.com/o/r/pull/9\n' "$home" ;;
    esac > "$home/state/delivery.meta"
    printf 'control_relaunch_tx=relaunch-fixture\ntraceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n' >> "$home/state/delivery.meta"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'ineligible task observation failed'
    [ -z "$out" ] && [ ! -s "$home/state/.wake-queue" ] || fail "$scenario metadata authorized closeout: $out"
    jq -e '.records[0].checked_at == "2026-09-16T08:00:00Z" and .records[0].error == null' \
      "$home/data/delivery/contributions.json" >/dev/null || fail "$scenario task stopped observing its linked contribution"
  done
  pass 'closeout requires a ship with one valid current canonical PR'
}

test_closeout_accepts_supported_metadata_tails() {
  local home out layout
  for layout in relaunch traced relaunch-traced; do
    home=$(new_home "closeout-metadata-$layout")
    forge_home "$home"
    with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
      || fail 'could not register PR before appending producer metadata'
    case "$layout" in
      relaunch|relaunch-traced) printf 'control_relaunch_tx=relaunch-fixture\n' >> "$home/state/delivery.meta" ;;
    esac
    case "$layout" in
      traced|relaunch-traced) printf 'traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n' >> "$home/state/delivery.meta" ;;
    esac
    printf '0\n' > "$home/config/outside-pr-review-window-hours"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'supported metadata observation failed'
    [ "$out" = "contribution-wake: check: contributions closeout delivery https://github.com/o/r/pull/8 head=$(cat "$home/forge/head") state=ready" ] \
      || fail "$layout metadata suppressed a valid ship closeout: $out"
    [ "$(awk -F '\t' '$3 == "check" {n++} END {print n+0}' "$home/state/.wake-queue")" = 1 ] \
      || fail "$layout metadata did not enqueue exactly one closeout wake"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'repeat supported metadata observation failed'
    [ -z "$out" ] || fail "$layout metadata repeated its closeout wake: $out"
  done
  pass 'relaunch and trace metadata tails preserve current ship closeout eligibility'
}

test_retire_ends_observation_of_a_gone_contribution() {
  local home out line='contributions: observation unavailable for https://github.com/o/r/pull/8' url=https://github.com/o/r/pull/8
  home=$(new_home retire-gone)
  forge_home "$home"
  wrap_forge "$home"
  printf 'not-found\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) || fail 'failing poll failed'
  [ "$out" = "$line" ] || fail "a gone repository did not raise the unavailable check: $out"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unreadable contribution did not hold coverage incomplete before retirement'
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:30:00Z "$ROOT/bin/fm-contributions.sh" retire delivery "$url" captain 'repository deleted' \
    || fail 'retire of an owned unreadable contribution failed'
  jq -e '.records[0].retired == {actor:"captain",reason:"repository deleted",at:"2026-09-16T09:30:00Z"}' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'retire did not record its provenance'
  : > "$home/forge/calls"
  for at in 2026-09-16T10:00:00Z 2026-09-16T10:05:00Z; do
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$at" "$ROOT/bin/fm-contributions.sh" poll) || fail "poll after retire failed at $at"
    [ -z "$out" ] || fail "a retired contribution still raised a check: $out"
  done
  [ ! -s "$home/forge/calls" ] || fail "a retired contribution stayed in rotation: $(cat "$home/forge/calls")"
  bearings "$home" | jq -e '.contributions.known == 0 and .contributions.checked == 0
    and .contributions.complete == true and .contributions.proven_clear == true' >/dev/null \
    || fail 'a retired contribution still counted against coverage despite its backlog link'
  pass 'retire stops the unavailable check, leaves rotation and restores complete coverage'
}

test_late_owner_of_a_retired_final_contribution_is_not_retired() {
  local home out
  home=$(new_home retire-late-owner)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].observation.state="merged"
    | .records[0].retired={actor:"captain",reason:"repository deleted",at:"2026-09-16T09:30:00Z"}'
  record "$home" duplicate 8 merged mergeable
  mutate_record "$home" duplicate '.records[0].error="forge observation unavailable or changed during read"'
  printf -- '- [ ] late - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-17T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) || fail 'late-owner poll failed'
  [ -z "$out" ] || fail "a late owner of a retired final contribution printed: $out"
  [ ! -s "$home/forge/calls" ] || fail 'a known final contribution triggered a forge read'
  jq -e '.records[0] | .retired == null and .observation.state == "merged" and .error == null' \
    "$home/data/late/contributions.json" >/dev/null || fail 'a late owner inherited another task'"'"'s retirement'
  jq -e '.records[0].retired.reason == "repository deleted"' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'settling a late owner changed the retired record'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || fail 'contribution input failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all | jq -e '.rows[0].tasks == ["duplicate","late"]' >/dev/null \
    || fail 'a late owner settled beside a retired final record left known'
  pass 'a late owner settled beside a retired final record stays unretired and known'
}

test_retire_is_idempotent_and_refuses_unknown_pairs() {
  local home url=https://github.com/o/r/pull/8 before err
  home=$(new_home retire-refusals)
  forge_home "$home"
  retire() { with_home "$home" "$ROOT/bin/fm-contributions.sh" retire "$@"; }
  retire delivery "$url" fleet 'repository deleted' >/dev/null 2>&1 && fail 'retire accepted the fleet as its actor'
  jq -e '.records[0].retired == null' "$home/data/delivery/contributions.json" >/dev/null || fail 'a fleet retire changed the record'
  retire delivery "$url" captain 'repository deleted' >/dev/null || fail 'first retire failed'
  before=$(cat "$home/data/delivery/contributions.json")
  retire delivery "$url" captain 'second reason' >/dev/null || fail 'repeating a retire was refused'
  [ "$(cat "$home/data/delivery/contributions.json")" = "$before" ] || fail 'repeating a retire rewrote its first provenance'
  printf -- '- [ ] linked - Linked only https://github.com/o/r/pull/30 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  err=$(retire linked https://github.com/o/r/pull/30 captain gone 2>&1) && fail 'retire created a record for an unobserved pair'
  case "$err" in *'not recorded for this durable task'*) ;; *) fail "unrecorded-pair refusal was unclear: $err" ;; esac
  [ ! -e "$home/data/linked/contributions.json" ] || fail 'a refused retire created a record'
  retire other "$url" captain gone >/dev/null 2>&1 && fail 'retire accepted a task that does not own the URL'
  record "$home" queued 31 open mergeable
  retire queued https://github.com/o/r/pull/31 owner gone >/dev/null 2>&1 && fail 'retire accepted an unknown actor'
  retire queued https://github.com/o/r/pull/31 captain '' >/dev/null 2>&1 && fail 'retire accepted an empty reason'
  retire queued https://github.com/o/r/pull/31 captain ' 	 ' >/dev/null 2>&1 && fail 'retire accepted a whitespace-only reason'
  retire queued https://github.com/o/r/pull/31 captain >/dev/null 2>&1 && fail 'retire accepted a missing reason'
  mutate_record "$home" queued '.records[0].pending=[{token:"comment:1:x",type:"comment"}]'
  retire queued https://github.com/o/r/pull/31 captain gone >/dev/null 2>&1 && fail 'retire dropped an unacknowledged signal'
  jq -e '.records[0].retired == null' "$home/data/queued/contributions.json" >/dev/null || fail 'a refused retire changed the record'
  pass 'retire is idempotent and refuses non-captain, unknown, malformed and signal-bearing pairs'
}

failures=0
for test_name in test_actor_coverage test_stale_verdict test_unchecked_is_not_silence test_newest_check_has_no_verdict test_comment_wake test_review_wake test_inline_wake test_ready_issue_wake test_fresh_issue_requires_maintainer test_missing_lane_remains_missing test_partial_freshness_keeps_measured_rows test_malformed_record_cannot_prove_silence test_issue_timeline_and_exact_ack test_verdict_retains_judged_head test_verdict_actor_values_are_discoverable test_observed_replacement_refreshes_verdict test_unobserved_head_leaves_verdict_unknown test_away_yolo_is_fleet_work test_away_yolo_cross_home_is_fleet_work test_retired_and_unsupported_coverage test_unsupported_forge_is_not_fleet_work test_held_unsupported_forge_is_not_captain_work test_shared_contribution_signal_wakes_once test_watcher_keeps_diagnostics_separate_from_contribution_wakes test_expired_child_unsupported_forge_stays_unmeasured test_watcher_surfaces_new_contribution_once test_home_summary_coverage test_unreadable_pending_is_not_empty test_record_task_identity_matches_dirname_basename test_read_only_views_create_no_state test_budget_refusal_between_calls test_budget_bounded_call_timeout test_genuine_failure_near_deadline_is_unavailable test_shared_url_observed_once test_terminal_contribution_settles test_late_owner_inherits_terminal_observation test_interrupted_multi_owner_poll_settles_every_owner test_done_task_open_pr_still_observed test_reservation_defers_later_url_when_fifteen_seconds_do_not_remain test_three_second_pr_reads_complete_fresh_in_one_cycle test_slow_read_deadline_kill_is_budget_refusal test_unmeasured_url_does_not_starve_the_tail test_budget_is_cut_down_to_the_watcher_check_bound test_arm_plumbs_a_configured_budget_into_the_check_shim test_unavailable_forge_records_error_and_wakes_once_per_episode test_late_owner_keeps_failure_episode_suppressed test_outside_pr_closeout_window_and_green_ci test_own_repository_pr_is_unchanged test_red_ci_holds_closeout test_new_push_restarts_closeout_window test_zero_and_malformed_closeout_window test_unanswered_feedback_and_dirty_worktree_hold_closeout test_initial_observation_uses_forge_timestamp test_missing_forge_timestamp_falls_back_to_observation test_worker_head_can_precede_published_head test_returned_head_restarts_closeout_window test_unacknowledged_feedback_with_observation_fallback test_registered_clones_do_not_establish_ownership test_unreadable_permission_blocks_closeout test_replaced_pr_cannot_closeout_current_task test_closeout_requires_current_ship_metadata test_closeout_accepts_supported_metadata_tails test_ci_lane_disappearing_after_ready_holds_closeout test_permission_lookup_failure_after_readable_observation test_retire_ends_observation_of_a_gone_contribution test_late_owner_of_a_retired_final_contribution_is_not_retired test_retire_is_idempotent_and_refuses_unknown_pairs; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures contribution regressions"

test_automated_reviewer_signal() {
  local home out
  home=$(new_home automated-review)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -n '[{id:31,user:{login:"dependabot[bot]"},author_association:"NONE",body:"Bumps a dependency",
    html_url:"https://github.com/o/r/pull/8#issuecomment-31",updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 0' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'an unconfigured bot comment must raise no pending signal'
  [ ! -s "$home/state/.wake-queue" ] || fail 'an unconfigured bot comment must raise no wake'
  jq -n --arg head "$HEAD_A" '[{id:32,user:{login:"Copilot-Pull-Request-Reviewer[bot]"},author_association:"NONE",
    body:"Possible nil dereference",html_url:"https://github.com/o/r/pull/8#discussion_r32",
    updated_at:"2026-09-16T08:02:00Z",commit_id:$head}]' > "$home/forge/inline.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 1 and .[0].automated == true and .[0].author == "Copilot-Pull-Request-Reviewer[bot]"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an automated inline comment must persist as a pending signal'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 1 ] || fail 'an automated inline comment must enqueue exactly one wake'
  registered_checks "$home" >/dev/null
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 1 ] || fail 're-poll duplicated the automated-review wake'
  out=$(bearings "$home") || fail 'Bearings could not read the automated review fixture'
  printf '%s' "$out" | jq -e '.contributions.counts.fleet == 1 and .contributions.counts.captain == 0' >/dev/null \
    || fail "an automated finding must be fleet triage work, never a captain call: $out"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 1 and .[0].automated == true' >/dev/null \
    || fail 'supervisor cannot retrieve the automated finding'
  pass 'a configured automated reviewer wakes as fleet triage and an unconfigured bot does not'
}

test_automated_reviewer_configuration() {
  local home
  home=$(new_home automated-config)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  jq -n '[{id:41,user:{login:"dependabot[bot]"},author_association:"NONE",body:"Check this",
    html_url:"https://github.com/o/r/pull/8#issuecomment-41",updated_at:"2026-09-16T08:01:00Z"},
    {id:42,user:{login:"copilot-pull-request-reviewer[bot]"},author_association:"NONE",body:"Nit",
    html_url:"https://github.com/o/r/pull/8#issuecomment-42",updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  with_home "$home" env FM_CONTRIBUTIONS_AUTOMATED_REVIEWERS= "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'disabled poll failed'
  jq -e '.records[0].pending | length == 0' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'an empty reviewer list must disable automated intake'
  with_home "$home" env FM_CONTRIBUTIONS_AUTOMATED_REVIEWERS=' Dependabot[bot] ' "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'extended poll failed'
  jq -e '.records[0].pending | length == 1 and .[0].author == "dependabot[bot]"' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the environment list must replace the defaults'
  pass 'the automated reviewer set is configurable and can be disabled'
}

test_author_marker_directive() {
  local home
  home=$(new_home author-marker)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  jq -n '[{id:51,user:{login:"author"},author_association:"OWNER",body:"thanks, fixed",
    html_url:"https://github.com/o/r/pull/8#issuecomment-51",updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 0' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'an ordinary author comment must stay ignored'
  [ ! -s "$home/state/.wake-queue" ] || fail 'an ordinary author comment must raise no wake'
  jq -n '[{id:52,user:{login:"author"},author_association:"OWNER",body:"  @Firstmate please rebase",
    html_url:"https://github.com/o/r/pull/8#issuecomment-52",updated_at:"2026-09-16T08:02:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 1 and .[0].directive == true' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a marked author comment must persist as a pending signal'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 1 ] || fail 'a marked author comment must enqueue one wake'
  jq -n '[{id:53,user:{login:"author"},author_association:"OWNER",body:"@ops please rebase",
    html_url:"https://github.com/o/r/pull/8#issuecomment-53",updated_at:"2026-09-16T08:03:00Z"}]' > "$home/forge/comments.json"
  with_home "$home" env FM_CONTRIBUTIONS_AUTHOR_MARKER=@ops "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'custom marker poll failed'
  jq -e '.records[0].pending | length == 2' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the environment marker must replace the default'
  pass 'an author comment is an event only with the configured marker'
}

test_closed_backlog_pr_owns_landed_contribution
test_automated_reviewer_signal
test_automated_reviewer_configuration
test_author_marker_directive

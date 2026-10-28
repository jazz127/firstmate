#!/usr/bin/env bash
# Behavior tests for watcher wedge-threshold deferrals to declared waits,
# captain holds, parked gates, worker blockers, and validation runs
# (bin/fm-watch.sh). Shared fixtures live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-wedge-defer-tests)

# Arm the opt-in parked-gate wait evidence for a fixture built above.
arm_parked_gate() {  # <case-dir>
  : > "$1/config/wedge-defer-parked-gate"
}


# --- a parked human-owed gate also needs the human to still owe an answer ----
# The gate's findings table says who the answer is owed BY. It does not say the
# human was ever asked, and it does not stop saying `ask-user` once they answer:
# the run stays parked, and the row stays in the table, until the CREWMATE relays
# the decision with `axi respond`. So a lane that is quiet because the crewmate
# wedged before relaying an answer it already has would read exactly like a lane
# waiting on firstmate - and would lose the ladder for the one failure the
# ladder exists to catch.
# The task's own decision fold is the record that closes that hole, because it is
# written at ANSWER time rather than at relay time: `fm-send --resolve-key`
# appends the closing `resolved` line the moment the decision is answered. An open
# `needs-decision` therefore means the human was told and has not answered; its
# absence means the outstanding move belongs to the crewmate, or that nobody was
# ever told at all. Each of those keeps the unchanged schedule below.
test_wedge_threshold_parked_gate_needs_an_unanswered_decision() {
  local dir state fakebin out capture window key n
  local human='state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · ask-user: authority decision · run: 01RUNGATE'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  # Answered, not yet relayed. The gate verdict is byte-identical to the one the
  # test above defers on; only the closing `resolved` line differs, and the
  # `resolved:` verb is not captain-relevant, so this lane takes the same plain
  # non-terminal route into the wedge timer as that one.
  dir=$(wedge_threshold_fixture parked-gate-decided \
    'needs-decision [key=nm-01RUNGATE-review]: the gate raised an authority question
resolved [key=nm-01RUNGATE-review]: firstmate chose the second fix' 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
      || fail "a decided-but-unrelayed gate stopped escalating at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge decided-gate escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "a decided-but-unrelayed gate did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "a decided-but-unrelayed gate lost the demand-deep-inspection wording: $(cat "$out")"
  grep -F 'verified wait at a parked gate' "$out" >/dev/null \
    && fail "a gate whose decision was already answered was deferred as a wait on the captain: $(cat "$out")"

  # Parked at a human-owed gate, quiet, and the crewmate never escalated it: no
  # human has been told, so there is no wait to defer to.
  dir=$(wedge_threshold_fixture parked-gate-unescalated 'working: validation under way' 2000)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
    || fail "a human-owed gate nobody was told about never escalated: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unescalated-gate escalation"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
    || fail "a human-owed gate nobody was told about did not take the unchanged ladder: $(cat "$out")"

  # An open `blocked` record is not an unanswered question: it is an obstacle the
  # crew reported, and a different action clears it. A `blocked:` last line is
  # captain-relevant, so this lane reaches the wedge timer through the
  # overridden-terminal-status branch instead, which only ever sees a hash whose
  # timer is already running - hence the fixture's fourth argument.
  dir=$(wedge_threshold_fixture parked-gate-blocked \
    'blocked [key=nm-01RUNGATE-review]: the fixture cannot reach its dependency' 2000 600)
  arm_parked_gate "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$human" exit \
    || fail "a human-owed gate with only a blocker open never escalated: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the blocked-gate escalation"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
    || fail "an open blocker was accepted as an unanswered gate decision: $(cat "$out")"
  pass "a parked human-owed gate is deferred only while its decision is still open, so an answered-but-unrelayed gate, an unescalated one, and one holding only a blocker all keep the unchanged ladder"
}

# --- a worker's own newest blocker or decision, behind its opt-in flag -------
# Upstream kunchenguid/firstmate#6899: a lane whose newest line is the worker's
# own `blocked:` or `needs-decision:` already woke firstmate, so in a home that
# armed config/wedge-defer-worker-wait the wedge timer defers it to the bounded
# recheck instead of climbing the ladder. `blocked:` is the verb pinned here
# because the parked-gate evidence above deliberately refuses it. A `blocked:`
# last line is captain-relevant, so every fixture arms the wedge timer (the
# fourth argument) to reach it through the overridden-terminal-status branch.
arm_worker_wait() {  # <case-dir>
  : > "$1/config/wedge-defer-worker-wait"
}

test_wedge_threshold_defers_to_a_worker_blocker() {
  local dir state fakebin out capture window key n reported case_log
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  dir=$(wedge_threshold_fixture worker-blocker-fresh \
    'working: wiring the client
blocked: need the API key for the staging account' 0 600)
  arm_worker_wait "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a worker blocker wedge-escalated at threshold $n in an armed home: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a worker blocker queued a wake inside the recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a worker blocker counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # House worker waits stay silent even beyond the normal recheck cadence.
  for declaration in 'blocked: need the API key for the staging account' \
    'needs-decision [key=scope]: ship the narrow fix or the broad one'; do
    dir=$(wedge_threshold_fixture worker-wait-aged "$declaration" 2000 600)
    arm_worker_wait "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "an aged declared worker wait raised an idle check-in: $(cat "$out")"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "an aged declared worker wait raised the escalation count"
  done

  # Each of these ends or never starts the deferral, so the lane keeps the ladder:
  # a newer worker line, a resolved line, a supervisor-reserved key, and an inbox
  # record the worker acknowledged after writing the blocker.
  for case_log in \
    'blocked: need the API key for the staging account
working: resumed without it' \
    'blocked: need the API key for the staging account
resolved: firstmate supplied the key' \
    'blocked [key=remote-reply-continuity-mate1]: the remote reply mirror stopped' \
    'blocked: need the API key for the staging account|handled'; do
    dir=$(wedge_threshold_fixture worker-blocker-ended "${case_log%|handled}" 2000 600)
    arm_worker_wait "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    case "$case_log" in
      *'|handled')
        mkdir -p "$state/wedge.inbox/handled"
        printf 'schema=fm-task-inbox.v1\n--\nthe key is in the vault\n' > "$state/wedge.inbox/handled/001.msg"
        ;;
    esac
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an ended or supervisor-owned blocker never escalated: ${case_log}: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the ended-blocker escalation"
    grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
      || fail "an ended or supervisor-owned blocker did not keep the ladder: ${case_log}: $(cat "$out")"
  done
  pass "in an armed home a worker's own open newest blocker or decision is deferred without idle rechecks, and a newer line, a resolved line, a reserved key, or a newer acknowledged inbox record keeps the ladder"
}

# Absent config/wedge-defer-worker-wait the same aged blocker escalates with the
# byte-identical reason it had before this evidence existed, and writes no
# recheck throttle.
test_wedge_threshold_worker_wait_is_off_until_armed() {
  local dir state fakebin out capture window key
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture worker-blocker-unarmed 'blocked: need the API key for the staging account' 2000 600)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  [ ! -e "$dir/config/wedge-defer-worker-wait" ] \
    || fail "the unarmed fixture armed the flag, so it proves nothing"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "an unarmed home stopped escalating a worker blocker: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unarmed worker-blocker escalation"
  grep -Ex 'stale: test:fm-wedge \(idle [0-9]+s, possible wedge, escalation 1\)' "$out" >/dev/null \
    || fail "an unarmed home changed the wedge reason for a worker blocker: $(cat "$out")"
  grep -F 'declared blocker' "$out" >/dev/null \
    && fail "an unarmed home deferred a worker blocker: $(cat "$out")"
  [ ! -e "$state/.waiting-resurfaced-$key" ] \
    || fail "an unarmed home wrote the worker-wait recheck throttle"
  pass "with config/wedge-defer-worker-wait absent a worker blocker keeps the byte-identical wedge reason"
}

# --- a wait record that does not carry every field is refused ----------------
# wait_record joins its five fields with US and wedge_defer_wait parses them with
# `IFS=<us> read`, so consecutive delimiters yield genuinely EMPTY fields and no
# field can shift left into another's position. That is what makes the deferral's
# guard able to enforce the whole contract rather than a position-specific slice
# of it: each field the recheck prints must be present, and a record carrying
# more than its four delimiters is refused too, since `read` puts any surplus
# into the final variable. Deferring on a record that is not what it claims is
# what takes the ladder away, so every one of these must fall back to the
# escalation the caller was about to make instead.
# No shipped evidence producer can emit a malformed record, which is precisely
# the invariant under test, so this loads the real bin/fm-watch.sh through its
# own source guard in a child shell (the entry tests/fm-supervision-events.test.sh
# uses) and drives the real wedge_timer_check. The assertion is on the durable
# wake queue the watcher actually wrote.

# One wedge_timer_check round against a malformed record. <evidence-body> is the
# body of a wedge_wait_evidence override, so a case supplies exactly the record
# under test. Publishes the state directory it ran in as MALFORMED_STATE rather
# than on stdout, because fail() exits the shell it runs in and a command
# substitution would swallow a setup failure here.
run_malformed_wait_record_round() {  # <name> <evidence-body>
  local name=$1 body=$2 dir state out
  dir=$(make_case "$name"); state="$dir/state"
  printf 'working: validation under way\n' > "$state/wedge.status"
  printf '%s\n' "$(( $(date +%s) - 600 ))" > "$state/.stale-since-test_fm-wedge"

  out="$dir/defer.out"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 \
    bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      wake() { :; }
      # A live agent, so the dead-record probe that runs after a refused
      # deferral keeps the unchanged ladder rather than reading a backend this
      # child shell has none of.
      fm_backend_agent_state() { printf alive; }
      crew_absorb_class() { printf working; }
      eval "wedge_wait_evidence() { $2 ; }"
      wedge_timer_check "test:fm-wedge" "$FM_STATE_OVERRIDE/.stale-since-test_fm-wedge" \
        "non-terminal stale" "$FM_STATE_OVERRIDE/.wedge-escalations-test_fm-wedge" wedge \
        malformed-record-pane
    ' _ "$WATCH" "$body" > "$out" 2>&1 \
    || fail "the wedge timer failed on a malformed wait record ($name): $(cat "$out")"
  MALFORMED_STATE=$state
}

assert_malformed_record_kept_the_ladder() {  # <state> <what>
  local state=$1 what=$2
  grep -F 'possible wedge, escalation 1' "$state/.wake-queue" >/dev/null \
    || fail "$what did not keep the unchanged ladder: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -F 'rechecked on a long cadence not a wedge' "$state/.wake-queue" >/dev/null \
    && fail "$what was deferred on a record that is not what it claims: $(cat "$state/.wake-queue")"
  [ "$(cat "$state/.wedge-escalations-test_fm-wedge" 2>/dev/null || echo 0)" -eq 1 ] \
    || fail "$what did not count its escalation"
}

test_wedge_defer_refuses_a_half_filled_wait_record() {
  # An empty subject - the field whose loss used to shift the prose action into
  # `whom` and print an action that clears nothing.
  run_malformed_wait_record_round malformed-wait-record \
    'wait_record "declared wait" "" external "confirm the wait still holds" ""'
  assert_malformed_record_kept_the_ladder "$MALFORMED_STATE" "a wait record with no subject"

  # An empty ACTION with a non-empty anchor. Under the old TAB join this parsed
  # as a valid record: the doubled tab collapsed, the anchor path slid into
  # `action`, and the recheck published a status-file path as the one thing that
  # clears the lane while silently losing the wait-age anchor.
  run_malformed_wait_record_round malformed-wait-record-no-action \
    "wait_record 'declared wait' 'awaiting external' external '' '$TMP_ROOT/anchor.status'"
  assert_malformed_record_kept_the_ladder "$MALFORMED_STATE" "a wait record with no action"

  # A record carrying a surplus delimiter: `read` puts everything past the last
  # field into `anchor`, so the fields after the extra one are not the fields
  # they are read as.
  run_malformed_wait_record_round malformed-wait-record-surplus \
    'printf "%s\\037%s\\037%s\\037%s\\037%s\\037%s" "declared wait" "awaiting external" external "confirm the wait still holds" "" extra'
  assert_malformed_record_kept_the_ladder "$MALFORMED_STATE" "a wait record with a surplus field"

  pass "a wait record missing a field the recheck must print, or carrying one it must not, is refused and the lane escalates exactly as it would have"
}

# --- an executing no-mistakes run is liveness, not a wedge candidate ---------
# While the pipeline runs or fixes a round the worker is idle behind its own
# blocking drive call, so a static pane is exactly what a healthy lane looks
# like. The attributed run step says so, and in a home that armed
# config/wedge-defer-validating the wedge timer defers to it on the same long
# recheck cadence as every other deferral instead of re-escalating a possible
# wedge each FM_STALE_ESCALATE_SECS.
arm_validating() {  # <case-dir>
  : > "$1/config/wedge-defer-validating"
}

test_wedge_threshold_defers_to_an_executing_validation_run() {
  local dir state fakebin out capture window key n verdict step queued
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  for step in running fixing; do
    verdict="state: working · source: run-step · validating ($step) · run: 01RUNLIVE"
    dir=$(wedge_threshold_fixture "validating-$step" 'working: handed to validation' 0)
    arm_validating "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    n=1
    while [ "$n" -le 3 ]; do
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
        || fail "a $step validation run wedge-escalated at threshold $n: $(cat "$out")"
      n=$((n + 1))
    done
    [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
      || fail "a $step validation run queued a stale wake: $(cat "$state/.wake-queue")"
    grep -F 'possible wedge' "$out" >/dev/null \
      && fail "a $step validation run was reported as a possible wedge: $(cat "$out")"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "a $step validation run counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"
    [ "$(cat "$state/.validating-since-$key" 2>/dev/null || true)" = 01RUNLIVE ] \
      || fail "the $step deferral chain was not bound to its run"
  done

  # The configured deferral does not restore ordinary-worker idle check-ins.
  verdict='state: working · source: run-step · validating (running) · run: 01RUNLIVE'
  dir=$(wedge_threshold_fixture validating-aged 'working: handed to validation' 0 5)
  arm_validating "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf '01RUNLIVE' > "$state/.validating-since-$key"
  set_mtime "$(( $(date +%s) - 2000 ))" "$state/.validating-since-$key"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
    || fail "an aged validating worker emitted an idle check-in: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "an aged validating worker queued a stale wake"

  # A replacement run starts its own chain, so an old run's age cannot make the
  # new one re-surface at once.
  dir=$(wedge_threshold_fixture validating-new-run 'working: handed to validation' 0 5)
  arm_validating "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf '01RUNOLD' > "$state/.validating-since-$key"
  set_mtime "$(( $(date +%s) - 2000 ))" "$state/.validating-since-$key"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
    || fail "a replacement run inherited the previous run's recheck age: $(cat "$out")"
  [ "$(cat "$state/.validating-since-$key")" = 01RUNLIVE ] \
    || fail "a replacement run did not rebind the deferral chain"
  pass "a running or fixing validation run is deferred on the long recheck cadence rather than wedge-escalated"
}

# Every run state that does not prove a round is executing keeps the unchanged
# ladder even where the flag is armed: a parked gate, a terminal run, a ci
# monitor, a coarse ledger row, a verdict naming no run, no run at all, and an
# unreadable verdict.
test_wedge_threshold_escalates_when_no_run_is_executing() {
  local dir state fakebin out capture window key n spec name verdict
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for spec in \
    'parked|state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · run: 01RUNLIVE' \
    'failed|state: failed · source: run-step · run failed · run: 01RUNLIVE' \
    'done|state: done · source: run-step · checks green: PR ready for review · run: 01RUNLIVE' \
    'ci|state: working · source: run-step · ci running · run: 01RUNLIVE' \
    'coarse|state: working · source: run-step · validating (background run)' \
    'runless|state: working · source: run-step · validating (running)' \
    'absent|state: working · source: pane · busy' \
    'unreadable|error: no-mistakes status timed out'; do
    name=${spec%%|*}; verdict=${spec#*|}
    dir=$(wedge_threshold_fixture "not-executing-$name" 'working: handed to validation' 0 5)
    arm_validating "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    case "$name" in failed|done)
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
        || fail "a completed run emitted a wedge alarm"
      [ ! -e "$state/.wedge-escalations-$key" ] || fail "completed run retained an escalation count"
      continue ;;
    esac
    n=1
    while [ "$n" -le 3 ]; do
      printf '%s\n' "$(( $(date +%s) - 5 ))" > "$state/.stale-since-$key"
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
        || fail "a $name run stopped escalating at threshold $n: $(cat "$out")"
      ack_stopped_cycle "$state" || fail "could not acknowledge $name escalation $n"
      grep -F "possible wedge, escalation $n" "$out" >/dev/null \
        || fail "a $name run did not reach escalation $n: $(cat "$out")"
      n=$((n + 1))
    done
    grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
      || fail "a $name run lost the demand-deep-inspection wording: $(cat "$out")"
    [ ! -e "$state/.validating-since-$key" ] \
      || fail "a $name run started a validating deferral chain"
  done
  pass "unfinished runs keep established wedge protection; completed runs retire it"
}

# Absent config/wedge-defer-validating an executing run is no deferral at all:
# the lane escalates on the unchanged schedule and wording, and the consult is
# never reached, so no current-state read is spent and no chain is started.
test_wedge_threshold_validating_run_is_off_until_armed() {
  local dir state fakebin out capture window key n probes
  local verdict='state: working · source: run-step · validating (running) · run: 01RUNLIVE'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture validating-unarmed 'working: handed to validation' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  [ ! -e "$dir/config/wedge-defer-validating" ] \
    || fail "the unarmed fixture armed the flag, so it proves nothing"
  export FM_FAKE_CREW_STATE_LOG="$dir/crew-state.calls"
  : > "$FM_FAKE_CREW_STATE_LOG"
  n=1
  while [ "$n" -le 3 ]; do
    printf '%s\n' "$(( $(date +%s) - 5 ))" > "$state/.stale-since-$key"
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
      || fail "an unarmed home stopped escalating a running validation at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge unarmed validating escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "an unarmed home did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  probes=$(wc -l < "$FM_FAKE_CREW_STATE_LOG" | tr -d ' ')
  unset FM_FAKE_CREW_STATE_LOG
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "an unarmed home lost the demand-deep-inspection wording: $(cat "$out")"
  [ "$probes" -gt 0 ] && [ "$probes" -le 6 ] \
    || fail "an unarmed home lost the bounded house state rechecks ($probes reads)"
  [ ! -e "$state/.validating-since-$key" ] \
    || fail "an unarmed home started a validating deferral chain"
  pass "with config/wedge-defer-validating absent a running validation keeps the house ladder, wording and bounded state rechecks"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_wedge_threshold_defers_to_a_worker_blocker \
  test_wedge_threshold_worker_wait_is_off_until_armed \
  test_wedge_defer_refuses_a_half_filled_wait_record \
  test_wedge_threshold_defers_to_an_executing_validation_run \
  test_wedge_threshold_escalates_when_no_run_is_executing \
  test_wedge_threshold_validating_run_is_off_until_armed

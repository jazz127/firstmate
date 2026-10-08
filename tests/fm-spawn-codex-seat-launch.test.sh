#!/usr/bin/env bash
# tests/fm-spawn-codex-seat-launch.test.sh - a seated Codex worker must start
# on its seat's credential home, never on the ambient Codex account.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# through a dock seat against a fake pane and a real isolated git worktree, then
# EXECUTE the launch command the pane received under a synthetic pane
# environment that carries ambient Codex and OpenAI credentials. The codex
# binary is a probe that prints the environment it was started with, so what it
# prints is what a real seated agent would have received. The launch also
# carries the AI-trailer hooks export ahead of the agent, which is the compound
# shape a command-prefix assignment silently fails to reach through.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-seat-launch)

# Every ambient override a seated launch must shed (bin/fm-worker-account-lib.sh).
AMBIENT_CREDENTIALS=(OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN OPENAI_BASE_URL OPENAI_ORG_ID OPENAI_ORGANIZATION OPENAI_PROJECT OPENAI_PROJECT_ID)

test_seated_codex_agent_sees_seat_home_and_no_ambient_credentials() {
  local setting id case_dir home proj wt fakebin launchlog panelog seat_home out status launch preamble seen var
  local -a ambient
  for setting in absent enabled; do
    id="codex-seat-$setting-s1"
    case_dir="$TMP_ROOT/$setting"
    home="$case_dir/home"
    proj="$case_dir/project"
    wt="$case_dir/wt"
    launchlog="$case_dir/launch.log"
    panelog="$case_dir/pane.log"
    fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
    fm_test_spawn_home "$home" codex
    fm_git_worktree "$proj" "$wt" "wt-$setting"
    fm_test_spawn_brief "$home" "$id"
    seat_home="$case_dir/seat home"
    mkdir -p "$seat_home"
    printf '%s\n' '{"OPENAI_API_KEY":"sk-fm-synthetic"}' > "$seat_home/auth.json"
    jq -n --arg home "$seat_home" '{version:1,id:"seat-launch-dock",seats:{luna:{harness:"codex",credential_home:$home}}}' \
      > "$home/config/dock.json"
    # The enabled posture grants every ambient name through the cleared
    # environment, so only the launch's own shed and home can keep them out.
    if [ "$setting" = enabled ]; then
      printf '%s\n' CODEX_HOME "${AMBIENT_CREDENTIALS[@]}" > "$home/config/launch-env-allowlist"
    fi
    cat > "$fakebin/codex" <<'SH'
#!/bin/sh
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  echo 'Logged in using ChatGPT' >&2
  exit 0
fi
printf 'CODEX_HOME=%s\n' "${CODEX_HOME-unset}"
printf 'hooks=%s\n' "${GIT_CONFIG_VALUE_0-unset}"
for var in OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN OPENAI_BASE_URL OPENAI_ORG_ID OPENAI_ORGANIZATION OPENAI_PROJECT OPENAI_PROJECT_ID; do
  eval "printf '%s=%s\n' \"\$var\" \"\${$var-unset}\""
done
SH
    chmod +x "$fakebin/codex"

    : > "$launchlog"
    : > "$panelog"
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness codex --seat luna \
      --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "seated Codex spawn with allowlist=$setting should succeed: $out"
    launch=$(cat "$launchlog")
    [ -n "$launch" ] || fail "seated Codex spawn with allowlist=$setting sent no launch command"

    ambient=(CODEX_HOME=/ambient/default-account)
    for var in "${AMBIENT_CREDENTIALS[@]}"; do
      ambient+=("$var=ambient-$var")
    done
    preamble=$(grep '^export ' "$panelog")
    seen=$(env -i HOME="$case_dir/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
      "${ambient[@]}" /bin/sh -c "$preamble
$launch") \
      || fail "seated Codex launch with allowlist=$setting failed to run"

    assert_contains "$seen" "CODEX_HOME=$seat_home" \
      "allowlist=$setting: the seated agent did not start on its seat's credential home"
    for var in "${AMBIENT_CREDENTIALS[@]}"; do
      assert_contains "$seen" "$var=unset" \
        "allowlist=$setting: the seated agent retained ambient $var"
    done
    assert_contains "$seen" "hooks=$(CDPATH='' cd -- "$home/state" && pwd -P)/$id.git-hooks" \
      "allowlist=$setting: the agent should run under the AI-trailer hooks export this case depends on"
  done
  pass "a seated Codex agent starts on its seat home with every ambient credential shed, behind the AI-trailer export"
}

test_seated_codex_agent_sees_seat_home_and_no_ambient_credentials

echo "# all fm-spawn-codex-seat-launch tests passed"

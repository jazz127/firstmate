#!/usr/bin/env bash
# Behavior tests for the spawn-owned AI commit-trailer strip.
#
# Cursor injects Co-Authored-By after the typed message, so these cases assert
# the commit OBJECT, never the string passed to -m. The strip is the public
# interface; tests drive git commit through the installed hooksPath the same
# way a fleet-launched pane does.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
unset CODEX_THREAD_ID OPENCODE_SESSION_ID

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-strip-ai-trailers)

fm_git_identity 'Captain Tests' 'captain@example.invalid'

with_hooks_env() {  # <hooks-dir> <command...>
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks "$@"
}

make_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
}

test_scoped_keep_and_add() {
  local runtime repo hooks meta body session model native expected platform
  for runtime in codex claude pi pi-signed omp opencode grok kimi cursor agy muse gemini rovo devin commandcode polytoken cortex; do
    repo="$TMP_ROOT/scoped-$runtime" hooks="$TMP_ROOT/scoped-hooks-$runtime"
    meta="$TMP_ROOT/$runtime.meta"
    make_repo "$repo"
    git -C "$repo" remote add origin git@github.com:t27sol/sample.git
    model=fixture-model
    "$STRIP" install --attribution "$meta" "$runtime" "$model" "$hooks" "$repo" || fail 'scoped install failed'
    session=11111111-2222-3333-4444-555555555555
    native=$(printf 'Co-authored-by: Jane Doe <jane@example.com>\nSigned-off-by: Jane Doe <jane@example.com>\nClaude-Session: %s' "$session")
    CODEX_THREAD_ID=$session with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty \
      -m 'fix: scoped attribution' -m "$native" || fail 'attributed commit failed'
    body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    platform=$runtime/$model
    [ "$runtime" != claude ] || platform=claude
    expected=$(printf '%s\nCo-authored-by: %s <noreply@firstmate.invalid>\nAgent-System: fac:firstmate\nAgent-Platform: %s' "$native" "$runtime" "$platform")
    [ "$body" = "$expected" ] || fail "$runtime lost or reordered parsed trailers: $body"
    CODEX_THREAD_ID=$session with_hooks_env "$hooks" git -C "$repo" commit -q --amend --no-edit --allow-empty || fail 'repeat stamping failed'
    body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    [ "$body" = "$expected" ] || fail "$runtime repeat stamping changed parsed trailers: $body"
    if [ "$runtime" = codex ]; then
      CODEX_THREAD_ID=$session with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: no native session'
      body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
      assert_contains "$body" "Agent-Session: $session" 'Codex UUID missing without native session'
    fi
    CODEX_THREAD_ID=/private/session with_hooks_env "$hooks" git -C "$repo" commit -q --amend --allow-empty \
      -m 'fix: amended attribution' -m 'Co-authored-by: Claude <noreply@anthropic.com>'
    body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    assert_not_contains "$body" 'Agent-Session:' 'unsafe or stale session published'
    assert_contains "$body" 'Co-authored-by: Claude <noreply@anthropic.com>' 'native coauthor lost'
    git -C "$repo" remote set-url origin https://github.com/t27sol-other/sample.git
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty \
      -m 'fix: outside scope' --trailer "Co-authored-by: $runtime <noreply@firstmate.invalid>" \
      --trailer 'Co-authored-by: Claude <noreply@anthropic.com>' \
      --trailer "Claude-Session: $session"
    body=$(git -C "$repo" log -1 --format=%B)
    assert_not_contains "$body" 'Claude-Session:' 'outside scope kept native session'
    assert_not_contains "$body" 'Co-authored-by:' 'outside scope kept AI trailer'
    assert_not_contains "$body" 'Agent-System:' 'outside scope gained attribution'
  done
  pass 'Git parses preserved native trailers and idempotent attribution across all runtimes'
}

test_scope_matching() {
  local config repo mode url model hooks trailers expected
  config="$TMP_ROOT/legacy-flag" repo="$TMP_ROOT/scope-repo"
  make_repo "$repo"
  git -C "$repo" remote add origin https://github.com/t27sol/repo.git
  hooks="$TMP_ROOT/scope-matching-hooks"
  "$STRIP" install --attribution "$TMP_ROOT/absent.meta" codex default "$hooks" "$repo" || fail 'owner-matching hook install failed'
  expected=$(printf '%s\n' 'Co-authored-by: Jane Doe <jane@example.com>' \
    'Co-authored-by: codex <noreply@firstmate.invalid>' 'Agent-System: fac:firstmate' 'Agent-Platform: codex')
  for url in https://github.com/t27sol/repo https://github.com/t27sol/repo/ \
    https://github.com/t27sol/repo.git https://github.com/t27sol/repo.git/ \
    ssh://git@github.com/t27sol/repo ssh://git@github.com/t27sol/repo/ \
    ssh://git@github.com/t27sol/repo.git ssh://git@github.com/t27sol/repo.git/ \
    git@github.com:t27sol/repo git@github.com:t27sol/repo/ \
    git@github.com:t27sol/repo.git git@github.com:t27sol/repo.git/ \
    https://github.com/T27SOL/Another.GIT https://github.com/T27SOL/Another.GIT///; do
    git -C "$repo" remote set-url origin "$url"
    mode=$(python3 "$ROOT/bin/fm-git-attribution.py" mode "$config" "$repo") || fail 'owner resolution failed'
    [ "$mode" = add ] || fail "t27sol owner did not match without configuration: $url"
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: equivalent origin' \
      --trailer 'Co-authored-by: Jane Doe <jane@example.com>' || fail "commit failed for origin: $url"
    trailers=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    [ "$trailers" = "$expected" ] || fail "equivalent origin changed committed attribution: $url"
  done
  for url in https://github.com/t27sol-other/repo.git https://github.com/t27sol-other/repo.git/ \
    ssh://git@github.com/t27sol-other/repo.git/ git@github.com:t27sol-other/repo.git/ \
    https://gitlab.com/t27sol/repo.git https://gitlab.com/t27sol/repo.git/ \
    https://github.com/other/t27sol.git "$repo"; do
    git -C "$repo" remote set-url origin "$url"
    [ "$(python3 "$ROOT/bin/fm-git-attribution.py" mode "$config" "$repo")" = strip ] || fail 'unrelated repository matched'
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: unrelated origin' \
      --trailer 'Co-authored-by: Claude <noreply@anthropic.com>' \
      --trailer 'Co-authored-by: Jane Doe <jane@example.com>' || fail 'unrelated origin commit failed'
    trailers=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    [ "$trailers" = 'Co-authored-by: Jane Doe <jane@example.com>' ] || fail "unrelated origin kept attribution: $url"
  done
  : >"$config"
  [ "$(python3 "$ROOT/bin/fm-git-attribution.py" mode "$config" "$repo")" = keep ] || fail 'legacy flag changed'
  printf '%s\n' 'gitlab.com/arbitrary/selection' >"$config"
  [ "$(python3 "$ROOT/bin/fm-git-attribution.py" mode "$config" "$repo")" = keep ] || fail 'legacy flag contents became a scope list'
  git -C "$repo" remote set-url origin git@github.com:t27sol/repo.git
  [ "$(python3 "$ROOT/bin/fm-git-attribution.py" mode "$config" "$repo")" = add ] || fail 'legacy flag bypassed t27sol attribution'
  for model in default auto; do
    "$STRIP" install --attribution "$TMP_ROOT/absent.meta" codex "$model" "$TMP_ROOT/default-model-hooks" "$repo" || fail 'default-model install failed'
    with_hooks_env "$TMP_ROOT/default-model-hooks" git -C "$repo" commit -q --allow-empty -m 'fix: unresolved model'
    mode=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    assert_contains "$mode" 'Agent-Platform: codex' 'runtime missing without model'
    assert_not_contains "$mode" 'Agent-Platform: codex/' 'unreported model emitted'
  done
  pass 't27sol policy needs no configuration and preserves the legacy presence flag elsewhere'
}

test_model_validation_follows_platform_emission() {
  local repo hooks runtime model native expected trailers before
  repo="$TMP_ROOT/model-emission" hooks="$TMP_ROOT/model-emission-hooks"
  make_repo "$repo"
  git -C "$repo" remote add origin https://github.com/t27sol/sample.git
  native=$(printf '%s\n' 'Co-authored-by: Claude <noreply@anthropic.com>' \
    'Claude-Session: https://claude.ai/code/session_test123')
  expected=$(printf '%s\nAgent-System: fac:firstmate\nAgent-Platform: claude' "$native")
  for model in 'sonnet[1m]' 'opus[1m]' 'claude-sonnet-4-5@20250929' \
    'claude-sonnet-4-5@20250929[1m]' sonnet default auto; do
    "$STRIP" install --attribution "$TMP_ROOT/absent.meta" claude "$model" "$hooks" "$repo" || fail 'Claude model hook install failed'
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: Claude model omission' -m "$native" \
      || fail "omitted Claude model blocked commit: $model"
    trailers=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    [ "$trailers" = "$expected" ] || fail "Claude model changed trailer semantics: $model"
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty --amend --no-edit \
      || fail "omitted Claude model blocked amendment: $model"
    trailers=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    [ "$trailers" = "$expected" ] || fail 'Claude amendment changed trailer semantics'
  done
  for model in fixture-model default auto; do
    "$STRIP" install --attribution "$TMP_ROOT/absent.meta" codex "$model" "$hooks" "$repo" || fail 'Codex model hook install failed'
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: platform model' || fail 'Codex model blocked commit'
    trailers=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    expected=$(printf '%s\n' 'Co-authored-by: codex <noreply@firstmate.invalid>' 'Agent-System: fac:firstmate')
    if [ "$model" = fixture-model ]; then
      expected="$expected"$'\n''Agent-Platform: codex/fixture-model'
    else
      expected="$expected"$'\n''Agent-Platform: codex'
    fi
    [ "$trailers" = "$expected" ] || fail 'known or unresolved model emission changed'
  done
  for model in 'unsafe model' 'https://provider.invalid/model' $'model\nAgent-System: injected'; do
    "$STRIP" install --attribution "$TMP_ROOT/absent.meta" codex "$model" "$hooks" "$repo" || fail 'unsafe-model hook install failed'
    before=$(git -C "$repo" rev-parse HEAD)
    if with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: refused model' >"$repo/refusal" 2>&1; then
      fail 'unsafe emitted model was accepted'
    fi
    [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail 'unsafe model created a commit'
  done
  for runtime in 'claude invalid' $'claude\nAgent-System: injected'; do
    "$STRIP" install --attribution "$TMP_ROOT/absent.meta" "$runtime" 'sonnet[1m]' "$hooks" "$repo" || fail 'unsafe-runtime hook install failed'
    before=$(git -C "$repo" rev-parse HEAD)
    if with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: refused runtime' >"$repo/refusal" 2>&1; then
      fail 'Claude model omission bypassed runtime validation'
    fi
    [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail 'unsafe runtime created a commit'
  done
  pass 'hook commits omit supported Claude model spellings while validating emitted models and runtimes'
}

test_model_selectors_reach_commit_attribution() {
  local repo hooks runtime model trailers expected native before
  repo="$TMP_ROOT/model-selectors" hooks="$TMP_ROOT/model-selector-hooks"
  make_repo "$repo"
  git -C "$repo" remote add origin https://github.com/t27sol/sample.git
  native='Co-authored-by: Jane Doe <jane@example.com>'
  while IFS='|' read -r runtime model; do
    "$STRIP" install --attribution "$TMP_ROOT/absent.meta" "$runtime" "$model" "$hooks" "$repo" || fail 'selector hook install failed'
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: model selector attribution' -m "$native" \
      || fail "safe launch selector blocked commit: $runtime $model"
    expected=$(printf '%s\nCo-authored-by: %s <noreply@firstmate.invalid>\nAgent-System: fac:firstmate\nAgent-Platform: %s/%s' "$native" "$runtime" "$runtime" "$model")
    trailers=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    [ "$trailers" = "$expected" ] || fail "selector changed committed trailer semantics: $runtime $model"
    with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty --amend --no-edit || fail 'selector amendment failed'
    trailers=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    [ "$trailers" = "$expected" ] || fail 'selector amendment changed trailer semantics'
  done <<'CASES'
opencode|openai/gpt-6.1-sol#high
opencode|fixture/native#proof
opencode|vertex/claude-sonnet-4-5@20250929[1m]#high
codex|gpt-6.1-sol
pi|codex-native/gpt-6.1-sol
pi-signed|codex-native/gpt-6.1-sol
omp|claude-bridge/claude-opus-4-7
omp|*sonnet*
grok|grok-4
kimi|kimi-code/k3-256k
cursor|cursor-grok-4.5-high-fast
agy|gemini-3.8-flash-high
muse|muse-spark-1.2-contributor
gemini|gemini-2.5-pro
rovo|gpt-5.6-sol
devin|swe-2-medium
commandcode|deepseek/deepseek-v4.1-flash
polytoken|zai/glm-5.3-flash
cortex|claude-sonnet-5-5
CASES
  for runtime in opencode codex; do
    for model in '' 'unsafe model' $'model\nAgent-System: injected' $'model\rAgent-System: injected' \
      $'model\tvariant' $'model\001variant' $'model\033variant' $'model\177variant' \
      "model$(printf '\302\205')variant" "model$(printf '\342\200\250')variant" \
      '/private/secret' './secret' '../secret' '~/secret' 'provider/../../secret' \
      'C:/Users/private/secret' 'C:\Users\private\secret' \
      'https://private.invalid/model' 'file:///private/secret'; do
      "$STRIP" install --attribution "$TMP_ROOT/absent.meta" "$runtime" "$model" "$hooks" "$repo" || fail 'unsafe-selector hook install failed'
      before=$(git -C "$repo" rev-parse HEAD)
      if with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: refused selector' >"$repo/refusal" 2>&1; then
        fail 'unsafe or private selector was published'
      fi
      assert_contains "$(cat "$repo/refusal")" 'unsafe model' 'selector was refused for an unrelated reason'
      [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail 'unsafe selector created a commit'
    done
  done
  pass 'runtime model references survive hook commits while controls, paths and URLs are refused'
}

test_recorded_sessions() {
  local runtime repo hooks meta sid body native
  for runtime in opencode polytoken; do
    repo="$TMP_ROOT/session-$runtime" hooks="$TMP_ROOT/session-hooks-$runtime" meta="$TMP_ROOT/session-$runtime.meta"
    make_repo "$repo"
    git -C "$repo" remote add origin https://github.com/t27sol/sample.git
    "$STRIP" install --attribution "$meta" "$runtime" default "$hooks" "$repo" || fail 'session hook install failed'
    if [ "$runtime" = opencode ]; then sid=ses_abc123; else sid=0czfake-echo; fi
    printf 'polytoken_session=%s\npolytoken_credential=/private/credential\n' "$sid" >"$meta"
    OPENCODE_SESSION_ID=$sid with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: recorded session' || fail 'session commit failed'
    body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    assert_contains "$body" "Agent-Session: $sid" "$runtime recorded session missing"
    assert_not_contains "$body" credential 'credential leaked'
    native="$runtime-session: $sid"
    OPENCODE_SESSION_ID=$sid with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: native session' --trailer "$native" || fail 'native session commit failed'
    body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    assert_contains "$body" "$native" 'native recorded session lost'
    assert_not_contains "$body" 'Agent-Session:' 'native recorded session duplicated'
    printf 'polytoken_session=/private/secret\n' >"$meta"
    OPENCODE_SESSION_ID=/private/secret with_hooks_env "$hooks" git -C "$repo" commit -q --amend --allow-empty -m 'fix: unsafe session' || fail 'unsafe session commit failed'
    body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    assert_not_contains "$body" 'Agent-Session:' 'unsafe session published'
    rm "$meta"
    OPENCODE_SESSION_ID= with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -m 'fix: absent session' || fail 'absent session commit failed'
    body=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
    assert_not_contains "$body" 'Agent-Session:' 'absent session guessed'
  done
  pass 'OpenCode context and existing Polytoken metadata supply safe session references'
}

test_git_trailer_removal_preserves_message_body() {
  local mode shape repo hooks msg prose native body parsed expected sid human
  sid=11111111-2222-3333-4444-555555555555
  prose=$(printf '%s\n' 'fix: document attribution' '' \
    'Agent-System: fac:example' 'Agent-Platform: codex/example' \
    'Agent-Session: example-session' 'Claude-Session: example-native-session' \
    'These are body examples followed by explanatory prose.')
  human=$(printf '%s\n' 'Signed-off-by: Jane Doe <jane@example.com>' \
    'Co-authored-by: Jane Doe <jane@example.com>' 'Reviewed-by: Review Team' 'Empty-Key: ')
  native=$(printf '%s\n' 'Signed-off-by: Jane Doe <jane@example.com>' \
    'Co-authored-by: Jane Doe <jane@example.com>' \
    'Co-authored-by: Claude <noreply@anthropic.com>' \
    'Reviewed-by: Review' ' Team' 'Empty-Key:' \
    'aGeNt-System : stale-system' ' stale-system-continuation' \
    'Agent-Platform: stale-platform' ' stale-platform-continuation' \
    'Agent-Session: stale-session' ' stale-session-continuation' "Claude-Session: $sid")
  for mode in add strip fallback direct keep; do
    for shape in trailered body-only; do
      repo="$TMP_ROOT/body-$mode-$shape" hooks="$TMP_ROOT/body-hooks-$mode-$shape"
      make_repo "$repo"
      git -C "$repo" remote add origin https://github.com/t27sol/sample.git
      case "$mode" in
        add | fallback) "$STRIP" install --attribution "$TMP_ROOT/body.meta" codex fixture-model "$hooks" "$repo" || fail 'body attribution install failed' ;;
        strip) "$STRIP" install "$hooks" "$repo" || fail 'body strip install failed' ;;
        keep) "$STRIP" install --no-strip "$hooks" "$repo" || fail 'body keep install failed' ;;
      esac
      [ "$mode" = add ] || git -C "$repo" remote set-url origin https://github.com/another-owner/sample.git
      msg="$repo/message"
      printf '%s\n' "$prose" >"$msg"
      [ "$shape" != trailered ] || printf '\n%s\n' "$native" >>"$msg"
      if [ "$mode" = direct ]; then
        "$STRIP" "$msg" || fail 'direct body strip failed'
        git -C "$repo" commit -q --allow-empty -F "$msg" || fail 'direct body commit failed'
      else
        CODEX_THREAD_ID=$sid with_hooks_env "$hooks" git -C "$repo" commit -q --allow-empty -F "$msg" || fail "$mode body commit failed"
      fi
      body=$(git -C "$repo" log -1 --format=%B)
      assert_contains "$body" "$prose" "$mode $shape changed body examples"
      parsed=$(git -C "$repo" log -1 --format=%B | git -C "$repo" interpret-trailers --parse)
      if [ "$mode" = keep ]; then
        if [ "$shape" = trailered ]; then
          assert_contains "$parsed" "Claude-Session: $sid" 'keep removed native session'
          assert_contains "$parsed" 'Agent-Session: stale-session stale-session-continuation' 'keep removed shared fields'
        else
          [ -z "$parsed" ] || fail 'body-only examples became trailers'
        fi
        continue
      fi
      expected=
      if [ "$shape" = trailered ]; then
        expected=$human
        if [ "$mode" = add ]; then
          expected=$(printf '%s\n' 'Signed-off-by: Jane Doe <jane@example.com>' \
            'Co-authored-by: Jane Doe <jane@example.com>' \
            'Co-authored-by: Claude <noreply@anthropic.com>' \
            'Reviewed-by: Review Team' 'Empty-Key: ' "Claude-Session: $sid")
        fi
      fi
      if [ "$mode" = add ]; then
        [ -z "$expected" ] || expected="$expected"$'\n'
        expected="$expected"$(printf '%s\n' 'Co-authored-by: codex <noreply@firstmate.invalid>' \
          'Agent-System: fac:firstmate' 'Agent-Platform: codex/fixture-model')
        [ "$shape" != body-only ] || expected="$expected"$'\n'"Agent-Session: $sid"
      fi
      [ "$parsed" = "$expected" ] || fail "$mode $shape changed parsed trailer meaning or order: $parsed"
      CODEX_THREAD_ID=$sid with_hooks_env "$hooks" git -C "$repo" commit -q --amend --allow-empty --no-edit || fail "$mode amendment failed"
      body=$(git -C "$repo" log -1 --format=%B)
      assert_contains "$body" "$prose" "$mode amendment changed body examples"
    done
  done
  pass 'Git trailer removal preserves body examples, folded native fields, empty fields and native order'
}

test_strip_fields_preserves_patch_content() {
  local msg patch expected
  msg="$TMP_ROOT/patch-message"
  patch=$(printf '%s\n' '---' 'Agent-System: patch-system' 'Agent-Platform: patch-platform' \
    'Agent-Session: patch-session' 'Claude-Session: patch-session')
  printf 'fix: patch message\n\nSigned-off-by: Jane Doe <jane@example.com>\nAgent-System: stale-system\nAgent-Platform: stale-platform\nAgent-Session: stale-session\nClaude-Session: stale-session\n\n%s\n' "$patch" >"$msg"
  "$STRIP" "$msg" || fail 'patch message strip failed'
  expected=$(printf 'fix: patch message\n\nSigned-off-by: Jane Doe <jane@example.com>\n\n%s' "$patch")
  [ "$(cat "$msg")" = "$expected" ] || fail 'strip changed patch content or retained real attribution'
  pass 'stripping respects Git trailer boundaries before a patch divider'
}

test_cursor_trailer_does_not_reach_the_commit_object() {
  local repo hooks body author
  repo="$TMP_ROOT/cursor-object"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-cursor"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed on a real git repo"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: keep the typed message clean'
  body=$(git -C "$repo" log -1 --format=%B)
  author=$(git -C "$repo" log -1 --format='%an <%ae>')
  assert_not_contains "$body" "Co-authored-by: Cursor" "Cursor trailer reached the commit object"
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor email reached the commit object"
  assert_contains "$body" "fix: keep the typed message clean" "subject was rewritten"
  [ "$author" = "Captain Tests <captain@example.invalid>" ] || fail "author was rewritten: $author"
  pass "a Cursor --trailer commit object has no AI co-author and keeps the captain identity"
}


test_human_coauthor_is_kept() {
  local repo hooks body
  repo="$TMP_ROOT/human-coauthor"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-human"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' --trailer 'Co-authored-by: Jane Doe <jane@example.com>' -m 'fix: mixed trailers'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "Cursor" "Cursor trailer was not stripped from a mixed message"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@example.com>" "human co-author was stripped"
  pass "a human Co-authored-by trailer survives next to a stripped Cursor trailer"
}

test_human_at_a_vendor_domain_is_kept() {
  local repo hooks body
  repo="$TMP_ROOT/vendor-human"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-vendor-human"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q \
    --trailer 'Co-authored-by: Claude <noreply@anthropic.com>' \
    --trailer 'Co-authored-by: Jane Doe <jane@anthropic.com>' \
    --trailer 'Co-authored-by: Sam Roe <sam@cursor.com>' -m 'fix: vendor staff co-authors'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "noreply@anthropic.com" "the Claude bot trailer reached the commit object"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@anthropic.com>" "a human at a vendor domain was stripped"
  assert_contains "$body" "Co-authored-by: Sam Roe <sam@cursor.com>" "a human at a vendor domain was stripped"
  pass "a human co-author at a vendor domain survives; only the exact bot address is stripped"
}

test_hook_manager_cannot_displace_the_strip() {
  local repo hooks target body
  if [ "$(id -u)" = 0 ]; then
    pass "a hook manager cannot displace the strip (skipped as root)"
    return 0
  fi
  repo="$TMP_ROOT/hook-manager"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-manager"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  target=$(with_hooks_env "$hooks" git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  [ "$target" = "$hooks" ] || fail "a hook manager in the pane would resolve $target, not the strip dir $hooks"
  mv "$target/commit-msg" "$target/commit-msg.old" 2>/dev/null &&
    fail "a hook manager could rename the strip's commit-msg aside"
  (printf '#!/bin/sh\nexit 0\n' >"$target/commit-msg") 2>/dev/null &&
    fail "a hook manager could overwrite the strip's commit-msg"
  (printf '#!/bin/sh\nexit 0\n' >"$target/post-update") 2>/dev/null &&
    fail "a hook manager could add a hook to the strip dir"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after a manager tried'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor trailer survived a hook manager's install attempt"
  pass "a hook manager resolving the pane hooks dir fails instead of displacing the strip"
}

test_reinstall_replaces_a_read_only_install() {
  local repo hooks body
  repo="$TMP_ROOT/reinstall"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-reinstall"
  "$STRIP" install "$hooks" "$repo" || fail "first install should succeed"
  "$STRIP" install "$hooks" "$repo" || fail "a relaunch reinstall over the read-only install failed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after reinstall'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor trailer survived after a reinstall"
  pass "a relaunch reinstall replaces the read-only strip dir and still strips"
}

test_previous_commit_msg_hook_still_runs() {
  local repo orig hooks
  repo="$TMP_ROOT/chain-hook"
  make_repo "$repo"
  orig=$(git -C "$repo" rev-parse --git-path hooks)
  case "$orig" in
  /*) ;;
  *) orig="$repo/$orig" ;;
  esac
  mkdir -p "$orig"
  cat >"$orig/commit-msg" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' > "$(dirname "$1")/orig-commit-msg.ran"
exit 0
SH
  chmod 700 "$orig/commit-msg"
  hooks="$TMP_ROOT/hooks-chain"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: chain'
  [ -f "$repo/.git/orig-commit-msg.ran" ] || fail "the worktree's previous commit-msg hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived even though the previous hook ran"
  pass "install chains the previous commit-msg hook after stripping"
}

write_marker_hook() {  # <path> <marker>
  cat >"$1" <<SH
#!/usr/bin/env bash
printf 'ran\n' > "\$PWD/$2.ran"
exit 0
SH
  chmod 700 "$1"
}

test_relative_project_hookspath_still_runs() {
  local repo hooks
  repo="$TMP_ROOT/husky-relative"
  make_repo "$repo"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" husky-pre-commit
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/hooks-husky"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with a relative core.hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: husky relative'
  [ -f "$repo/husky-pre-commit.ran" ] || fail "the project's relative-hooksPath pre-commit hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a relative-hooksPath install"
  pass "a relative project core.hooksPath resolves against the worktree and still runs"
}

test_inherited_hookspath_env_does_not_decide_the_chain() {
  local repo hooks parent
  repo="$TMP_ROOT/nested-spawn"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" project-pre-commit
  parent="$TMP_ROOT/parent-hooks"
  mkdir -p "$parent"
  write_marker_hook "$parent/pre-commit" parent-pre-commit
  hooks="$TMP_ROOT/hooks-nested"
  with_hooks_env "$parent" "$STRIP" install "$hooks" "$repo" ||
    fail "install should succeed with an inherited GIT_CONFIG hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: nested spawn'
  [ -f "$repo/project-pre-commit.ran" ] || fail "the project's own pre-commit hook was not chained"
  [ -f "$repo/parent-pre-commit.ran" ] && fail "a parent spawn's hooks were chained into this worktree"
  pass "an inherited GIT_CONFIG hooksPath does not become the chained previous hooks"
}

test_project_hook_generated_after_install_still_runs() {
  local repo hooks
  repo="$TMP_ROOT/late-husky"
  make_repo "$repo"
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/hooks-late"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed before the project's hooks exist"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" late-pre-commit
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: late husky'
  [ -f "$repo/late-pre-commit.ran" ] || fail "a project hook generated after the spawn did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a late-generated project hooks directory"
  pass "a project hook that appears after install still runs for the rest of the task"
}

test_pane_hookspath_does_not_reroute_another_repository() {
  local repo other hooks
  repo="$TMP_ROOT/task-wt"
  other="$TMP_ROOT/other-repo"
  make_repo "$repo"
  make_repo "$other"
  write_marker_hook "$other/.git/hooks/pre-commit" other-pre-commit
  write_marker_hook "$repo/.git/hooks/pre-commit" task-pre-commit
  hooks="$TMP_ROOT/hooks-pane"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$other/README.md"
  git -C "$other" add README.md
  with_hooks_env "$hooks" git -C "$other" commit -q -m 'fix: other repo'
  [ -f "$other/other-pre-commit.ran" ] || fail "the other repository's own pre-commit hook did not run"
  [ -f "$other/task-pre-commit.ran" ] && fail "the task worktree's pre-commit ran inside another repository"
  [ -f "$repo/task-pre-commit.ran" ] && fail "the task worktree's pre-commit ran while committing elsewhere"
  pass "a pane GIT_CONFIG hooksPath still chains the repository git is actually in"
}

test_empty_project_hookspath_runs_no_repository_hook() {
  local repo hooks err
  repo="$TMP_ROOT/empty-hookspath"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" default-pre-commit
  git -C "$repo" config core.hooksPath ''
  hooks="$TMP_ROOT/hooks-empty"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with an empty core.hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: empty hooksPath' 2>&1) ||
    fail "a commit in a repo with an empty core.hooksPath was refused: $err"
  assert_equals "" "$err" "an empty core.hooksPath commit printed errors"
  [ -f "$repo/default-pre-commit.ran" ] && fail "a repository hook ran although core.hooksPath is empty"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived an empty-hooksPath commit"
  pass "an empty project core.hooksPath runs no repository hook and still strips the trailer"
}

test_unresolvable_project_hookspath_still_refuses() {
  local repo hooks head err
  repo="$TMP_ROOT/unresolvable-hookspath"
  make_repo "$repo"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" config core.hooksPath '~fm-no-such-user-6171/hooks'
  hooks="$TMP_ROOT/hooks-unresolvable"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with an unresolvable core.hooksPath"
  head=$(git -C "$repo" rev-parse HEAD)
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: unresolvable hooksPath' 2>&1) &&
    fail "a commit succeeded although the repository's hooks directory cannot be resolved"
  assert_contains "$err" "refusing to skip its pre-commit hook" "the refusal did not name the skipped hook"
  assert_equals 1 "$(printf '%s\n' "$err" | grep -c 'failed to expand user dir')" "git's lookup error was not shown exactly once"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused commit still moved HEAD"
  pass "an unresolvable project core.hooksPath still refuses the commit"
}

test_valueless_project_hookspath_still_refuses() {
  local repo hooks head err
  repo="$TMP_ROOT/valueless-hookspath"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-valueless"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed before the valueless key is written"
  head=$(git -C "$repo" rev-parse HEAD)
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  printf '[core]\n\thooksPath\n' >>"$repo/.git/config"
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: valueless hooksPath' 2>&1) &&
    fail "a commit succeeded although core.hooksPath has no value"
  assert_contains "$err" "refusing to skip its pre-commit hook" "the refusal did not name the skipped hook"
  assert_equals 1 "$(printf '%s\n' "$err" | grep -c "missing value for 'core.hookspath'")" "git's lookup error was not shown exactly once"
  assert_equals "$head" "$(git -C "$repo" -c core.hooksPath=x rev-parse HEAD)" "a refused commit still moved HEAD"
  pass "a valueless project core.hooksPath still refuses the commit"
}

write_refusing_pre_push() {  # <path> <marker>
  cat >"$1" <<SH
#!/usr/bin/env bash
printf 'ran\n' >> "$2"
exit 1
SH
  chmod 700 "$1"
}

# A publish guard installed as the repository's pre-push must run however the
# pane's hooksPath reaches git: the pane export, git -c (GIT_CONFIG_PARAMETERS),
# or a child process that inherits either one.
test_repository_pre_push_runs_on_every_override_channel() {
  local repo remote hooks marker label child_push
  # shellcheck disable=SC2016 # the child shell expands its own positional args
  child_push='git -C "$1" push -q origin "HEAD:refs/heads/$2"'
  repo="$TMP_ROOT/guarded-push"
  remote="$TMP_ROOT/guarded-remote.git"
  make_repo "$repo"
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  marker="$TMP_ROOT/guarded-push.pre-push"
  write_refusing_pre_push "$repo/.git/hooks/pre-push" "$marker"
  hooks="$TMP_ROOT/hooks-guarded"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  for label in env param env+param child-env child-param; do
    rm -f "$marker"
    case "$label" in
    env) with_hooks_env "$hooks" git -C "$repo" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    param) git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    env+param) with_hooks_env "$hooks" git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    child-env) with_hooks_env "$hooks" sh -c "$child_push" _ "$repo" "$label" 2>/dev/null ;;
    child-param) git -C "$repo" -c core.hooksPath="$hooks" -c "alias.guarded-push=!git push -q origin HEAD:refs/heads/$label" guarded-push 2>/dev/null ;;
    esac && fail "push via $label succeeded past the repository's refusing pre-push hook"
    [ -f "$marker" ] || fail "the repository's pre-push hook did not run via $label"
    git -C "$remote" rev-parse -q --verify "refs/heads/$label" >/dev/null &&
      fail "push via $label reached the remote despite the refusing pre-push hook"
  done
  pass "the repository's pre-push runs and can refuse under every hooksPath override channel"
}

test_git_c_override_still_strips_and_chains_commit_hooks() {
  local repo hooks
  repo="$TMP_ROOT/param-commit"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" param-pre-commit
  hooks="$TMP_ROOT/hooks-param-commit"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c core.hooksPath="$hooks" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: git -c override'
  [ -f "$repo/param-pre-commit.ran" ] || fail "the project's pre-commit hook did not run under git -c core.hooksPath"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a git -c core.hooksPath commit"
  pass "a git -c hooksPath override still strips the trailer and chains the project's hooks"
}

test_repository_hook_keeps_inherited_git_config() {
  local repo hooks layout record helpers
  repo="$TMP_ROOT/inherited-config"
  make_repo "$repo"
  record="$TMP_ROOT/inherited-config.record"
  cat >"$repo/.git/hooks/pre-commit" <<SH
#!/usr/bin/env bash
{ git config --get-all credential.helper; printf 'hooksPath=%s\\n' "\$(git config --get-all core.hooksPath)"; } >"$record"
SH
  chmod 700 "$repo/.git/hooks/pre-commit"
  hooks="$TMP_ROOT/hooks-inherited-config"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  hooks=$(cd "$hooks" && pwd -P)
  for layout in last middle relaunched; do
    rm -f "$record"
    printf '%s\n' "$layout" >>"$repo/README.md"
    git -C "$repo" add README.md
    case "$layout" in
    last)
      GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential' \
        GIT_CONFIG_KEY_2=core.hooksPath GIT_CONFIG_VALUE_2="$hooks" \
        git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m "fix: $layout"
      ;;
    middle)
      GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1="$hooks" \
        GIT_CONFIG_KEY_2=credential.helper GIT_CONFIG_VALUE_2='!gh auth git-credential' \
        git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m "fix: $layout"
      ;;
    relaunched)
      GIT_CONFIG_COUNT=4 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential' \
        GIT_CONFIG_KEY_2=core.hooksPath GIT_CONFIG_VALUE_2="$hooks" \
        GIT_CONFIG_KEY_3=core.hooksPath GIT_CONFIG_VALUE_3="$hooks" \
        git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m "fix: $layout"
      ;;
    esac || fail "commit failed with the hooksPath entry $layout"
    [ -f "$record" ] || fail "the repository's pre-commit hook did not run with the hooksPath entry $layout"
    helpers=$(sed '$d' "$record")
    [ "$(printf '%s\n' "$helpers" | tail -n 2)" = $'\n!gh auth git-credential' ] ||
      fail "the repository hook lost the inherited credential helpers with the hooksPath entry $layout: $helpers"
    [ "$(tail -n 1 "$record")" = "hooksPath=" ] ||
      fail "the repository hook still saw this launch's hooksPath with the entry $layout: $(tail -n 1 "$record")"
    assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
      "Cursor trailer survived with the hooksPath entry $layout"
  done
  pass "the repository's own hook keeps inherited GIT_CONFIG entries such as a scoped credential helper"
}

test_env_file_canonicalizes_hooks_dir() {
  local repo hooks link env_file record
  repo="$TMP_ROOT/env-file-symlink"
  make_repo "$repo"
  record="$TMP_ROOT/env-file-symlink.record"
  cat >"$repo/.git/hooks/pre-commit" <<SH
#!/usr/bin/env bash
git config --get-all credential.helper >"$record"
SH
  chmod 700 "$repo/.git/hooks/pre-commit"
  hooks="$TMP_ROOT/hooks-env-file-symlink"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  link="$TMP_ROOT/hooks-env-file-link"
  ln -s "$hooks" "$link"
  env_file="$TMP_ROOT/env-file-symlink.sh"
  GIT_CONFIG_COUNT=2 "$STRIP" env-file "$link" "$env_file" || fail "env-file should succeed through a symlinked hooks path"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
    GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential' \
    sh -c '. "$1" && exec git -C "$2" commit -q -m "fix: symlinked hooks path"' _ "$env_file" "$repo" ||
    fail "commit failed through the symlinked hooks path"
  [ -f "$record" ] || fail "the repository's pre-commit hook was skipped for a symlinked hooks path"
  [ "$(cat "$record")" = $'\n!gh auth git-credential' ] ||
    fail "the repository hook lost the inherited credential helpers for a symlinked hooks path: $(cat "$record")"
  pass "env-file writes the canonical hooks path so wrappers still chain the repository hook"
}

test_pre_push_guard_runs_before_project_hooks() {
  local repo hooks guard remote
  repo="$TMP_ROOT/pre-push-guard"
  make_repo "$repo"
  remote="$TMP_ROOT/pre-push-guard-remote.git"
  git init -q --bare "$remote"
  git -C "$repo" remote add target "$remote"
  mkdir -p "$repo/.husky"
  git -C "$repo" config core.hooksPath .husky
  write_marker_hook "$repo/.husky/pre-commit" project-pre-commit
  cat >"$repo/.husky/pre-push" <<'SH'
#!/usr/bin/env bash
cat > "$PWD/project-pre-push.stdin"
SH
  chmod 700 "$repo/.husky/pre-push"
  guard="$TMP_ROOT/pre-push-guard.sh"
  cat >"$guard" <<'SH'
#!/usr/bin/env bash
cat > "$1/guard.stdin"
[ ! -f "$1/refuse" ]
SH
  chmod 700 "$guard"
  hooks="$TMP_ROOT/hooks-pre-push-guard"
  "$STRIP" install "$hooks" "$repo" "$guard" "$TMP_ROOT" || fail "guarded install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: guarded'
  [ -f "$repo/project-pre-commit.ran" ] || fail "a guarded install skipped the project's pre-commit hook"
  touch "$TMP_ROOT/refuse"
  with_hooks_env "$hooks" git -C "$repo" push -q target HEAD:refs/heads/main 2>/dev/null \
    && fail "a refusing pre-push guard let the push through"
  [ -f "$repo/project-pre-push.stdin" ] && fail "the project's pre-push ran after the guard refused"
  git --git-dir="$remote" rev-parse --verify -q refs/heads/main >/dev/null && fail "a refused push reached the remote"
  rm -f "$TMP_ROOT/refuse"
  with_hooks_env "$hooks" git -C "$repo" push -q target HEAD:refs/heads/main \
    || fail "a passing pre-push guard blocked the push"
  assert_contains "$(cat "$TMP_ROOT/guard.stdin")" "$(git -C "$repo" rev-parse HEAD)" "the guard did not read the pushed refs"
  [ "$(cat "$repo/project-pre-push.stdin")" = "$(cat "$TMP_ROOT/guard.stdin")" ] \
    || fail "the project's pre-push did not receive the same pushed refs as the guard"
  pass "a pre-push guard runs first and then chains the project's own hooks with the same stdin"
}

test_cortex_attribution_does_not_reach_the_commit_object() {
  local repo hooks body
  repo="$TMP_ROOT/cortex-object"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-cortex"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  # The exact message Cortex Code 1.1.104 produced live: its typed -m body,
  # a Generated with link line, then the Co-authored-by trailer.
  with_hooks_env "$hooks" git -C "$repo" commit -q \
    -m 'probe commit' \
    -m 'Generated with [Snowflake CoCo](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code)' \
    -m 'Co-authored-by: Snowflake CoCo <noreply@snowflake.com>' \
    -m 'Co-authored-by: Jane Doe <jane@snowflake.com>' \
    -m 'Generated with care by a human, no link'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "Snowflake CoCo" "Cortex attribution reached the commit object"
  assert_not_contains "$body" "noreply@snowflake.com" "Cortex bot address reached the commit object"
  assert_contains "$body" "probe commit" "subject was rewritten"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@snowflake.com>" "a human at the vendor domain was stripped"
  assert_contains "$body" "Generated with care by a human, no link" "an unrelated Generated with line was stripped"
  pass "Cortex Code's Generated with line and co-author trailer are stripped; a human at its vendor domain is kept"
}

test_strip_msgfile_alone_does_not_rewrite_author_fields() {
  local msg
  msg="$TMP_ROOT/msg.txt"
  printf '%s\n' 'fix: subject' '' 'Co-authored-by: Cursor <cursoragent@cursor.com>' >"$msg"
  "$STRIP" "$msg" || fail "strip should succeed"
  assert_not_contains "$(cat "$msg")" "Cursor" "strip left the Cursor trailer in the file"
  assert_contains "$(cat "$msg")" "fix: subject" "strip dropped the subject"
  pass "commit-msg file mode strips the trailer and keeps the subject"
}

test_commandcode_trailer_is_stripped() {
  local msg
  msg="$TMP_ROOT/commandcode-msg.txt"
  printf '%s\n' 'Add computed sum to answer.txt' '' 'Co-authored-by: CommandCodeBot <noreply@commandcode.ai>' >"$msg"
  "$STRIP" "$msg" || fail "strip should succeed"
  assert_not_contains "$(cat "$msg")" "CommandCodeBot" "strip left the Command Code trailer in the file"
  assert_contains "$(cat "$msg")" "Add computed sum to answer.txt" "strip dropped the subject"
  pass "the Command Code trailer a worker writes into its own message is stripped"
}

test_no_strip_keeps_the_message_and_still_chains() {
  local repo hooks orig body
  repo="$TMP_ROOT/no-strip"
  make_repo "$repo"
  orig="$repo/.git/hooks"
  mkdir -p "$orig"
  cat >"$orig/commit-msg" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' > "$(dirname "$1")/orig-commit-msg.ran"
SH
  chmod 700 "$orig/commit-msg"
  hooks="$TMP_ROOT/hooks-no-strip"
  "$STRIP" install --no-strip "$hooks" "$repo" || fail "install --no-strip should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: kept trailer'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_contains "$body" "cursoragent@cursor.com" "install --no-strip still stripped the trailer"
  assert_present "$repo/.git/orig-commit-msg.ran" "install --no-strip did not chain the repository's commit-msg hook"
  pass "install --no-strip leaves commit messages untouched while still chaining"
}

test_push_guard_install_runs_the_guard_before_chaining() {
  local repo hooks guard bare out rc
  repo="$TMP_ROOT/push-guard"
  make_repo "$repo"
  bare="$TMP_ROOT/push-guard-origin.git"
  git init -q --bare "$bare"
  git -C "$repo" remote add origin "file://$bare"
  guard="$TMP_ROOT/push-guard-file"
  "$ROOT/bin/fm-git-push-guard.sh" write "$guard" "$repo" fm/t1 fm/ || fail "guard write failed"
  hooks="$TMP_ROOT/hooks-push-guard"
  "$STRIP" install --push-guard "$guard" "$hooks" "$repo" || fail "install --push-guard should succeed"
  [ ! -w "$hooks/pre-push" ] || fail "the guarded pre-push wrapper is writable"
  [ ! -w "$hooks/fm-push-guard" ] || fail "the installed guard record is writable"
  out=$(with_hooks_env "$hooks" git -C "$repo" push origin HEAD:refs/heads/main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the guarded pre-push let a push to origin through"
  assert_contains "$out" "fm-git-push-guard: refused:" "the guarded pre-push did not run the guard"
  "$STRIP" install --push-guard "$TMP_ROOT/no-such-guard" "$TMP_ROOT/hooks-missing-guard" "$repo" 2>/dev/null \
    && fail "install accepted a missing guard file"
  pass "install --push-guard writes a read-only pre-push that runs the guard before chaining"
}

test_git_trailer_removal_preserves_message_body
test_strip_fields_preserves_patch_content
test_scoped_keep_and_add
test_scope_matching
test_model_validation_follows_platform_emission
test_model_selectors_reach_commit_attribution
test_recorded_sessions
test_cursor_trailer_does_not_reach_the_commit_object
test_commandcode_trailer_is_stripped
test_human_coauthor_is_kept
test_human_at_a_vendor_domain_is_kept
test_hook_manager_cannot_displace_the_strip
test_reinstall_replaces_a_read_only_install
test_previous_commit_msg_hook_still_runs
test_relative_project_hookspath_still_runs
test_inherited_hookspath_env_does_not_decide_the_chain
test_project_hook_generated_after_install_still_runs
test_pane_hookspath_does_not_reroute_another_repository
test_empty_project_hookspath_runs_no_repository_hook
test_unresolvable_project_hookspath_still_refuses
test_valueless_project_hookspath_still_refuses
test_repository_pre_push_runs_on_every_override_channel
test_git_c_override_still_strips_and_chains_commit_hooks
test_pre_push_guard_runs_before_project_hooks
test_repository_hook_keeps_inherited_git_config
test_env_file_canonicalizes_hooks_dir
test_cortex_attribution_does_not_reach_the_commit_object
test_strip_msgfile_alone_does_not_rewrite_author_fields
test_no_strip_keeps_the_message_and_still_chains
test_push_guard_install_runs_the_guard_before_chaining

echo "# all fm-git-strip-ai-trailers tests passed"

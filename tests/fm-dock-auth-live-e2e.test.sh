#!/usr/bin/env bash
# Token-free native Codex status guard for a synthetic file-backed seat.
# Re-run after a Codex upgrade; no real credential or model request is used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_DOCK_AUTH_LIVE_E2E codex python3
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dock-auth-live)
VERSION=$(codex --version 2>&1)
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME" "$TMP_ROOT/empty" "$TMP_ROOT/stored"
unset OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN OPENAI_BASE_URL

out=$(env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="$TMP_ROOT/empty" \
  codex login status -c 'cli_auth_credentials_store="file"' -c 'model_provider="openai"' 2>&1)
rc=$?
expect_code 1 "$rc" "$VERSION empty file store must be signed out"
[ "$out" = 'Not logged in' ] || fail "$VERSION changed its signed-out status discriminator"

printf '%s\n' 'sk-fm-synthetic-native-test' | env -i HOME="$HOME" PATH="$PATH" \
  CODEX_HOME="$TMP_ROOT/stored" codex login --with-api-key >/dev/null 2>&1 ||
  fail "$VERSION did not accept a synthetic API key into an isolated home"
out=$(env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="$TMP_ROOT/stored" \
  codex login status -c 'cli_auth_credentials_store="file"' -c 'model_provider="openai"' 2>&1)
rc=$?
expect_code 0 "$rc" "$VERSION stored file must be signed in"
case "$out" in
  'Logged in using an API key - '*) ;;
  *) fail "$VERSION changed its signed-in API-key status discriminator" ;;
esac
fm_worker_account_codex_check "$TMP_ROOT/stored" codex ||
  fail "$VERSION account helper refused the synthetic stored login"
out=$(env -i HOME="$HOME" PATH="$PATH" CODEX_HOME="$TMP_ROOT/stored" \
  codex login status -c 'cli_auth_credentials_store="keyring"' -c 'model_provider="openai"' 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "$VERSION keyring mode unexpectedly accepted the synthetic file-store login"
printf 'cli_auth_credentials_store = "keyring"\n' > "$TMP_ROOT/stored/config.toml"
if fm_worker_account_codex_check "$TMP_ROOT/stored" codex 2>/dev/null; then
  fail "$VERSION account helper accepted an unguarded keyring storage mode"
fi
rm "$TMP_ROOT/stored/config.toml"
if OPENAI_API_KEY=sk-fm-ambient-synthetic fm_worker_account_codex_check "$TMP_ROOT/empty" codex 2>/dev/null; then
  fail "$VERSION account helper accepted an empty store because of an ambient key"
fi
printf 'ok - %s: native status distinguishes synthetic file stores from empty and keyring selections, and the helper rejects ambient credentials\n' "$VERSION"

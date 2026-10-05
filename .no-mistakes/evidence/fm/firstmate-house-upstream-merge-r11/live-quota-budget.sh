#!/bin/bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M455W9R326CJ1BPJVJB6ADKS
TASK_SCRATCH=$(mktemp -d "$PWD/.test-phase/tmp/quota-budget.XXXXXX")
trap 'rm -rf "$TASK_SCRATCH"' EXIT
mkdir -p "$TASK_SCRATCH/bin" "$TASK_SCRATCH/home" "$TASK_SCRATCH/codex" "$TASK_SCRATCH/fm/state"
for tool in bash dirname jq mkdir sleep sed head awk uname stat date perl mktemp rm env node; do
  ln -s "$(command -v "$tool")" "$TASK_SCRATCH/bin/$tool"
done
cat > "$TASK_SCRATCH/bin/quota-axi" <<'LAUNCH'
#!/bin/sh
printf '%s\n' "$*" >> "$QUOTA_LIVE_INVOCATIONS"
exec node /opt/homebrew/opt/quota-axi-house/source/dist/bin/quota-axi.js --profile-only --provider codex --no-credential-refresh "$@"
LAUNCH
chmod +x "$TASK_SCRATCH/bin/quota-axi"
export HOME="$TASK_SCRATCH/home" CODEX_HOME="$TASK_SCRATCH/codex" CLAUDE_CONFIG_DIR="$TASK_SCRATCH/home/claude" XDG_CONFIG_HOME="$TASK_SCRATCH/home/config" XDG_CACHE_HOME="$TASK_SCRATCH/home/cache" FM_HOME="$TASK_SCRATCH/fm" QUOTA_LIVE_INVOCATIONS="$TASK_SCRATCH/invocations"
REAL_BASH=$(command -v bash)
set +e
PATH="$TASK_SCRATCH/bin" quota-axi --json > "$TASK_EVIDENCE/quota-live-isolated-profile.json"
status=$?
set -e
printf 'Isolated quota-axi JSON exit status: %s (missing disposable profile credentials).\n' "$status" > "$TASK_EVIDENCE/quota-live-environment.log"
: > "$QUOTA_LIVE_INVOCATIONS"
PATH="$TASK_SCRATCH/bin" "$REAL_BASH" bin/fm-procevent-quota.sh poll --provider codex --interval 1 --threshold 10 > "$TASK_EVIDENCE/quota-live-failure-budget.log"
cat "$TASK_EVIDENCE/quota-live-failure-budget.log"
/usr/bin/grep -q '3 consecutive read failures' "$TASK_EVIDENCE/quota-live-failure-budget.log"
/usr/bin/grep -q '^condition_polls: 3$' "$TASK_EVIDENCE/quota-live-failure-budget.log"
cp "$QUOTA_LIVE_INVOCATIONS" "$TASK_EVIDENCE/quota-live-invocations.log"
rm "$TASK_SCRATCH/bin/quota-axi"
PATH="$TASK_SCRATCH/bin" "$REAL_BASH" bin/fm-procevent-quota.sh poll --provider codex --interval 1 > "$TASK_EVIDENCE/quota-live-missing.log"
cat "$TASK_EVIDENCE/quota-live-missing.log"
/usr/bin/grep -q 'quota-axi is missing' "$TASK_EVIDENCE/quota-live-missing.log"
/usr/bin/grep -q '^condition_polls: 1$' "$TASK_EVIDENCE/quota-live-missing.log"

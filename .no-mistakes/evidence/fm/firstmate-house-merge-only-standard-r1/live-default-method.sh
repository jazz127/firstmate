#!/usr/bin/env bash
# Loads the real github_urlencode_path_segment and github_choose_default_method
# from bin/fm-pr-merge.sh and runs them against live GitHub (read-only gh calls).
set -u
src=bin/fm-pr-merge.sh
eval "$(sed -n '/^github_urlencode_path_segment() {/,/^}/p' "$src")"
eval "$(sed -n '/^FM_PR_GITHUB_DEFAULT_METHOD=$/,/^}/p' "$src")"
for target in "jazz127 firstmate house" "jazz127 quota-axi house" "jazz127 firstmate main" "kunchenguid firstmate main"; do
  set -- $target
  PR_OWNER=$1 PR_REPO=$2 FM_PR_GITHUB_BASE=$3 URL="https://github.com/$1/$2/pull/0"
  printf '== %s/%s base=%s\n' "$1" "$2" "$3"
  if github_choose_default_method; then
    printf 'chosen default: --%s\n' "$FM_PR_GITHUB_DEFAULT_METHOD"
  else
    printf 'refused (rc=1)\n'
  fi
done

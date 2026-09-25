#!/usr/bin/env bash
# Check a complete draft PR body before publishing or editing it, or read the
# published body back through gh-axi and check that exact text before reporting.
# Usage: fm-pr-body-preflight.sh <body-file> <worker-worktree> <task-temp-dir>
#        fm-pr-body-preflight.sh --gh-url <url> <body-file> <worker-worktree> <task-temp-dir>
# Uses the exact publish-phase evidence validator applied when Firstmate reads
# a published PR body; it leaves that validator's refusal unchanged on stderr.
set -u

usage() {
  printf '%s\n' 'usage: fm-pr-body-preflight.sh [--gh-url <url>] <body-file> <worker-worktree> <task-temp-dir>' >&2
  exit 2
}

gh_url=
if [ "${1:-}" = --gh-url ]; then
  [ "$#" -eq 5 ] || usage
  gh_url=$2
  shift 2
else
  [ "$#" -eq 3 ] || usage
fi
body_file=$1
worktree=$2
task_temp=$3

# shellcheck source=bin/fm-dod-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-dod-lib.sh"

if [ -n "$gh_url" ]; then
  if [[ ! "$gh_url" =~ ^https://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
    printf 'error: expected a canonical GitHub PR URL: %s\n' "$gh_url" >&2
    exit 1
  fi
  host=${BASH_REMATCH[1]}
  owner=${BASH_REMATCH[2]}
  repo=${BASH_REMATCH[3]}
  number=${BASH_REMATCH[4]}
  worktree_root=$(cd -P "$worktree" 2>/dev/null && pwd -P) || {
    printf 'error: worker worktree cannot be resolved: %s\n' "$worktree" >&2
    exit 1
  }
  task_temp_root=$(cd -P "$task_temp" 2>/dev/null && pwd -P) || {
    printf 'error: task temp directory cannot be resolved: %s\n' "$task_temp" >&2
    exit 1
  }
  body_parent=$(cd -P "$(dirname -- "$body_file")" 2>/dev/null && pwd -P) || {
    printf 'error: body-file directory cannot be resolved: %s\n' "$body_file" >&2
    exit 1
  }
  case "$body_parent/" in
    "$worktree_root/"|"$worktree_root/"*|"$task_temp_root/"|"$task_temp_root/"*) ;;
    *) printf 'error: body-file must be inside the worker worktree or task temp directory: %s\n' "$body_file" >&2; exit 1 ;;
  esac
  if [ -L "$body_file" ]; then
    printf 'error: body-file must not be a symlink: %s\n' "$body_file" >&2
    exit 1
  fi
  response=$(gh-axi pr view "$number" -R "$owner/$repo" --hostname "$host" --full) || exit 1
  quoted_body=$(printf '%s\n' "$response" | sed -n 's/^  body: //p')
  if [ -z "$quoted_body" ] || [ "$(printf '%s\n' "$quoted_body" | wc -l | tr -d ' ')" -ne 1 ] || printf '%s\n' "$response" | grep -Eq '^[[:space:]]+truncated: true$'; then
    printf 'error: gh-axi did not return one complete PR body: %s\n' "$gh_url" >&2
    exit 1
  fi
  body_tmp=$(mktemp "$body_file.XXXXXX") || exit 1
  if ! printf '%s\n' "$quoted_body" | jq -ej 'if type == "string" then . else error("PR body is not text") end' > "$body_tmp"; then
    rm -f -- "$body_tmp"
    printf 'error: gh-axi returned an unreadable PR body: %s\n' "$gh_url" >&2
    exit 1
  fi
  mv -f -- "$body_tmp" "$body_file" || { rm -f -- "$body_tmp"; exit 1; }
fi

if [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; then
  printf 'error: draft PR body is missing or unreadable: %s\n' "$body_file" >&2
  exit 1
fi
body=$(cat "$body_file") || exit 1
fm_dod_validate_intent_evidence "$body" "$worktree" "$task_temp" publish || exit 1
printf '%s\n' 'evidence preflight ok'

#!/usr/bin/env bash

fm_scratch_reserved_path() {
  case "/$1/" in
    */.codex-live-check/*|*/.corepack/*|*/.pnpm-store/*|*/.npm/*) return 0 ;;
  esac
  return 1
}

fm_scratch_check_paths() {
  local path
  while IFS= read -r -d '' path; do
    if fm_scratch_reserved_path "$path"; then
      printf 'error: scratch path would be published: %s\n' "$path" >&2
      return 1
    fi
  done
}

fm_scratch_check_lines() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if fm_scratch_reserved_path "$path"; then
      printf 'error: scratch path would be published: %s\n' "$path" >&2
      return 1
    fi
  done
}

fm_scratch_refuse_range() {
  local repo=$1 old=$2 new=$3 context=${4:-push} git_status check_status
  local -a statuses
  case "$new" in
    0000000000000000000000000000000000000000) return 0 ;;
  esac
  if [ "$old" = 0000000000000000000000000000000000000000 ]; then
    git -C "$repo" ls-tree -r --name-only -z "$new" | fm_scratch_check_paths
    statuses=("${PIPESTATUS[@]}")
  else
    git -C "$repo" diff --name-only --no-renames --diff-filter=ACMRTUXB -z "$old..$new" | fm_scratch_check_paths
    statuses=("${PIPESTATUS[@]}")
  fi
  git_status=${statuses[0]:-1}
  check_status=${statuses[1]:-1}
  if [ "$git_status" -ne 0 ] || [ "$check_status" -ne 0 ]; then
    printf 'error: scratch check failed during %s\n' "$context" >&2
    return 1
  fi
  return 0
}

fm_scratch_refuse_index() {
  git -C "$1" diff --cached --name-only --no-renames --diff-filter=ACMRTUXB -z | fm_scratch_check_paths
}

fm_scratch_branch_base() {
  local repo=$1 ref base
  for ref in refs/remotes/origin/house refs/remotes/origin/HEAD refs/heads/house refs/heads/main refs/heads/master; do
    if git -C "$repo" rev-parse --verify "$ref" >/dev/null 2>&1; then
      base=$(git -C "$repo" merge-base HEAD "$ref") || return 1
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}

fm_scratch_refuse_worktree() {
  local repo=$1 base
  fm_scratch_refuse_index "$repo" || return 1
  base=$(fm_scratch_branch_base "$repo") || {
    printf '%s\n' 'error: scratch preflight cannot determine the branch base' >&2
    return 1
  }
  fm_scratch_refuse_range "$repo" "$base" "$(git -C "$repo" rev-parse HEAD)" worktree
}

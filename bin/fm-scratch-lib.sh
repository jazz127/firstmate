#!/usr/bin/env bash
# shellcheck source=bin/fm-tangle-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tangle-lib.sh"

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

fm_scratch_refuse_diff() {
  local repo=$1 git_status check_status
  local -a statuses
  shift
  git -C "$repo" diff --name-only --no-renames --diff-filter=ACMRTUXB -z "$@" | fm_scratch_check_paths
  statuses=("${PIPESTATUS[@]}")
  git_status=${statuses[0]:-1}
  check_status=${statuses[1]:-1}
  if [ "$git_status" -ne 0 ] || [ "$check_status" -ne 0 ]; then
    printf '%s\n' 'error: scratch check failed' >&2
    return 1
  fi
  return 0
}

fm_scratch_branch_base() {
  local repo=$1 branch ref
  branch=$(fm_default_branch "$repo") || return 1
  for ref in "refs/remotes/origin/$branch" "refs/heads/$branch"; do
    if git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      git -C "$repo" merge-base HEAD "$ref"
      return
    fi
  done
  return 1
}

fm_scratch_refuse_worktree() {
  local repo=$1 base
  fm_scratch_refuse_diff "$repo" --cached || return 1
  base=$(fm_scratch_branch_base "$repo") || {
    printf '%s\n' 'error: scratch preflight cannot determine the branch base' >&2
    return 1
  }
  fm_scratch_refuse_diff "$repo" "$base..HEAD"
}

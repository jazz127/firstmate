# shellcheck shell=bash
# Shared runtime branch resolution for updater and tangle detection.
# firstmate_runtime_branch <repo>: configured firstmate.runtimeBranch, or the
# historical origin/HEAD then local main/master fallback when unset.
firstmate_runtime_branch() {
  local dir=$1 configured branch
  if git -C "$dir" config --get firstmate.runtimeBranch >/dev/null 2>&1; then
    configured=$(git -C "$dir" config --get-all firstmate.runtimeBranch 2>/dev/null) || return 1
    case "$configured" in ''|*$'\n'*|/*|*-|.*|*..*|*' '*|*'~'*|*'^'*|*':'*|*'?'*|*'['*|*'\\'*) return 1 ;; esac
    git check-ref-format --branch "$configured" >/dev/null 2>&1 || return 1
    git -C "$dir" show-ref --verify --quiet "refs/heads/$configured" || return 1
    printf '%s\n' "$configured"
    return 0
  fi
  local ref
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    branch=${ref#origin/}
    git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1
    printf '%s\n' "$branch"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

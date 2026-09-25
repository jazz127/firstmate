# shellcheck shell=bash
# Shared runtime branch and tracking-source resolution for Firstmate consumers.
# firstmate_runtime_branch <repo>: configured firstmate.runtimeBranch, or the
# historical origin/HEAD then local main/master fallback when unset.
firstmate_runtime_branch() {
  local dir=$1 configured branch
  if git -C "$dir" config --get firstmate.runtimeBranch >/dev/null 2>&1; then
    configured=$(git -C "$dir" config --get-all firstmate.runtimeBranch 2>/dev/null) || return 1
    case "$configured" in ''|*$'\n'*) return 1 ;; esac
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

firstmate_runtime_branch_is_configured() {
  git -C "$1" config --get firstmate.runtimeBranch >/dev/null 2>&1
}

FIRSTMATE_RUNTIME_REMOTE=
FIRSTMATE_RUNTIME_MERGE_REF=
FIRSTMATE_RUNTIME_TRACKING_REF=
FIRSTMATE_RUNTIME_FETCH_REFSPEC=

# Resolve the configured runtime branch's fetch source for sync consumers.
# firstmate_runtime_tracking_source <repo> <runtime-branch>
firstmate_runtime_tracking_source() {
  local dir=$1 branch=$2 remote merge_ref merge_branch
  FIRSTMATE_RUNTIME_REMOTE=
  FIRSTMATE_RUNTIME_MERGE_REF=
  FIRSTMATE_RUNTIME_TRACKING_REF=
  FIRSTMATE_RUNTIME_FETCH_REFSPEC=
  remote=$(git -C "$dir" config --get "branch.$branch.remote" 2>/dev/null) || return 1
  merge_ref=$(git -C "$dir" config --get "branch.$branch.merge" 2>/dev/null) || return 1
  case "$remote" in ''|-*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$merge_ref" in refs/heads/*) merge_branch=${merge_ref#refs/heads/} ;; *) return 1 ;; esac
  git check-ref-format --branch "$merge_branch" >/dev/null 2>&1 || return 1
  git -C "$dir" remote get-url "$remote" >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2034
  FIRSTMATE_RUNTIME_REMOTE=$remote
  # shellcheck disable=SC2034
  FIRSTMATE_RUNTIME_MERGE_REF=$merge_ref
  FIRSTMATE_RUNTIME_TRACKING_REF="refs/remotes/$remote/$merge_branch"
  # shellcheck disable=SC2034
  FIRSTMATE_RUNTIME_FETCH_REFSPEC="+$merge_ref:$FIRSTMATE_RUNTIME_TRACKING_REF"
}

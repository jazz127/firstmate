#!/usr/bin/env bash
# fm-housefeature-cut.sh - cut a merged house pull request's durable housefeature/<name> branch.
#
# Usage: bin/fm-housefeature-cut.sh name <head-ref>
#        bin/fm-housefeature-cut.sh classify
#        bin/fm-housefeature-cut.sh run
#
# name prints the durable feature name for a pull request head ref: a ref
# already under housefeature/ keeps its name; otherwise a leading fm/, then a
# leading firstmate-, then a trailing round suffix such as -r1 or -c2 is
# stripped. It exits 1 when no valid branch name remains.
#
# classify reads the HF_* environment below and prints either
# "cut <name>" or "skip <reason>". It skips a pull request that was not merged,
# whose base is not house, whose head lives in another repository, or whose
# head ref contains upstream-merge or reconcile (upstream main brought into house).
#
# run classifies, then in the current clone of the fork: leaves an existing
# housefeature/<name> untouched; otherwise commits the pull request's change
# on top of the fork's main when it applies cleanly there, else captures the
# merged pull request head, and pushes only refs/heads/housefeature/<name>
# without force. Every outcome appends one line to $GITHUB_STEP_SUMMARY
# (stdout when unset). Only a failed git operation or push exits non-zero.
#
# Environment (the .github/workflows/housefeature-cut.yml event fields):
#   HF_MERGED      "true" when the pull request was merged
#   HF_BASE_REF    base branch name
#   HF_HEAD_REF    head branch name
#   HF_BASE_REPO   base repository full name
#   HF_HEAD_REPO   head repository full name
#   HF_PR_NUMBER   pull request number (run)
#   HF_PR_TITLE    pull request title (run; commit subject for a main cut)
#   HF_HEAD_SHA    pull request head commit (run)
#   HF_MERGE_SHA   commit the merge created on house (run)
#   HF_REMOTE      fork remote name, default origin (run)
# The committer identity for a main cut comes from GIT_COMMITTER_NAME and
# GIT_COMMITTER_EMAIL; the author is the pull request head commit's author.
set -eu

HOUSE_BRANCH=house
MAIN_BRANCH=main
PREFIX=housefeature/

feature_name() {
  local ref=$1 name
  case "$ref" in
    "$PREFIX"*) name=${ref#"$PREFIX"} ;;
    *)
      name=${ref#fm/}
      name=${name#firstmate-}
      if [[ "$name" =~ ^(.+)-[rc][0-9]+$ ]]; then
        name=${BASH_REMATCH[1]}
      fi
      ;;
  esac
  [ -n "$name" ] || return 1
  git check-ref-format "refs/heads/$PREFIX$name" || return 1
  printf '%s\n' "$name"
}

classify() {
  local name
  if [ "${HF_MERGED:-}" != true ]; then
    printf 'skip pull request was closed without merging\n'
  elif [ "${HF_BASE_REF:-}" != "$HOUSE_BRANCH" ]; then
    printf 'skip base is %s, not %s\n' "${HF_BASE_REF:-<none>}" "$HOUSE_BRANCH"
  elif [ -z "${HF_HEAD_REPO:-}" ] || [ "${HF_HEAD_REPO:-}" != "${HF_BASE_REPO:-}" ]; then
    printf 'skip head is from another repository (%s)\n' "${HF_HEAD_REPO:-<deleted>}"
  else
    case "${HF_HEAD_REF:-}" in
      *upstream-merge*|*reconcile*)
        printf 'skip %s brings upstream main into %s\n' "$HF_HEAD_REF" "$HOUSE_BRANCH"
        ;;
      *)
        if name=$(feature_name "${HF_HEAD_REF:-}" 2>/dev/null); then
          printf 'cut %s\n' "$name"
        else
          printf 'skip head ref %s gives no valid feature name\n' "${HF_HEAD_REF:-<none>}"
        fi
        ;;
    esac
  fi
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
  printf '%s\n' "$1"
}

need() {
  [ -n "${!1:-}" ] || { printf 'fm-housefeature-cut.sh: %s is required\n' "$1" >&2; exit 2; }
}

# cut_from_main <fork-point>: print a commit on the fork's main carrying the
# pull request's change, or nothing when it does not apply cleanly there.
cut_from_main() {
  local fork_point=$1 main_sha index tree='' author_name author_email author_date
  main_sha=$(git rev-parse --verify "refs/remotes/$REMOTE/$MAIN_BRANCH^{commit}")
  git diff --quiet "$fork_point" "$HF_HEAD_SHA" && return 0
  index=$(mktemp)
  if GIT_INDEX_FILE=$index git read-tree "$main_sha" &&
    git diff --binary --no-renames "$fork_point" "$HF_HEAD_SHA" \
      | GIT_INDEX_FILE=$index git apply --cached 2>/dev/null; then
    tree=$(GIT_INDEX_FILE=$index git write-tree)
  fi
  rm -f "$index"
  [ -n "$tree" ] || return 0
  author_name=$(git log -1 --format=%an "$HF_HEAD_SHA")
  author_email=$(git log -1 --format=%ae "$HF_HEAD_SHA")
  author_date=$(git log -1 --format=%aI "$HF_HEAD_SHA")
  printf '%s (#%s)\n\nCut from %s by the house feature workflow from %s pull request #%s head %s.\n' \
    "$HF_PR_TITLE" "$HF_PR_NUMBER" "$MAIN_BRANCH" "$HF_BASE_REPO" "$HF_PR_NUMBER" "$HF_HEAD_SHA" \
    | GIT_AUTHOR_NAME=$author_name GIT_AUTHOR_EMAIL=$author_email GIT_AUTHOR_DATE=$author_date \
      git commit-tree "$tree" -p "$main_sha"
}

run() {
  local decision name branch existing rc fork_point sha source
  decision=$(classify)
  case "$decision" in
    skip\ *)
      summary "Skipped pull request #${HF_PR_NUMBER:-?}: ${decision#skip }; nothing pushed."
      return 0
      ;;
  esac
  name=${decision#cut }
  branch=$PREFIX$name
  need HF_PR_NUMBER; need HF_PR_TITLE; need HF_HEAD_SHA; need HF_MERGE_SHA
  REMOTE=${HF_REMOTE:-origin}

  rc=0
  existing=$(git ls-remote --exit-code --heads "$REMOTE" "refs/heads/$branch") || rc=$?
  if [ "$rc" -eq 0 ]; then
    summary "Left existing \`$branch\` at ${existing%%[[:space:]]*} unchanged for pull request #$HF_PR_NUMBER."
    return 0
  elif [ "$rc" -ne 2 ]; then
    summary "Could not read \`$branch\` from $REMOTE for pull request #$HF_PR_NUMBER; nothing pushed."
    return 1
  fi

  git fetch --quiet --no-tags "$REMOTE" \
    "+refs/heads/$MAIN_BRANCH:refs/remotes/$REMOTE/$MAIN_BRANCH" \
    "+refs/heads/$HOUSE_BRANCH:refs/remotes/$REMOTE/$HOUSE_BRANCH" \
    "+refs/pull/$HF_PR_NUMBER/head:refs/remotes/$REMOTE/pull/$HF_PR_NUMBER/head" 2>/dev/null \
    || git fetch --quiet --no-tags "$REMOTE" \
      "+refs/heads/$MAIN_BRANCH:refs/remotes/$REMOTE/$MAIN_BRANCH" \
      "+refs/heads/$HOUSE_BRANCH:refs/remotes/$REMOTE/$HOUSE_BRANCH"
  git cat-file -e "$HF_HEAD_SHA^{commit}"
  git cat-file -e "$HF_MERGE_SHA^{commit}"
  fork_point=$(git merge-base "$HF_MERGE_SHA^1" "$HF_HEAD_SHA")

  sha=$(cut_from_main "$fork_point")
  if [ -n "$sha" ]; then
    source="cut from \`$MAIN_BRANCH\` (the change applies cleanly there)"
  else
    sha=$HF_HEAD_SHA
    source="captured from the merged pull request head (the change does not apply cleanly to \`$MAIN_BRANCH\`)"
  fi

  if ! git push --quiet "$REMOTE" "$sha:refs/heads/$branch"; then
    summary "Push of \`$branch\` for pull request #$HF_PR_NUMBER was refused; nothing created."
    return 1
  fi
  summary "Created \`$branch\` at $sha for pull request #$HF_PR_NUMBER, $source."
}

case "${1-}" in
  name)
    [ "$#" -eq 2 ] || { printf 'usage: %s name <head-ref>\n' "$0" >&2; exit 2; }
    feature_name "$2"
    ;;
  classify)
    [ "$#" -eq 1 ] || exit 2
    classify
    ;;
  run)
    [ "$#" -eq 1 ] || exit 2
    run
    ;;
  -h|--help|help)
    sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'
    ;;
  *)
    printf 'usage: %s name <head-ref>|classify|run\n' "$0" >&2
    exit 2
    ;;
esac

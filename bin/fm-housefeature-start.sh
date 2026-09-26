#!/usr/bin/env bash
# Prepare a house-feature worker branch in the current isolated fork worktree.
# Usage: fm-housefeature-start.sh <feature-name> <main|house> <worker-branch>
#
# The first run fetches the selected fork base and creates
# refs/heads/housefeature/<feature-name> at that exact commit if absent.
# Creation uses GitHub's create-ref API, which refuses a concurrent branch
# creation instead of moving any existing head.
# A later run fetches the durable branch and starts a fresh worker branch from
# its current head. Neither path merges main; a refresh from main is a separate
# deliberate step. The worker branch is never pushed here. No remote ref is
# deleted or force-pushed.
set -eu

[ "$#" -eq 3 ] || { echo "usage: $0 <feature-name> <main|house> <worker-branch>" >&2; exit 2; }
name=$1
base=$2
worker=$3
case "$name" in
  ''|*[!a-zA-Z0-9._-]*) echo "error: feature name must be a single branch-name component" >&2; exit 2 ;;
esac
case "$base" in
  main|house) ;;
  *) echo "error: feature base must be main or house" >&2; exit 2 ;;
esac
feature="housefeature/$name"
git check-ref-format --branch "$feature" >/dev/null 2>&1 || {
  echo "error: invalid feature branch $feature" >&2
  exit 2
}
git check-ref-format --branch "$worker" >/dev/null 2>&1 || {
  echo "error: invalid worker branch $worker" >&2
  exit 2
}
[ "$worker" != "$feature" ] || {
  echo "error: worker branch must differ from durable feature branch" >&2
  exit 2
}
status=$(git status --porcelain) || {
  echo "error: current directory is not a usable git worktree" >&2
  exit 1
}
[ -z "$status" ] || {
  echo "error: worktree is not clean; refusing to change branches" >&2
  exit 1
}
origin_url=$(git config --get remote.origin.url) || {
  echo "error: origin must be a GitHub fork with house as its default branch" >&2
  exit 1
}
case "$origin_url" in
  https://github.com/*) repo=${origin_url#https://github.com/} ;;
  git@github.com:*) repo=${origin_url#git@github.com:} ;;
  ssh://git@github.com/*) repo=${origin_url#ssh://git@github.com/} ;;
  *) echo "error: origin must be a github.com fork URL" >&2; exit 1 ;;
esac
repo=${repo%.git}
case "$repo" in
  */*) owner=${repo%%/*}; repo_name=${repo#*/} ;;
  *) echo "error: origin must name one GitHub owner and repository" >&2; exit 1 ;;
esac
[ -n "$owner" ] && [ -n "$repo_name" ] || {
  echo "error: origin must name one GitHub owner and repository" >&2
  exit 1
}
case "$owner/$repo_name" in
  *[!a-zA-Z0-9._/-]*|*/*/*|/*|*/|*/.git)
    echo "error: origin must name one GitHub owner and repository" >&2
    exit 1
    ;;
esac
symref=$(git ls-remote --symref origin HEAD) || {
  echo "error: could not read origin's default branch" >&2
  exit 1
}
printf '%s\n' "$symref" | awk '$1 == "ref:" && $2 == "refs/heads/house" && $3 == "HEAD" { found=1 } END { exit !found }' || {
  echo "error: origin's default branch must be house; use the fork-origin run clone" >&2
  exit 1
}
remote_ref="refs/heads/$feature"
tracking_ref="refs/remotes/origin/$feature"
git fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base"
rc=0
git ls-remote --exit-code --heads origin "$remote_ref" >/dev/null || rc=$?
case "$rc" in
  0) ;;
  2)
    base_sha=$(git rev-parse --verify "refs/remotes/origin/$base^{commit}")
    gh-axi api POST "/repos/$repo/git/refs" \
      --field "ref=$remote_ref" --field "sha=$base_sha" >/dev/null || {
      echo "error: could not create $feature at fork $base; inspect the remote before retrying" >&2
      exit 1
    }
    ;;
  *) echo "error: could not inspect $remote_ref on origin" >&2; exit 1 ;;
esac
git fetch --quiet origin "+$remote_ref:$tracking_ref"
git checkout -b "$worker" "$tracking_ref" --
printf 'prepared %s from %s on %s\n' "$worker" "$feature" "$base"

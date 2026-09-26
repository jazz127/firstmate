set -u
src=bin/fm-pr-merge.sh
eval "$(sed -n '/^github_urlencode_path_segment() {/,/^}/p' "$src")"
eval "$(sed -n '/^FM_PR_GITHUB_DEFAULT_METHOD=$/,/^}/p' "$src")"
PR_OWNER=jazz127 PR_REPO=no-such-repo-fm-test FM_PR_GITHUB_BASE=house URL=https://github.com/jazz127/no-such-repo-fm-test/pull/0
github_choose_default_method; echo "rc=$? chosen='$FM_PR_GITHUB_DEFAULT_METHOD'"

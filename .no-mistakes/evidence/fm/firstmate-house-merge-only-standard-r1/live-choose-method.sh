#!/usr/bin/env bash
# Runs bin/fm-pr-merge.sh's own github_choose_default_method (extracted verbatim)
# against live GitHub with read-only gh calls; no merge is attempted.
. "/Users/jarad/.no-mistakes/evidence/01M3DHTJP42G50S1EWQDS6WXQ0/choose-method-extract.sh"
for target in jazz127/firstmate:house jazz127/quota-axi:house jazz127/firstmate:main; do
  PR_OWNER=${target%%/*}; rest=${target#*/}; PR_REPO=${rest%%:*}; FM_PR_GITHUB_BASE=${target##*:}
  URL="https://github.com/$PR_OWNER/$PR_REPO/pull/(dry-run)"
  if github_choose_default_method; then
    echo "$target -> default method: --$FM_PR_GITHUB_DEFAULT_METHOD"
  else
    echo "$target -> refused (rc=1)"
  fi
done

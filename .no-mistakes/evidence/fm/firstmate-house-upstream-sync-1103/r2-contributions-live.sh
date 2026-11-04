#!/usr/bin/env bash
set -eu
E=~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV
export FM_HOME="$PWD/.phase-tmp/r2-github-home"
bin/fm-lab-home.sh create "$FM_HOME"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND
bin/fm-contributions.sh enroll public-pr https://github.com/kunchenguid/firstmate/pull/8135
bin/fm-contributions.sh poll
cat "$FM_HOME/data/public-pr/contributions.json" > "$E/r2-public-pr-contribution.json"
jq '{task,urls:[.records[]? | {url,error,head:.observation.head,state:.observation.state}]}' "$E/r2-public-pr-contribution.json"

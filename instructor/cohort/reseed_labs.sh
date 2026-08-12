#!/usr/bin/env bash
###############################################################################
# IO-107 -- force re-seed the per-student CodeCommit lab repos from the
# GitHub monorepo, WITHOUT touching any other infrastructure.
#
# Why this exists: null_resource.lab{1,2,3,4}_seed clones fixtures from
# https://github.com/roi-cloud-fun/io-107.git, but its `triggers` are only
# repo_arn / monorepo_url / fixture_subdir -- there is NO content hash. So when
# the monorepo changes (e.g. the us-east-1 hardcoding fix, commit a1bf33d), a
# plain re-apply is a no-op and students keep the stale fixtures. `-replace`
# forces the provisioner to re-run.
#
# The seed provisioner ends in `git push --force`, so re-seeding is safe and
# idempotent against a repo that already has content.
#
# NOTE: the push fires the EventBridge rule -> the student's CodePipeline runs
# again automatically. That is the point: it is how the fix reaches the labs.
#
# Usage:
#   ./reseed_labs.sh user04 user05 user06 user07      # subset
#   LABS="2 3 4" ./reseed_labs.sh user04              # only some labs
###############################################################################
set -uo pipefail

# Resolved from this script's own location (it lives at instructor/cohort/).
# HERE is the ops directory holding cohort/ and the run logs; it defaults to the
# checkout's parent so nothing is written into git. Override if your layout
# differs.
REPO="${IO107_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HERE="${IO107_OPS_DIR:-$(cd "$REPO/.." && pwd)}"
COHORT="$HERE/cohort"

export AWS_PROFILE="${AWS_PROFILE:-io107}"
# Without this, the CodeCommit credential-helper push blocks forever on Windows
# waiting for a Git Credential Manager prompt that never appears.
export GCM_INTERACTIVE=never
export GIT_TERMINAL_PROMPT=0

# Git for Windows configures `credential.helper = manager` at SYSTEM level.
# The seed provisioner adds the AWS helper with `-c`, but helpers run in order,
# so GCM answers FIRST. On the initial seed it has nothing cached, returns
# empty, and git falls through to the AWS helper -- which works, and GCM then
# STORES that credential. CodeCommit credential-helper credentials are
# short-lived, so on any LATER push GCM confidently replays the expired one and
# git never reaches the AWS helper => HTTP 403.
#
# An empty credential.helper value RESETS the helper list. Injecting it via
# GIT_CONFIG_* applies it to every git process the provisioner spawns, and it
# is read after system config but before `-c`, so the net list is just the AWS
# helper. Verified: `git ls-remote` 403s without this and succeeds with it.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=
export TF_PLUGIN_CACHE_DIR="$HERE/.tfplugincache"

LABS="${LABS:-1 2 3 4}"
STATUS="$HERE/reseed-status.txt"; : > "$STATUS"

[ $# -eq 0 ] && { echo "usage: $0 <student-id>..." >&2; exit 2; }

reseed_one(){
  local S="$1" D="$COHORT/$1"
  {
    cd "$D" || { echo "$S NO-DIR" >> "$STATUS"; exit 1; }

    local args=()
    for L in $LABS; do args+=( -replace="null_resource.lab${L}_seed[0]" ); done

    # -parallelism=1: the seeds are `git push` to CodeCommit, which throttles.
    # 4 students x 4 labs pushed at once returned HTTP 429 ("RPC failed ...
    # remote end hung up") for 2 of the 4 students. Seeding is seconds of work,
    # so serialising within a student costs almost nothing and removes the
    # throttle. Still run at most a couple of STUDENTS at a time.
    if terraform apply -input=false -auto-approve -no-color \
         -parallelism="${TF_PARALLELISM:-1}" \
         "${args[@]}" \
         -var enable_lab1=true -var enable_lab2=true \
         -var enable_lab3=true -var enable_lab4=true \
         > "$HERE/reseed-$S.log" 2>&1; then
      echo "$S OK $(date -u +%H:%M:%SZ)" >> "$STATUS"
    else
      echo "$S RESEED-FAILED $(date -u +%H:%M:%SZ)" >> "$STATUS"
    fi
  } &
}

echo "Re-seeding labs [$LABS] for: $*"
for S in "$@"; do
  [ -d "$COHORT/$S" ] || { echo "$S NO-DIR" >> "$STATUS"; continue; }
  echo "==> reseed $S [background]"
  reseed_one "$S"
done
wait

echo ""
echo "==================== RESEED SUMMARY ===================="
sort "$STATUS"
echo "========================================================"
grep -h '^Apply complete' "$HERE"/reseed-user*.log 2>/dev/null | sort | uniq -c

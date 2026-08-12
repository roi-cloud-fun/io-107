#!/usr/bin/env bash
###############################################################################
# IO-107 — deploy the WHOLE cohort in parallel.
#
# The existing deploy_cohort.sh is sequential because every student shares the
# single working directory lab_environment/lab_env_student and backend.tf is
# rewritten per student. 8 students x ~15 min = ~2 hours.
#
# This script removes that constraint (the improvement flagged as "not yet
# done" in DEPLOY_LOG §6): bootstrap runs sequentially (it is only an S3 bucket
# + two small file writes, a few seconds each), then each student gets their
# OWN copy of the module directory so the applies can run concurrently.
# Expect ~20-25 min wall clock instead of ~2 hours.
#
# Usage:
#   ./deploy_cohort_parallel.sh                 # full cohort, both regions
#   ./deploy_cohort_parallel.sh user01 user02   # subset
#
# Env:
#   ENABLE_LAB1..4   default true
#   MAXPAR           max concurrent applies (default 8)
###############################################################################
set -uo pipefail

# Resolved from this script's own location so the toolkit works from any clone.
# REPO = the io-107 checkout (this file lives at instructor/cohort/ inside it).
# HERE = the ops directory holding cohort/, .tfplugincache and the run logs;
#        defaults to the checkout's parent so nothing is written into git.
REPO="${IO107_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HERE="${IO107_OPS_DIR:-$(cd "$REPO/.." && pwd)}"
SRC="$REPO/lab_environment/lab_env_student"
COHORT="$HERE/cohort"
ACCOUNT_ID="${IO107_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

export AWS_PROFILE="${AWS_PROFILE:-io107}"
export GCM_INTERACTIVE=never
export GIT_TERMINAL_PROMPT=0
# Reset the git credential-helper list so the CodeCommit push uses ONLY the AWS
# helper. Git for Windows sets `credential.helper = manager` at SYSTEM level and
# helpers answer in order; GCM caches the short-lived CodeCommit credential on
# first use and then replays it after expiry => HTTP 403 on any re-push. A fresh
# repo happens to work (nothing cached yet), which is why this stayed hidden
# until the first re-seed. See reseed_labs.sh for the full write-up.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=
# One shared provider cache -- without this each of the 8 working directories
# downloads its own copy of the AWS provider (~700MB total, and slow).
export TF_PLUGIN_CACHE_DIR="$HERE/.tfplugincache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

ENABLE_LAB1="${ENABLE_LAB1:-true}"; ENABLE_LAB2="${ENABLE_LAB2:-true}"
ENABLE_LAB3="${ENABLE_LAB3:-true}"; ENABLE_LAB4="${ENABLE_LAB4:-true}"
MAXPAR="${MAXPAR:-8}"

# student:region -- the agreed split from DEPLOY_LOG §2.
ALL=(user50:us-east-1 user01:us-east-1 user02:us-east-1 user03:us-east-1
     user04:us-east-2 user05:us-east-2 user06:us-east-2 user07:us-east-2)

TARGETS=()
if [ $# -gt 0 ]; then
  for want in "$@"; do
    for pair in "${ALL[@]}"; do
      [ "${pair%%:*}" = "$want" ] && TARGETS+=("$pair")
    done
  done
else
  TARGETS=("${ALL[@]}")
fi
[ ${#TARGETS[@]} -eq 0 ] && { echo "no matching students" >&2; exit 2; }

STATUS="$HERE/cohort-status.txt"; : > "$STATUS"
echo "Deploying ${#TARGETS[@]} students, labs 1=$ENABLE_LAB1 2=$ENABLE_LAB2 3=$ENABLE_LAB3 4=$ENABLE_LAB4"

# ---------------------------------------------------------------------------
# Phase 1 (sequential, fast): bootstrap writes backend.tf + terraform.tfvars
# into the shared SRC dir, so it cannot be parallelised. Snapshot the result
# into a per-student directory immediately after each run.
# ---------------------------------------------------------------------------
for pair in "${TARGETS[@]}"; do
  S="${pair%%:*}"; R="${pair##*:}"
  echo "==> bootstrap $S ($R)"
  "$REPO/instructor/bootstrap.sh" --student-id "$S" --region "$R" \
      --profile "$AWS_PROFILE" --force-tfvars >/dev/null 2>&1 \
    || { echo "$S BOOTSTRAP-FAILED" >> "$STATUS"; continue; }

  # Student (not the applying instructor) gets the EKS access entry -- §5a.
  cat >> "$SRC/terraform.tfvars" <<EOF

apply_host_principal_arn = "arn:aws:iam::$ACCOUNT_ID:user/$S"
EOF

  D="$COHORT/$S"
  rm -rf "$D"; mkdir -p "$D"
  # Copy module source + the just-generated backend.tf/tfvars. Exclude state,
  # provider cache and prior run artifacts.
  tar -C "$SRC" -cf - \
      --exclude='.terraform' --exclude='.terraform.lock.hcl' \
      --exclude='*.tfstate*' --exclude='tfplan*' \
      --exclude='*.log' --exclude='outputs-*.json' --exclude='plan*.json' \
      . | tar -C "$D" -xf -
done

# ---------------------------------------------------------------------------
# Phase 2 (parallel): each student applies in their own directory.
# ---------------------------------------------------------------------------
# `terraform init` is run SEQUENTIALLY below, never in parallel: the shared
# TF_PLUGIN_CACHE_DIR is not safe for concurrent writes, and two inits racing to
# populate it can corrupt the cache. Reads are safe, so once the first init has
# warmed it the rest are fast.
for pair in "${TARGETS[@]}"; do
  S="${pair%%:*}"
  [ -d "$COHORT/$S" ] || continue
  echo "==> init $S"
  ( cd "$COHORT/$S" && terraform init -input=false >/dev/null 2>&1 ) \
    || echo "$S INIT-FAILED" >> "$STATUS"
done

run_one(){
  local S="$1" R="$2" D="$COHORT/$1"
  {
    cd "$D" || exit 1
    if terraform apply -input=false -auto-approve -no-color \
         -var "enable_lab1=$ENABLE_LAB1" -var "enable_lab2=$ENABLE_LAB2" \
         -var "enable_lab3=$ENABLE_LAB3" -var "enable_lab4=$ENABLE_LAB4" \
         > "$HERE/apply-$S.log" 2>&1; then
      terraform output -json > "$HERE/outputs-$S.json" 2>/dev/null
      echo "$S OK $(date -u +%H:%M:%SZ)" >> "$STATUS"
    else
      echo "$S APPLY-FAILED $(date -u +%H:%M:%SZ)" >> "$STATUS"
    fi
  } &
}

running=0
for pair in "${TARGETS[@]}"; do
  S="${pair%%:*}"; R="${pair##*:}"
  [ -d "$COHORT/$S" ] || continue
  echo "==> apply $S ($R) [background]"
  run_one "$S" "$R"
  running=$((running+1))
  if [ "$running" -ge "$MAXPAR" ]; then wait -n 2>/dev/null || wait; running=$((running-1)); fi
done
wait

echo ""
echo "==================== COHORT SUMMARY ===================="
sort "$STATUS"
echo "========================================================"
grep -h '^Apply complete' "$HERE"/apply-user*.log 2>/dev/null | sort | uniq -c

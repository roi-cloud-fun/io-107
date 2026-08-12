#!/usr/bin/env bash
###############################################################################
# IO-107 — deploy one student environment end-to-end.
#
# Wraps instructor/bootstrap.sh with the two things it doesn't do:
#   1. apply_host_principal_arn -> the STUDENT's IAM user, so they get an EKS
#      access entry and can run the kubectl/helm steps in Lab 1 Part B.
#      (The applying instructor keeps cluster admin via
#      bootstrap_cluster_creator_admin_permissions on the cluster.)
#   2. GCM_INTERACTIVE=never / GIT_TERMINAL_PROMPT=0 -- REQUIRED on Windows.
#      The labN_seed provisioners append the AWS credential helper with `git -c`
#      rather than replacing the global helper, so Git Credential Manager is
#      tried first and pops an interactive prompt that HANGS terraform apply at
#      ~90%. These vars make GCM fail fast so git falls through to the AWS
#      helper. Harmless on Linux.
#
# Usage:
#   ./deploy_cohort.sh user01 us-east-1
#   ./deploy_cohort.sh user04 us-east-2
#   ENABLE_LAB3=false ENABLE_LAB4=false ./deploy_cohort.sh user01 us-east-1
#
# Env:
#   AWS_PROFILE                    defaults to io107
#   ACCOUNT_ID                     defaults to the profile's account (via STS)
#   ENABLE_LAB1..ENABLE_LAB4       default true. Passed as -var, which OVERRIDES
#                                  the all-true block bootstrap.sh writes into
#                                  terraform.tfvars (it has no flag for these).
#                                  Shared infra (VPC, EKS, ECR, KMS, IAM) is
#                                  unconditional; these only gate each lab's
#                                  pipeline/CodeBuild/CodeCommit/IRSA (+ Aurora
#                                  for lab4). Flip a lab back to true and re-run
#                                  to add it later -- it is additive, and does
#                                  not disturb the labs already deployed.
###############################################################################
set -euo pipefail

STUDENT_ID="${1:?usage: deploy_cohort.sh <student-id> <region>}"
REGION="${2:?usage: deploy_cohort.sh <student-id> <region>}"

ENABLE_LAB1="${ENABLE_LAB1:-true}"
ENABLE_LAB2="${ENABLE_LAB2:-true}"
ENABLE_LAB3="${ENABLE_LAB3:-true}"
ENABLE_LAB4="${ENABLE_LAB4:-true}"
LAB_VARS=(
  -var "enable_lab1=$ENABLE_LAB1"
  -var "enable_lab2=$ENABLE_LAB2"
  -var "enable_lab3=$ENABLE_LAB3"
  -var "enable_lab4=$ENABLE_LAB4"
)

export AWS_PROFILE="${AWS_PROFILE:-io107}"
# See header: without these the seed push hangs on a GCM prompt on Windows.
export GCM_INTERACTIVE=never
export GIT_TERMINAL_PROMPT=0

# This script lives at instructor/cohort/ inside the io-107 checkout, so the
# repo root is two levels up. Override with IO107_REPO if you relocate it.
REPO_ROOT="${IO107_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TF_DIR="$REPO_ROOT/lab_environment/lab_env_student"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

echo "############################################################"
echo "# $STUDENT_ID -> $REGION   (account $ACCOUNT_ID)"
echo "# labs: 1=$ENABLE_LAB1 2=$ENABLE_LAB2 3=$ENABLE_LAB3 4=$ENABLE_LAB4"
echo "############################################################"

# 1. State bucket + backend.tf + tfvars
"$REPO_ROOT/instructor/bootstrap.sh" \
  --student-id "$STUDENT_ID" \
  --region "$REGION" \
  --profile "$AWS_PROFILE" \
  --force-tfvars

# 2. Grant the student EKS cluster-admin on their own cluster.
cat >> "$TF_DIR/terraform.tfvars" <<EOF

# Student gets the EKS access entry so Lab 1 Part B (kubectl/helm) works.
apply_host_principal_arn = "arn:aws:iam::${ACCOUNT_ID}:user/${STUDENT_ID}"
EOF

cd "$TF_DIR"

# 3. -reconfigure: backend.tf now points at a DIFFERENT per-student bucket/key.
#    Without it terraform offers to MIGRATE the previous student's state.
terraform init -input=false -reconfigure

terraform plan  -input=false "${LAB_VARS[@]}" -out="tfplan.$STUDENT_ID"
terraform apply -input=false -no-color "tfplan.$STUDENT_ID" \
  2>&1 | tee "apply-$STUDENT_ID.log"

# 4. Capture outputs per student (terraform output alone is overwritten next run)
terraform output -json > "outputs-$STUDENT_ID.json"

echo ""
echo "== $STUDENT_ID done =="
terraform output -raw eks_cluster_name; echo
terraform output -raw kubeconfig_command; echo

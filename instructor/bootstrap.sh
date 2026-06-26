#!/usr/bin/env bash
###############################################################################
# IO-107 — Instructor bootstrap.
#
# Idempotent end-to-end setup for the lab environment. Creates the S3 state
# bucket if missing, generates backend.tf + terraform.tfvars, surfaces the
# CodeStar connection (creating it requires browser OAuth — script tells you
# what to click), and optionally runs `terraform apply`.
#
# Re-run any time. Existing resources are left alone.
#
# Usage:
#   ./instructor/bootstrap.sh --student-id ltf-smoke
#   ./instructor/bootstrap.sh --student-id ltf-smoke --apply       # also runs terraform apply
#   ./instructor/bootstrap.sh --student-id ltf-smoke --region us-west-2 --profile sandbox
#
# Required:
#   --student-id <ID>        Short ID (lowercase, 1-16 chars). Used to tag every
#                            resource and as the Terraform state key suffix.
#
# Optional:
#   --region <REGION>        AWS region. Default: us-east-1.
#   --profile <PROFILE>      AWS named profile. Default: $AWS_PROFILE env, else "default".
#   --apply                  Also run `terraform init && terraform apply` at the end.
#   --course-id <ID>         Used to name the state bucket. Default: io107.
#   --force-tfvars           Overwrite an existing terraform.tfvars.
#   -h | --help              Show this and exit.
#
# What it does NOT do:
#   - Tear anything down. Use `terraform destroy` for that.
#
# Note: no GitHub OAuth required. In student mode the pipelines read from
# per-student CodeCommit repos (created + seeded by Terraform from the public
# monorepo). GitHub is only touched once during `terraform apply` -- a public
# git clone of roi-cloud-fun/io-107 -- so no CodeStar connection is created.
###############################################################################

set -euo pipefail

# --- Args ---
REGION="us-east-1"
COURSE_ID="io107"
STUDENT_ID=""
PROFILE="${AWS_PROFILE:-}"
DO_APPLY=0
FORCE_TFVARS=0

print_help() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)         REGION="$2"; shift 2;;
    --course-id)      COURSE_ID="$2"; shift 2;;
    --student-id)     STUDENT_ID="$2"; shift 2;;
    --profile)        PROFILE="$2"; shift 2;;
    --apply)          DO_APPLY=1; shift;;
    --force-tfvars)   FORCE_TFVARS=1; shift;;
    -h|--help)        print_help; exit 0;;
    *) echo "Unknown argument: $1" >&2; echo "Run with --help for usage." >&2; exit 2;;
  esac
done

if [[ -z "$STUDENT_ID" ]]; then
  echo "ERROR: --student-id is required (e.g., ltf-smoke or your-short-name)." >&2
  echo "Run with --help for usage." >&2
  exit 2
fi

if [[ ! "$STUDENT_ID" =~ ^[a-z0-9-]{1,16}$ ]]; then
  echo "ERROR: --student-id must be lowercase letters, digits, or dashes; 1-16 chars." >&2
  echo "Got: '$STUDENT_ID'" >&2
  exit 2
fi

PROFILE_ARG=()
[[ -n "$PROFILE" ]] && PROFILE_ARG=(--profile "$PROFILE")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/lab_environment/lab_env_student"
STATE_KEY="lab_env_student/${STUDENT_ID}.tfstate"
# BUCKET is set below, after we resolve the account ID (see "AWS auth"). Each
# student gets their OWN state bucket, prefixed with their student_id and made
# globally unique by the account ID -- S3 bucket names are global across ALL AWS
# accounts, so a shared "io107-tfstate-<region>" name collides between students.

echo "================================================================"
echo "IO-107 bootstrap"
echo "  course_id:  $COURSE_ID"
echo "  region:     $REGION"
echo "  student_id: $STUDENT_ID"
echo "  profile:    ${PROFILE:-default}"
echo "  apply?      $([ $DO_APPLY -eq 1 ] && echo yes || echo no)"
echo "  tf dir:     $TF_DIR"
echo "================================================================"
echo ""

# --- Prereqs ---
echo "==> Checking prerequisites..."
for bin in aws terraform git jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' not on PATH. Install it and re-run." >&2
    exit 1
  fi
done
echo "    aws       $(aws --version 2>&1 | head -1)"
echo "    terraform $(terraform version | head -1)"
echo "    git       $(git --version)"
echo "    jq        $(jq --version)"
echo ""

if [[ ! -d "$TF_DIR" ]]; then
  echo "ERROR: $TF_DIR does not exist. Are you running this from inside an io-107 clone?" >&2
  exit 1
fi

# --- AWS auth ---
echo "==> Confirming AWS credentials..."
CALLER=$(aws "${PROFILE_ARG[@]}" sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: AWS credentials not configured. Set AWS_PROFILE or run aws configure." >&2
  echo "$CALLER" >&2
  exit 1
}
ACCOUNT_ID=$(echo "$CALLER" | jq -r '.Account')
ARN=$(echo "$CALLER" | jq -r '.Arn')
echo "    Account: $ACCOUNT_ID"
echo "    Identity: $ARN"
echo ""

# Per-student state bucket: prefixed with student_id, made globally unique by
# the account ID. All students can share one AWS account (each their own IAM
# user) and still get a non-colliding, individually-owned state bucket.
BUCKET="${COURSE_ID}-${STUDENT_ID}-tfstate-${ACCOUNT_ID}"
echo "    State bucket: s3://$BUCKET"
echo ""

# --- State bucket ---
echo "==> Ensuring S3 state bucket s3://$BUCKET ..."
if aws "${PROFILE_ARG[@]}" s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "    Bucket already exists, skipping create."
else
  aws "${PROFILE_ARG[@]}" s3 mb "s3://$BUCKET" --region "$REGION"
  aws "${PROFILE_ARG[@]}" s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --versioning-configuration Status=Enabled
  aws "${PROFILE_ARG[@]}" s3api put-public-access-block \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws "${PROFILE_ARG[@]}" s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  echo "    Created with versioning + public-access-block + AES256 encryption."
fi
echo ""

# --- backend.tf ---
BACKEND_TF="$TF_DIR/backend.tf"
echo "==> Writing $BACKEND_TF ..."
cat > "$BACKEND_TF" <<EOF
# Auto-generated by instructor/bootstrap.sh. Safe to regenerate by re-running
# the script. Do not hand-edit -- changes are overwritten.
#
# State key includes student_id so multiple students can share the same bucket
# without colliding. Native S3 locking (Terraform 1.10+) -- no DynamoDB table.

terraform {
  backend "s3" {
    bucket       = "$BUCKET"
    key          = "$STATE_KEY"
    region       = "$REGION"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
echo "    Written (state key: $STATE_KEY)."
echo ""

# --- terraform.tfvars ---
# (No CodeStar / GitHub OAuth step. In student mode the per-lab pipelines read
# from per-student CodeCommit repos that this module creates. GitHub is only
# touched once during `terraform apply` -- the null_resource seed clones the
# public monorepo to seed each CodeCommit -- no auth required.)
TFVARS="$TF_DIR/terraform.tfvars"
if [[ -f "$TFVARS" && $FORCE_TFVARS -ne 1 ]]; then
  echo "==> $TFVARS already exists, keeping. Add --force-tfvars to overwrite."
else
  echo "==> Writing $TFVARS ..."
  cat > "$TFVARS" <<EOF
# Auto-generated by instructor/bootstrap.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Re-run with --force-tfvars to regenerate.

aws_region = "$REGION"
student_id = "$STUDENT_ID"
EOF
  echo "    Written."
fi
echo ""

# --- Apply (optional) ---
if [[ $DO_APPLY -eq 1 ]]; then
  echo "==> Running terraform init + apply..."
  cd "$TF_DIR"
  terraform init -input=false
  terraform plan -input=false -out=tfplan
  terraform apply -input=false tfplan
  echo ""
  echo "==> Capturing outputs to $TF_DIR/outputs.json..."
  terraform output -json > outputs.json
  echo ""
  echo "Apply complete. Per-student resources provisioned."
  echo ""
  echo "Key outputs:"
  terraform output -json | jq -r 'to_entries[] | select(.value.value != "(disabled)") | "  \(.key): \(.value.value)"' | head -20
else
  echo "Bootstrap complete. Ready to apply."
  echo ""
  echo "Next steps:"
  echo "  cd $TF_DIR"
  echo "  terraform init"
  echo "  terraform plan -out=tfplan"
  echo "  terraform apply tfplan      # ~15 min for EKS"
  echo ""
  echo "Or re-run this script with --apply to do all three automatically."
fi

#!/usr/bin/env bash
###############################################################################
# IO-107 — COMPLETE teardown for a student who has COMPLETED labs 3 and 4.
#
# The §8 sequence is NOT enough once the Lab 3 and Lab 4 Deploy stages have
# actually run. Two extra classes of leftover exist, both confirmed on user50
# (suffix e2ecbd) on 2026-08-11:
#
#   A. Lab 3's Deploy runs its own `terraform apply` whose BACKEND LIVES INSIDE
#      the lab3 artifact bucket (s3://<...>-lab3-artifacts/lab3/terraform.tfstate).
#      `terraform destroy` of lab_env_student deletes that bucket -- and the
#      state file with it -- stranding an S3 bucket, a Lambda and an IAM role
#      with nothing left to destroy them from.
#      => Destroy the lab3 stack FIRST, while its state still exists.
#
#   B. Lab 4's Blue/Green switchover renames the ORIGINAL cluster to
#      `<name>-old1` and promotes the green one into the original name.
#      lab_env_student state tracks `<name>`, so `terraform destroy` removes the
#      NEW cluster and leaves `<name>-old1` running and BILLING (~$50+/month
#      per student).
#      => Delete the blue/green record and the -old1 cluster explicitly.
#
# Usage: ./teardown_complete.sh user50 us-east-1
###############################################################################
set -uo pipefail

STUDENT="${1:?usage: teardown_complete.sh <student-id> <region>}"
REGION="${2:?usage: teardown_complete.sh <student-id> <region>}"
export AWS_PROFILE="${AWS_PROFILE:-io107}"
export MSYS_NO_PATHCONV=1
export GCM_INTERACTIVE=never
export GIT_TERMINAL_PROMPT=0

# Resolved from this script's own location so the toolkit works from any clone.
# REPO  = the io-107 checkout (this file lives at instructor/cohort/ inside it).
# HERE  = the ops directory holding cohort/, .tfplugincache and the run logs;
#         defaults to the checkout's parent. Override either if your layout
#         differs.
REPO="${IO107_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HERE="${IO107_OPS_DIR:-$(cd "$REPO/.." && pwd)}"
ACCOUNT_ID="${IO107_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
TF_DIR="$REPO/lab_environment/lab_env_student"
LAB3_SRC="$REPO/lab_3/terraform"

# cygpath: Git Bash paths are unreadable by Windows python -- see §10 bug.
OUT=$(cygpath -m "$TF_DIR/outputs-$STUDENT.json" 2>/dev/null || echo "$TF_DIR/outputs-$STUDENT.json")
get(){ python -c "import json;print(json.load(open(r'$OUT'))['$1']['value'])" 2>/dev/null; }
CLUSTER=$(get eks_cluster_name)
NS=$(get lab1_namespace)
LAB3_BUCKET=$(get lab3_artifact_bucket)
AURORA=$(get lab4_aurora_cluster_id)
SUFFIX=$(echo "$CLUSTER" | sed -E "s/^io107-$STUDENT-(.+)-eks$/\1/")

if [ -z "$CLUSTER" ] || [ -z "$SUFFIX" ] || [ "$SUFFIX" = "$CLUSTER" ]; then
  echo "ERROR: could not derive names for $STUDENT from $OUT" >&2; exit 1
fi
echo "student=$STUDENT suffix=$SUFFIX cluster=$CLUSTER aurora=$AURORA"

# --- A. Lab 3's own Terraform stack (MUST be before the main destroy) --------
echo ""; echo "=== A. lab3 pipeline-created stack ==="
if aws s3 ls "s3://$LAB3_BUCKET/lab3/terraform.tfstate" >/dev/null 2>&1; then
  W=$(mktemp -d); cp -r "$LAB3_SRC"/* "$W"/ 2>/dev/null
  mkdir -p "$W/../src" && cp -r "$REPO/lab_3/src"/* "$W/../src"/ 2>/dev/null
  ( cd "$W" \
    && terraform init -input=false -reconfigure \
         -backend-config="bucket=$LAB3_BUCKET" \
         -backend-config="region=$REGION" >/dev/null 2>&1 \
    && terraform destroy -auto-approve -input=false -no-color 2>&1 | tail -3 )
  rm -rf "$W"
else
  echo "  no lab3 state at s3://$LAB3_BUCKET/lab3/terraform.tfstate (Deploy never ran)"
fi

# --- B. Aurora Blue/Green leftovers -----------------------------------------
echo ""; echo "=== B. Aurora blue/green leftovers ==="
for BG in $(aws rds describe-blue-green-deployments --region "$REGION" \
            --query "BlueGreenDeployments[?contains(BlueGreenDeploymentName,'$SUFFIX')].BlueGreenDeploymentIdentifier" \
            --output text 2>/dev/null | tr '\t' '\n'); do
  echo "  deleting blue/green record $BG"
  aws rds delete-blue-green-deployment --region "$REGION" \
      --blue-green-deployment-identifier "$BG" >/dev/null 2>&1 \
    && echo "    ok" || echo "    (already gone)"
done

# The switchover leaves the ORIGINAL cluster renamed to <name>-oldN.
for OLD in $(aws rds describe-db-clusters --region "$REGION" \
             --query "DBClusters[?contains(DBClusterIdentifier,'$SUFFIX') && contains(DBClusterIdentifier,'-old')].DBClusterIdentifier" \
             --output text 2>/dev/null | tr '\t' '\n'); do
  echo "  orphaned cluster: $OLD"
  for INST in $(aws rds describe-db-instances --region "$REGION" \
                --query "DBInstances[?DBClusterIdentifier=='$OLD'].DBInstanceIdentifier" \
                --output text 2>/dev/null | tr '\t' '\n'); do
    echo "    deleting instance $INST"
    aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$INST" \
        --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1
    aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$INST" 2>&1 | tail -1
  done
  echo "    deleting cluster $OLD"
  aws rds delete-db-cluster --region "$REGION" --db-cluster-identifier "$OLD" \
      --skip-final-snapshot >/dev/null 2>&1
  aws rds wait db-cluster-deleted --region "$REGION" --db-cluster-identifier "$OLD" 2>&1 | tail -1
  echo "    $OLD deleted"
done

# --- C. in-cluster LoadBalancer (belt and braces; vpc_lb_cleanup also does it)
echo ""; echo "=== C. helm LoadBalancer ==="
if aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  helm uninstall myapp -n "$NS" 2>&1 | tail -1 || true
  kubectl delete namespace lab3 --ignore-not-found --timeout=60s 2>&1 | tail -1 || true
else
  echo "  cluster unreachable, skipping"
fi

# --- D. pipeline-created SAM stack (discover, do not trust a built name) -----
echo ""; echo "=== D. lab2 SAM stack ==="
STACK=$(aws cloudformation list-stacks --region "$REGION" \
          --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
          --query "StackSummaries[?starts_with(StackName,'io107-$STUDENT-')].StackName | [0]" \
          --output text 2>/dev/null)
if [ -n "$STACK" ] && [ "$STACK" != "None" ]; then
  echo "  deleting $STACK"
  aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK" 2>&1 | tail -1
  echo "  done"
else
  echo "  none found"
fi

# --- E. main stack ------------------------------------------------------------
echo ""; echo "=== E. terraform destroy (lab_env_student) ==="
"$REPO/instructor/bootstrap.sh" --student-id "$STUDENT" --region "$REGION" \
    --profile "$AWS_PROFILE" --force-tfvars >/dev/null 2>&1
cat >> "$TF_DIR/terraform.tfvars" <<EOF

apply_host_principal_arn = "arn:aws:iam::${ACCOUNT_ID}:user/$STUDENT"
EOF
cd "$TF_DIR"
terraform init -input=false -reconfigure >/dev/null 2>&1
terraform destroy -auto-approve -input=false -no-color 2>&1 | tee "destroy-$STUDENT.log" | tail -3

# --- F. orphaned log groups ---------------------------------------------------
echo ""; echo "=== F. log groups ==="
for LG in $(aws logs describe-log-groups --region "$REGION" \
            --query "logGroups[?contains(logGroupName,'io107-$STUDENT-$SUFFIX')].logGroupName" \
            --output text 2>/dev/null | tr '\t' '\n'); do
  aws logs delete-log-group --region "$REGION" --log-group-name "$LG" 2>/dev/null \
    && echo "  deleted $LG"
done

echo ""; echo "=== teardown_complete done for $STUDENT ==="

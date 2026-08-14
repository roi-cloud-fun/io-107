#!/usr/bin/env bash
###############################################################################
# IO-107 -- make EKS worker nodes identifiable per student.
#
# The node group already carries good tags from Terraform (StudentId, RunSuffix,
# Course...), but **EKS does not propagate node-group tags to the Auto Scaling
# Group or to the EC2 instances**. The instances only get the eks:* / k8s.io/*
# tags AWS injects, and no Name at all -- so the console shows a blank Name for
# every worker and you cannot tell whose is whose.
#
# This fixes both halves:
#   1. tags the instances that exist RIGHT NOW (immediate, no restart)
#   2. adds the same tags to the ASG with PropagateAtLaunch=true, so any node
#      launched later -- a scale-up, or a replacement after a failure -- is born
#      with them. Without this, step 1 is undone the next time nodes cycle.
#
# Safe to re-run; tagging is idempotent and never restarts or replaces a node.
#
# Usage:
#   ./tag_nodes.sh              # all clusters, both regions
#   ./tag_nodes.sh user04       # one student
#   DRY_RUN=1 ./tag_nodes.sh    # show what would change
###############################################################################
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-io107}"
export MSYS_NO_PATHCONV=1
REGIONS="${IO107_REGIONS:-us-east-1 us-east-2}"
FILTER="${1:-}"
DRY="${DRY_RUN:-}"

run(){ if [ -n "$DRY" ]; then echo "      DRY: $*"; else "$@"; fi; }

for R in $REGIONS; do
  echo "########## $R ##########"
  for C in $(aws eks list-clusters --region "$R" --query 'clusters[]' --output text 2>/dev/null); do
    [ -n "$FILTER" ] && case "$C" in *"$FILTER"*) ;; *) continue ;; esac

    # io107-user50-cbb2ad-eks -> user50
    STUDENT=$(echo "$C" | sed -E 's/^io107-([^-]+)-.*/\1/')

    for N in $(aws eks list-nodegroups --region "$R" --cluster-name "$C" --query 'nodegroups[]' --output text 2>/dev/null); do
      ASG=$(aws eks describe-nodegroup --region "$R" --cluster-name "$C" --nodegroup-name "$N" \
        --query 'nodegroup.resources.autoScalingGroups[0].name' --output text 2>/dev/null)
      [ -z "$ASG" ] || [ "$ASG" = None ] && { echo "  $N: no ASG found, skipping"; continue; }

      NAME="io107-${STUDENT}-eks-node"
      echo "  $STUDENT -> $NAME  (asg $ASG)"

      # --- 1. future nodes: tag the ASG so launches inherit -----------------
      run aws autoscaling create-or-update-tags --region "$R" --tags \
        "ResourceId=$ASG,ResourceType=auto-scaling-group,Key=Name,Value=$NAME,PropagateAtLaunch=true" \
        "ResourceId=$ASG,ResourceType=auto-scaling-group,Key=Student,Value=$STUDENT,PropagateAtLaunch=true" \
        "ResourceId=$ASG,ResourceType=auto-scaling-group,Key=Cluster,Value=$C,PropagateAtLaunch=true" \
        "ResourceId=$ASG,ResourceType=auto-scaling-group,Key=Purpose,Value=io107-eks-worker,PropagateAtLaunch=true"

      # --- 2. nodes that already exist: PropagateAtLaunch is launch-time
      #        only, so running instances need tagging directly ---------------
      IDS=$(aws ec2 describe-instances --region "$R" \
        --filters "Name=tag:eks:nodegroup-name,Values=$N" "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
      if [ -z "$IDS" ]; then
        echo "      (no running nodes right now -- ASG tags will cover the next launch)"
      else
        echo "      tagging $(echo "$IDS" | wc -w) running node(s)"
        # shellcheck disable=SC2086
        run aws ec2 create-tags --region "$R" --resources $IDS --tags \
          "Key=Name,Value=$NAME" \
          "Key=Student,Value=$STUDENT" \
          "Key=Cluster,Value=$C" \
          "Key=Purpose,Value=io107-eks-worker"
      fi
    done
  done
done

echo
echo "Done. Terraform should own this going forward -- see"
echo "lab_environment/lab_env_student/main.tf (aws_autoscaling_group_tag)."

#!/usr/bin/env bash
###############################################################################
# IO-107 -- turn the whole cohort's billable compute off and on.
#
# Between sessions there is no reason to pay for idle compute. This stops and
# starts the two things that can be stopped without destroying anything:
#
#   - student workstations (EC2, tagged Purpose=io107-student-workstation)
#   - Lab 4 Aurora clusters
#
# What it deliberately does NOT touch:
#   - EKS control planes  -- cannot be stopped; $0.10/hr each is the price of
#                            keeping the clusters (destroying them means a
#                            ~15 min rebuild and new names in every handout).
#   - EKS worker nodes    -- stopping them fights the node group, which just
#                            replaces them. Scale the node group to 0 instead if
#                            you really need to (and expect pods to churn).
#
# Usage:
#   ./power.sh status
#   ./power.sh stop          # end of a session
#   ./power.sh start         # ~15 min before the next one (Aurora is slow)
#   ./power.sh stop  workstations   # just one class of resource
#   ./power.sh start aurora
#
# Env: AWS_PROFILE (default io107), IO107_REGIONS (default both cohort regions)
###############################################################################
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-io107}"
export MSYS_NO_PATHCONV=1   # Git Bash mangles ARNs/paths passed to aws.exe
REGIONS="${IO107_REGIONS:-us-east-1 us-east-2}"

ACTION="${1:-status}"
SCOPE="${2:-all}"

ws_ids(){ # $1 = region, $2 = comma-separated states
  aws ec2 describe-instances --region "$1" \
    --filters "Name=tag:Purpose,Values=io107-student-workstation" \
              "Name=instance-state-name,Values=$2" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null
}

aurora_ids(){ # $1 = region, $2 = status
  aws rds describe-db-clusters --region "$1" \
    --query "DBClusters[?Status=='$2'].DBClusterIdentifier" --output text 2>/dev/null
}

do_status(){
  for R in $REGIONS; do
    echo "########## $R ##########"
    echo "-- workstations --"
    aws ec2 describe-instances --region "$R" \
      --filters "Name=tag:Purpose,Values=io107-student-workstation" \
      --query 'Reservations[].Instances[].[Tags[?Key==`Student`]|[0].Value,InstanceId,State.Name,PublicIpAddress]' \
      --output text 2>/dev/null | sort | sed 's/^/   /'
    echo "-- aurora --"
    aws rds describe-db-clusters --region "$R" \
      --query 'DBClusters[].[DBClusterIdentifier,Status]' --output text 2>/dev/null | sed 's/^/   /'
    echo "-- eks (always on; cannot be stopped) --"
    aws eks list-clusters --region "$R" --query 'clusters|length(@)' --output text 2>/dev/null | sed 's/^/   clusters: /'
  done
}

do_workstations(){ # $1 = stop|start
  for R in $REGIONS; do
    if [ "$1" = stop ]; then IDS=$(ws_ids "$R" running,pending); else IDS=$(ws_ids "$R" stopped); fi
    if [ -z "$IDS" ]; then echo "  $R: no workstations to $1"; continue; fi
    echo "  $R: ${1}ping $(echo "$IDS" | wc -w) workstation(s)"
    # shellcheck disable=SC2086
    aws ec2 "${1}-instances" --region "$R" --instance-ids $IDS \
      --query "StoppingInstances[].InstanceId || StartingInstances[].InstanceId" --output text 2>&1 | sed 's/^/     /'
  done
}

do_aurora(){ # $1 = stop|start
  for R in $REGIONS; do
    if [ "$1" = stop ]; then WANT=available; else WANT=stopped; fi
    IDS=$(aurora_ids "$R" "$WANT")
    if [ -z "$IDS" ]; then echo "  $R: no Aurora clusters to $1"; continue; fi
    for C in $IDS; do
      printf "  %s: %sping %-42s " "$R" "$1" "$C"
      aws rds "${1}-db-cluster" --region "$R" --db-cluster-identifier "$C" \
        --query 'DBCluster.Status' --output text 2>&1
    done
  done
}

case "$ACTION" in
  status) do_status ;;
  stop|start)
    case "$SCOPE" in
      all)          do_workstations "$ACTION"; do_aurora "$ACTION" ;;
      workstations) do_workstations "$ACTION" ;;
      aurora)       do_aurora "$ACTION" ;;
      *) echo "unknown scope: $SCOPE (all|workstations|aurora)" >&2; exit 2 ;;
    esac
    echo
    echo "Note: state changes take a few minutes. Re-run './power.sh status' to confirm."
    [ "$ACTION" = stop ] && cat <<'EOT'

Reminders:
  - AWS auto-STARTS a stopped Aurora cluster after 7 days. For a longer gap,
    tear the environments down instead (teardown_complete.sh).
  - Stopped instances still bill for their EBS volumes, and Aurora still bills
    for storage and backups. Stopping saves compute, not everything.
EOT
    ;;
  *) echo "usage: $0 {status|stop|start} [all|workstations|aurora]" >&2; exit 2 ;;
esac

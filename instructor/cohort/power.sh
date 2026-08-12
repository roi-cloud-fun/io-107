#!/usr/bin/env bash
###############################################################################
# IO-107 -- turn the whole cohort's billable compute off and on.
#
# Between sessions there is no reason to pay for idle compute. This stops and
# starts the two things that can be stopped without destroying anything:
#
#   - student workstations (EC2, tagged Purpose=io107-student-workstation)
#   - Lab 4 Aurora clusters
#   - EKS worker nodes, by scaling the managed node group to zero
#
# Note on worker nodes: do NOT stop the instances directly -- the node group
# treats a stopped node as unhealthy and replaces it, so you pay for the
# replacement. Scaling the node group to desiredSize=0 (and minSize=0, which the
# API allows even though our Terraform pins min_size=1) is the supported way,
# and the node group stays ACTIVE throughout. Original sizes are saved to
# nodegroup-scale.json so `start` restores exactly what was there.
#
# What it deliberately does NOT touch:
#   - EKS control planes -- cannot be stopped; $0.10/hr each is the price of
#                           keeping the clusters (destroying them means a
#                           ~15 min rebuild and new names in every handout).
#   - The lab1 Classic LoadBalancers -- one per student, created by the lab1
#                           helm release. They keep billing (~$0.025/hr each)
#                           and survive a node scale-down with no targets. The
#                           only way to remove them is `helm uninstall myapp`,
#                           which throws away lab1's deployed state.
#
# Usage:
#   ./power.sh status
#   ./power.sh stop          # end of a session (workstations + aurora + nodes)
#   ./power.sh start         # ~15 min before the next one (Aurora is slow)
#   ./power.sh stop  workstations   # just one class of resource
#   ./power.sh start nodes
#
# Env: AWS_PROFILE (default io107), IO107_REGIONS (default both cohort regions),
#      IO107_NODE_MIN / IO107_NODE_DESIRED (fallback restore sizes, default 1/2)
###############################################################################
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-io107}"
export MSYS_NO_PATHCONV=1   # Git Bash mangles ARNs/paths passed to aws.exe
REGIONS="${IO107_REGIONS:-us-east-1 us-east-2}"

ACTION="${1:-status}"
SCOPE="${2:-all}"
# Optional 3rd arg: only act on resources whose name contains this string,
# e.g. `./power.sh start nodes user50` to wake one student's cluster.
FILTER="${3:-}"

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

# Where the pre-scale-down node group sizes are remembered, so `start` restores
# exactly what was there rather than guessing.
SCALE_FILE="${IO107_SCALE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/nodegroup-scale.json}"

# jq here is the WINDOWS build, and we export MSYS_NO_PATHCONV=1 above (needed so
# ARNs and log-group names survive being passed to aws.exe). That combination
# means jq cannot open an MSYS-style /c/Users/... path -- it fails with "No such
# file", and a `// empty` fallback would silently restore DEFAULT node counts
# instead of the saved ones. Convert explicitly for jq.
jq_path(){ cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

nodegroups(){ # $1 = region -> "cluster<TAB>nodegroup" per line, honouring $FILTER
  for C in $(aws eks list-clusters --region "$1" --query 'clusters[]' --output text 2>/dev/null); do
    [ -n "${FILTER:-}" ] && case "$C" in *"$FILTER"*) ;; *) continue ;; esac
    for N in $(aws eks list-nodegroups --region "$1" --cluster-name "$C" --query 'nodegroups[]' --output text 2>/dev/null); do
      printf '%s\t%s\n' "$C" "$N"
    done
  done
}

do_nodes_stop(){
  local tmp; tmp=$(mktemp)
  echo "{" > "$tmp"; local first=1
  for R in $REGIONS; do
    while IFS=$'\t' read -r C N; do
      [ -z "$N" ] && continue
      read -r MIN DES MAX <<<"$(aws eks describe-nodegroup --region "$R" --cluster-name "$C" --nodegroup-name "$N" \
        --query 'nodegroup.scalingConfig.[minSize,desiredSize,maxSize]' --output text 2>/dev/null)"
      [ -z "${MAX:-}" ] && { echo "  $R/$N: could not read scaling config, skipping"; continue; }
      if [ "${DES:-0}" = "0" ] && [ "${MIN:-0}" = "0" ]; then
        echo "  $R/$N: already at zero"
      else
        printf "  %s/%-32s %s/%s/%s -> 0/0/%s " "$R" "$N" "$MIN" "$DES" "$MAX" "$MAX"
        aws eks update-nodegroup-config --region "$R" --cluster-name "$C" --nodegroup-name "$N" \
          --scaling-config "minSize=0,maxSize=$MAX,desiredSize=0" \
          --query 'update.status' --output text 2>&1
      fi
      # Remember the ORIGINAL sizes -- but never overwrite a saved non-zero
      # entry with the zeros we just wrote, or a second `stop` would destroy the
      # only record of how to get back.
      if [ "${MIN:-0}" != "0" ] || [ "${DES:-0}" != "0" ]; then
        [ $first -eq 0 ] && echo "," >> "$tmp"; first=0
        printf '  "%s/%s/%s": {"min": %s, "desired": %s, "max": %s}' "$R" "$C" "$N" "$MIN" "$DES" "$MAX" >> "$tmp"
      fi
    done <<< "$(nodegroups "$R")"
  done
  echo "" >> "$tmp"; echo "}" >> "$tmp"
  if [ "$first" -eq 0 ]; then
    # MERGE, never replace. A filtered run (`stop nodes user50`) only iterates
    # that student's node group, so writing the file wholesale would delete the
    # saved sizes for everyone else and silently downgrade their restore to
    # defaults.
    if [ -f "$SCALE_FILE" ]; then
      if jq -s '.[0] * .[1]' "$(jq_path "$SCALE_FILE")" "$(jq_path "$tmp")" > "$tmp.merged" 2>/dev/null \
         && [ -s "$tmp.merged" ]; then
        mv "$tmp.merged" "$SCALE_FILE"; rm -f "$tmp"
      else
        echo "  WARNING: could not merge into $SCALE_FILE -- leaving it untouched." >&2
        echo "           New sizes are in $tmp ; merge by hand before relying on start." >&2
        return 1
      fi
    else
      mv "$tmp" "$SCALE_FILE"
    fi
    echo "  saved original sizes -> $SCALE_FILE ($(jq 'length' "$(jq_path "$SCALE_FILE")" 2>/dev/null) entries)"
  else
    rm -f "$tmp"
    [ -f "$SCALE_FILE" ] && echo "  (nothing new to save; kept existing $SCALE_FILE)"
  fi
}

do_nodes_start(){
  local DMIN="${IO107_NODE_MIN:-1}" DDES="${IO107_NODE_DESIRED:-2}"
  [ -f "$SCALE_FILE" ] || echo "  no $SCALE_FILE -- restoring defaults min=$DMIN desired=$DDES"
  for R in $REGIONS; do
    while IFS=$'\t' read -r C N; do
      [ -z "$N" ] && continue
      MIN=""; DES=""; MAX=""
      if [ -f "$SCALE_FILE" ]; then
        read -r MIN DES MAX <<<"$(jq -r --arg k "$R/$C/$N" '.[$k] // empty | "\(.min) \(.desired) \(.max)"' "$(jq_path "$SCALE_FILE")" 2>/dev/null)"
        if [ -z "${MIN:-}" ]; then
          echo "  NOTE: $N not found in $(basename "$SCALE_FILE") -- using defaults"
        fi
      fi
      if [ -z "${MIN:-}" ] || [ "$MIN" = "null" ]; then
        MIN="$DMIN"; DES="$DDES"
        MAX=$(aws eks describe-nodegroup --region "$R" --cluster-name "$C" --nodegroup-name "$N" \
          --query 'nodegroup.scalingConfig.maxSize' --output text 2>/dev/null)
        [ -z "${MAX:-}" ] && MAX=$((DES + 2))
      fi
      CUR=$(aws eks describe-nodegroup --region "$R" --cluster-name "$C" --nodegroup-name "$N" \
        --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null)
      if [ "${CUR:-0}" = "$DES" ]; then echo "  $R/$N: already at $DES"; continue; fi
      printf "  %s/%-32s -> %s/%s/%s " "$R" "$N" "$MIN" "$DES" "$MAX"
      aws eks update-nodegroup-config --region "$R" --cluster-name "$C" --nodegroup-name "$N" \
        --scaling-config "minSize=$MIN,maxSize=$MAX,desiredSize=$DES" \
        --query 'update.status' --output text 2>&1
    done <<< "$(nodegroups "$R")"
  done
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
    echo "-- eks node groups (control planes always on; cannot be stopped) --"
    while IFS=$'\t' read -r C N; do
      [ -z "$N" ] && continue
      read -r ST MIN DES MAX <<<"$(aws eks describe-nodegroup --region "$R" --cluster-name "$C" --nodegroup-name "$N" \
        --query 'nodegroup.[status,scalingConfig.minSize,scalingConfig.desiredSize,scalingConfig.maxSize]' --output text 2>/dev/null)"
      LIVE=$(aws ec2 describe-instances --region "$R" \
        --filters "Name=tag:eks:nodegroup-name,Values=$N" "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[].Instances[]|length(@)' --output text 2>/dev/null)
      printf "   %-34s %-9s min/des/max=%s/%s/%s  live=%s\n" "$N" "$ST" "$MIN" "$DES" "$MAX" "${LIVE:-?}"
    done <<< "$(nodegroups "$R")"
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
      all)          do_workstations "$ACTION"; do_aurora "$ACTION"
                    [ "$ACTION" = stop ] && do_nodes_stop || do_nodes_start ;;
      workstations) do_workstations "$ACTION" ;;
      aurora)       do_aurora "$ACTION" ;;
      nodes)        [ "$ACTION" = stop ] && do_nodes_stop || do_nodes_start ;;
      *) echo "unknown scope: $SCOPE (all|workstations|aurora|nodes)" >&2; exit 2 ;;
    esac
    echo
    echo "Note: state changes take a few minutes. Re-run './power.sh status' to confirm."
    [ "$ACTION" = stop ] && cat <<'EOT'

Reminders:
  - AWS auto-STARTS a stopped Aurora cluster after 7 days. For a longer gap,
    tear the environments down instead (teardown_complete.sh).
  - Stopped instances still bill for their EBS volumes, and Aurora still bills
    for storage and backups. Stopping saves compute, not everything.
  - Node groups at zero mean NO pods run: the lab1 myapp release goes Pending
    and its LoadBalancer has no targets until you scale back up.
  - Still billing after all this: 8 EKS control planes and 8 lab1 Classic LBs.
EOT
    [ "$ACTION" = start ] && cat <<'EOT'

Give it time before class:
  - Nodes take ~2-3 min to join, then pods reschedule on their own.
  - Aurora is the slow one -- allow ~10-15 min.
  - Check with './power.sh status' until node groups show live=desired.
EOT
    ;;
  *) echo "usage: $0 {status|stop|start} [all|workstations|aurora]" >&2; exit 2 ;;
esac

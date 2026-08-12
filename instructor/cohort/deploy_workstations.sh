#!/usr/bin/env bash
###############################################################################
# IO-107 -- build (or destroy) the student management workstations.
#
# Wraps instructor/workstations/ and applies it ONCE PER REGION, because the
# cohort is split and a student's workstation must sit in the same region as
# their cluster.
#
# The module is copied into the ops directory before running, for the same
# reason deploy_cohort_parallel.sh does it: each region needs its own state and
# .terraform, and neither belongs in the git checkout.
#
# Usage:
#   ./deploy_workstations.sh apply
#   ./deploy_workstations.sh plan
#   ./deploy_workstations.sh destroy          # end of course
#   ./deploy_workstations.sh apply us-east-2  # one region
#
# State: S3, in the instructor's own tfstate bucket, key workstations/<region>.
###############################################################################
set -uo pipefail

REPO="${IO107_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HERE="${IO107_OPS_DIR:-$(cd "$REPO/.." && pwd)}"
SRC="$REPO/instructor/workstations"

export AWS_PROFILE="${AWS_PROFILE:-io107}"
export MSYS_NO_PATHCONV=1
export TF_PLUGIN_CACHE_DIR="$HERE/.tfplugincache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

ACCOUNT_ID="${IO107_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

# Which students are in which region -- keep in step with deploy_cohort_parallel.sh.
US_EAST_1="${IO107_USE1_STUDENTS:-user50 user01 user02 user03}"
US_EAST_2="${IO107_USE2_STUDENTS:-user04 user05 user06 user07}"

# State bucket: reuse the instructor's own per-student bucket rather than
# inventing another one. It already exists and is versioned.
STATE_BUCKET="${IO107_STATE_BUCKET:-io107-${IO107_INSTRUCTOR_ID:-user50}-tfstate-${ACCOUNT_ID}}"
STATE_REGION="${IO107_STATE_REGION:-us-east-1}"

ACTION="${1:-plan}"
case "$ACTION" in plan|apply|destroy) ;; *) echo "usage: $0 {plan|apply|destroy} [region]" >&2; exit 2 ;; esac
REGIONS="${2:-us-east-1 us-east-2}"

tf_list(){ printf '["%s"]' "$(echo "$1" | sed 's/ /","/g')"; }

for R in $REGIONS; do
  case "$R" in
    us-east-1) STUDENTS="$US_EAST_1" ;;
    us-east-2) STUDENTS="$US_EAST_2" ;;
    *) echo "no student list for region $R -- set IO107_USE1_STUDENTS/IO107_USE2_STUDENTS" >&2; continue ;;
  esac

  D="$HERE/workstations/$R"
  mkdir -p "$D"
  cp "$SRC"/*.tf "$SRC"/*.tftpl "$D"/ 2>/dev/null

  cat > "$D/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket       = "$STATE_BUCKET"
    key          = "workstations/$R.tfstate"
    region       = "$STATE_REGION"
    encrypt      = true
    use_lockfile = true
  }
}
EOF

  echo "==================== $R : $ACTION ===================="
  echo "  students: $STUDENTS"
  ( cd "$D" \
    && terraform init -input=false -no-color >/dev/null 2>&1 \
    && terraform "$ACTION" -input=false -no-color \
         $([ "$ACTION" != plan ] && echo -auto-approve) \
         -var "aws_region=$R" \
         -var "students=$(tf_list "$STUDENTS")" \
       2>&1 | tail -25 )

  if [ "$ACTION" = apply ]; then
    ( cd "$D" && terraform output -json > "$HERE/workstations-$R.json" 2>/dev/null ) \
      && echo "  outputs -> $HERE/workstations-$R.json"
  fi
done

echo
[ "$ACTION" = apply ] && cat <<'EOT'
Workstations are booting. cloud-init installs the toolchain (~3-5 min) and
touches /var/lib/io107-setup-complete when it is done.

  ./power.sh status      # see them
  ./power.sh stop        # park them until class (they bill while running)
EOT

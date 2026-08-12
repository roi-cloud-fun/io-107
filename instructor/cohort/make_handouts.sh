#!/usr/bin/env bash
###############################################################################
# IO-107 -- generate a one-page handout per student from their terraform
# outputs, so nobody has to fill in a placeholder by hand.
#
# STUDENT_SETUP.md deliberately ships with invalid placeholders (`userXX`,
# `REGION`) so it fails fast rather than defaulting everyone into one region.
# That is right for the doc and wrong for the classroom -- hand each student
# their own copy of the two lines they need and the mistakes go away.
#
# Handouts contain account-specific values (account id, cluster endpoints,
# CodeCommit URLs), so they are written to the OPS directory, OUTSIDE the git
# checkout. Do not commit them.
#
# Usage:
#   ./make_handouts.sh                    # everyone with an outputs-*.json
#   ./make_handouts.sh user04 user05      # subset
###############################################################################
set -uo pipefail

REPO="${IO107_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HERE="${IO107_OPS_DIR:-$(cd "$REPO/.." && pwd)}"
OUT="$HERE/handouts"
mkdir -p "$OUT"

if [ $# -gt 0 ]; then
  STUDENTS=("$@")
else
  STUDENTS=()
  for f in "$HERE"/outputs-*.json; do
    [ -e "$f" ] || continue
    s=$(basename "$f"); s=${s#outputs-}; s=${s%.json}
    STUDENTS+=("$s")
  done
fi
[ ${#STUDENTS[@]} -eq 0 ] && { echo "no outputs-*.json found in $HERE" >&2; exit 2; }

get(){ jq -r --arg k "$1" '.[$k].value // empty' "$J"; }

for S in "${STUDENTS[@]}"; do
  J="$HERE/outputs-$S.json"
  [ -f "$J" ] || { echo "  skip $S (no $J)" >&2; continue; }

  REGION=$(get aws_region)
  CLUSTER=$(get eks_cluster_name)
  [ -n "$CLUSTER" ] || { echo "  skip $S (outputs look empty)" >&2; continue; }

  {
    echo "# IO-107 — your lab environment ($S)"
    echo
    echo "Your environment is **already deployed**. You are connecting to it, not"
    echo "building it. Work through \`STUDENT_SETUP.md\`; this page gives you the"
    echo "values to paste in."
    echo
    echo '> 🛑 Never run `terraform apply` or `terraform destroy` in'
    echo '> `lab_environment/lab_env_student/`. It would delete your environment.'
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Student id | \`$S\` |"
    echo "| Region | \`$REGION\` |"
    echo "| EKS cluster | \`$CLUSTER\` |"
    echo "| Lab 1 namespace | \`$(get lab1_namespace)\` |"
    echo
    echo "## Step 5a — copy this exactly"
    echo
    echo '```bash'
    echo "./instructor/bootstrap.sh --student-id $S --region $REGION"
    echo '```'
    echo
    echo "## Step 5c — connect kubectl"
    echo
    echo '```bash'
    echo "$(get kubeconfig_command)"
    echo "kubectl get nodes        # expect 2 nodes, Ready"
    echo '```'
    echo
    echo "## Your lab repositories"
    echo
    echo "Each lab is its own CodeCommit repo. Editing and **pushing** to it is what"
    echo "runs that lab's pipeline."
    echo
    echo "| Lab | Clone URL | Pipeline |"
    echo "|---|---|---|"
    for n in 1 2 3 4; do
      U=$(get "lab${n}_codecommit_clone_url"); P=$(get "lab${n}_pipeline_name")
      [ -n "$U" ] && [ "$U" != "(disabled)" ] && echo "| $n | \`$U\` | \`$P\` |"
    done
    echo
    echo "> Labs 3 and 4 start with their pipeline **failing at \`Validate\`**. That is"
    echo "> the exercise — deliberately policy-violating code for you to fix."
    echo
    echo "## Other values"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| ECR repos | \`$(jq -r '.ecr_repos.value | to_entries | map("\(.key)=\(.value)") | join("  ")' "$J" 2>/dev/null)\` |"
    AUR=$(get lab4_aurora_endpoint)
    [ -n "$AUR" ] && [ "$AUR" != "(disabled)" ] && echo "| Aurora endpoint (Lab 4) | \`$AUR\` |"
    echo "| VPC | \`$(get vpc_id)\` |"
    echo
    echo "_Aurora is stopped between sessions to save cost — if Lab 4 cannot reach the"
    echo "database, ask the instructor to start it._"
  } > "$OUT/$S.md"

  echo "  wrote $OUT/$S.md  ($S / $REGION)"
done

echo
echo "Handouts in: $OUT  (outside the git checkout -- do not commit)"

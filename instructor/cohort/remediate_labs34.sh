#!/usr/bin/env bash
###############################################################################
# IO-107 — play the STUDENT for Labs 3 and 4 on one environment.
#
# Applies the canonical remediations from each lab's README so Validate goes
# GREEN and the Deploy stages actually execute. This is the only way to reach
# the teardown path documented as untested in DEPLOY_LOG §8/§10:
#   - Lab 3 Deploy runs `terraform apply` with its backend INSIDE the artifact
#     bucket, creating a real S3 bucket + Lambda + IAM role, plus a `myapp`
#     Deployment in namespace `lab3`.
#   - Lab 4 Deploy runs an Aurora Blue/Green switchover, which swaps the
#     physical cluster behind the `aws_rds_cluster` in lab_env_student state.
#
# Usage: ./remediate_labs34.sh user50 us-east-1
###############################################################################
set -euo pipefail

STUDENT="${1:?usage: remediate_labs34.sh <student-id> <region>}"
REGION="${2:?usage: remediate_labs34.sh <student-id> <region>}"
export AWS_PROFILE="${AWS_PROFILE:-io107}"
# Same Windows GCM trap as the seed provisioners -- see DEPLOY_LOG §5b.
export GCM_INTERACTIVE=never
export GIT_TERMINAL_PROMPT=0

# Resolved from this script's own location (it lives at instructor/cohort/).
REPO="${IO107_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TF_DIR="$REPO/lab_environment/lab_env_student"
OUT=$(cygpath -m "$TF_DIR/outputs-$STUDENT.json")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

get(){ python -c "import json;print(json.load(open(r'$OUT'))['$1']['value'])"; }
LAB3_REPO=$(get lab3_codecommit_repo_name)
LAB4_REPO=$(get lab4_codecommit_repo_name)
SUFFIX=$(get eks_cluster_name); SUFFIX=$(echo "$SUFFIX" | sed -E "s/^io107-$STUDENT-(.+)-eks$/\1/")
[ -z "$SUFFIX" ] && { echo "ERROR: no suffix" >&2; exit 1; }
echo "student=$STUDENT suffix=$SUFFIX lab3=$LAB3_REPO lab4=$LAB4_REPO"

clone(){ # $1 = repo name
  git -c credential.helper='!aws codecommit credential-helper $@' \
      -c credential.UseHttpPath=true \
      clone "https://git-codecommit.$REGION.amazonaws.com/v1/repos/$1" "$WORK/$1" 2>&1 | tail -2
}
push(){ # $1 = repo dir, $2 = message
  cd "$1"
  git -c user.email=instructor@io107.local -c user.name=Instructor add -A
  git -c user.email=instructor@io107.local -c user.name=Instructor commit -m "$2" 2>&1 | tail -1
  git -c credential.helper='!aws codecommit credential-helper $@' \
      -c credential.UseHttpPath=true push origin HEAD:main 2>&1 | tail -2
}

############################### LAB 3 #########################################
echo ""; echo "===== LAB 3 remediation ====="
clone "$LAB3_REPO"

# Bucket name must be GLOBALLY unique and match
# ^client-(dev|stg|prd)-[a-z0-9]+-[a-z0-9-]+$ -- the run suffix goes in the
# `purpose` segment, which permits hyphens.
BUCKET="client-dev-lab3-$STUDENT-$SUFFIX"
echo "lab3 bucket -> $BUCKET"

python - "$WORK/$LAB3_REPO/terraform/main.tf" "$BUCKET" <<'PY'
import re, sys
p, bucket = sys.argv[1], sys.argv[2]
s = open(p).read()

# VIOLATION 1 + 3: compliant name, and the 4 mandatory tags + DataClass.
s = re.sub(
    r'resource "aws_s3_bucket" "data_bucket" \{.*?\n\}\n',
    f'''resource "aws_s3_bucket" "data_bucket" {{
  bucket = "{bucket}"

  tags = {{
    Environment = "dev"
    Application = "lab3"
    Owner       = "training@client.com"
    CostCenter  = "CC-TRAINING"
    DataClass   = "internal"
  }}
}}

# VIOLATION 2 fixed: paired SSE resource (inline SSE was removed from the
# aws_s3_bucket schema in AWS provider v4.0).
resource "aws_s3_bucket_server_side_encryption_configuration" "data_bucket" {{
  bucket = aws_s3_bucket.data_bucket.id

  rule {{
    apply_server_side_encryption_by_default {{
      sse_algorithm = "AES256"
    }}
  }}
}}
''', s, flags=re.S)

# VIOLATION 4: timeout 600 -> 30 (cap is 300).
s = s.replace("timeout          = 600", "timeout          = 30")

# VIOLATION 5: the 4 mandatory tags on the Lambda.
s = s.replace('''  tags = {
    Name = "Processor"
  }''', '''  tags = {
    Environment = "dev"
    Application = "lab3"
    Owner       = "training@client.com"
    CostCenter  = "CC-TRAINING"
  }''')

open(p, "w").write(s)
print("patched", p)
PY

# VIOLATIONS 6/7/8: required labels, approved registry, resource limits.
cat > "$WORK/$LAB3_REPO/kubernetes/deployment.yaml" <<'YAML'
---
# REMEDIATED (instructor rehearsal) -- see lab_3/README.md step 14.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  labels:
    app: myapp
    environment: dev
    owner: training-at-client-com
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
        environment: dev
        owner: training-at-client-com
    spec:
      containers:
        - name: myapp
          image: public.ecr.aws/docker/library/nginx:1.21
          ports:
            - containerPort: 80
          resources:
            requests:
              memory: "64Mi"
              cpu: "100m"
            limits:
              memory: "128Mi"
              cpu: "250m"
YAML

push "$WORK/$LAB3_REPO" "lab3: remediate all 8 policy violations (instructor rehearsal)"

############################### LAB 4 #########################################
echo ""; echo "===== LAB 4 remediation ====="
clone "$LAB4_REPO"
sed -i 's/target_engine_version = "16.11"/target_engine_version = "16.13"/' \
    "$WORK/$LAB4_REPO/terraform/aurora_cluster.tf"
grep -n 'target_engine_version' "$WORK/$LAB4_REPO/terraform/aurora_cluster.tf" | head -3
push "$WORK/$LAB4_REPO" "lab4: bump target_engine_version 16.11 -> 16.13 (instructor rehearsal)"

echo ""
echo "Both repos pushed. Pipelines should trigger within ~60s."
echo "Lab 4 will stop at the manual Approval gate -- approve it to run the"
echo "Blue/Green switchover."

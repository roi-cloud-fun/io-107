#!/usr/bin/env bash
###############################################################################
# Watch lab3/lab4 pipelines after remediation, auto-approve lab4's manual gate,
# and report terminal state. Lab 4's Blue/Green switchover is slow (~30-45 min).
###############################################################################
set -uo pipefail
export AWS_PROFILE=io107
R=us-east-1
L3="$1"   # lab3 pipeline name
L4="$2"   # lab4 pipeline name
APPROVED=0

state(){ aws codepipeline get-pipeline-state --region $R --name "$1" \
  --query 'stageStates[].{S:stageName,St:latestExecution.status}' --output text 2>/dev/null | tr '\t' ' ' | paste -sd' | '; }
overall(){ aws codepipeline list-pipeline-executions --region $R --pipeline-name "$1" --max-items 1 \
  --query 'pipelineExecutionSummaries[0].status' --output text 2>/dev/null | head -1; }

for i in $(seq 1 120); do   # up to ~60 min
  S3=$(overall "$L3"); S4=$(overall "$L4")
  echo "[$(date -u +%H:%M:%SZ)] lab3=$S3 | lab4=$S4"
  echo "   lab3: $(state "$L3")"
  echo "   lab4: $(state "$L4")"

  # --- auto-approve lab4's manual gate once it is waiting -------------------
  if [ "$APPROVED" -eq 0 ]; then
    TOKEN=$(aws codepipeline get-pipeline-state --region $R --name "$L4" \
      --query "stageStates[?stageName=='Approval'].actionStates[0].latestExecution.token | [0]" \
      --output text 2>/dev/null)
    ACTION=$(aws codepipeline get-pipeline-state --region $R --name "$L4" \
      --query "stageStates[?stageName=='Approval'].actionStates[0].actionName | [0]" \
      --output text 2>/dev/null)
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "None" ]; then
      echo "   >>> approving lab4 gate (action=$ACTION)"
      aws codepipeline put-approval-result --region $R --pipeline-name "$L4" \
        --stage-name Approval --action-name "$ACTION" --token "$TOKEN" \
        --result summary="instructor rehearsal",status=Approved 2>&1 | tail -2
      APPROVED=1
    fi
  fi

  case "$S3|$S4" in
    Succeeded\|Succeeded|Failed\|Failed|Succeeded\|Failed|Failed\|Succeeded) echo "BOTH TERMINAL"; break;;
  esac
  sleep 30
done
echo "=== FINAL ==="
echo "lab3 $(overall "$L3") :: $(state "$L3")"
echo "lab4 $(overall "$L4") :: $(state "$L4")"

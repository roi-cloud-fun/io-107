# IO-107 — Lab Testing Framework (LTF) Recipe

This is the playbook for running the IO-107 Playwright test suite against a sandbox AWS account. The LTF clones this monorepo, applies the unified Terraform, then drives each lab's per-student CodeCommit + CodePipeline through a real end-to-end run.

## Prerequisites

- AWS account with admin (or sufficient) credentials available via `AWS_PROFILE` or instance role
- `terraform >= 1.10`, `aws-cli v2`, `git`, `jq`, `kubectl`, `node` 18+ on PATH
- This repo cloned and current

## Step 1 — Run the bootstrap

From the repo root:

```bash
./instructor/bootstrap.sh --student-id ltf-smoke --apply
```

This creates the S3 state bucket (if missing), writes `backend.tf` + `terraform.tfvars`, then runs `terraform init` + `terraform plan` + `terraform apply` in `lab_environment/lab_env_student/`. EKS provisioning takes ~15 min.

When apply completes, outputs land in `lab_environment/lab_env_student/outputs.json`.

## Step 2 — Run the LTF specs

From the LTF clone:

```bash
cd path/to/testing_framework

export IO107_STUDENT_ID="ltf-smoke"
export IO107_REGION="us-east-1"
export AWS_PROFILE="roitraining"      # or whatever profile your AWS creds are under
export LAB_ENV_TF_DIR="path/to/io-107/lab_environment/lab_env_student"

npx playwright test --grep "IO-107 Lab 1"
```

For Labs 2/3/4: change `--grep "IO-107 Lab N"`. Start with Lab 1 — if it passes, the EKS + pipeline plumbing is sound. Then run the rest.

## Step 3 — Tear down when done

```bash
cd path/to/io-107/lab_environment/lab_env_student
terraform destroy
```

Everything in this stack is tagged with your `student_id`. The S3 state bucket persists (cheap, useful for re-runs); it's named `io107-<student_id>-tfstate-<account_id>` (bootstrap.sh creates one per student_id). To remove it too:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 rb "s3://io107-ltf-smoke-tfstate-${ACCOUNT_ID}" --force
```

## Known gotchas per lab

### Lab 1 — EKS Deployment

- The `aws s3 ls` IRSA proof in the lab MD calls S3 directly; the spec uses `aws sts get-caller-identity` instead because the IRSA role doesn't have `s3:ListAllMyBuckets`. If you want the MD-literal test, grant that permission in the IRSA role's inline policy (in `lab_environment/lab_env_student/main.tf`).
- The 12-minute pipeline wait may be tight on a cold EKS cluster. Bump to 15 min if you see timeouts.
- IRSA role ARN substitution (the test calls it "step 10a") swaps the placeholder in `values-dev.yaml` with the real per-student role ARN from terraform outputs before push.

### Lab 2 — Lambda SAM

- The POST `/items` injection uses a fragile regex against `template.yaml` + `src/app.py`. If the upstream fixture content drifts, the regex won't match and the inject becomes a no-op. Hardening: replace with a hard-coded post-edit content stub or a templating step.
- "Task 7: invoke endpoints" will `test.skip` if the CFN stack name isn't discoverable. Real LTF should read the stack name from the buildspec or compute it from `io107-<student_id>-lab2`.

### Lab 3 — OPA Violations

- The remediation step is currently a **STUB**. It applies a partial fix that won't actually pass OPA. The follow-on assertion is explicitly `test.skip`. For a full LTF run, keep two branches on the per-student CodeCommit (`main` = violations, `remediated` = fixes) and have the test `git checkout remediated && git push origin remediated:main --force-with-lease` for cycle 2.

### Lab 4 — Aurora Blue/Green

- Auto-approval via `aws codepipeline put-approval-result` requires the LTF role to have `codepipeline:PutApprovalResult`. Add it if missing.
- Blue/Green provisioning + replication catch-up + switchover is the longest part of any lab (~15-20 min). If your AWS account has unusually slow RDS provisioning, bump `deployDeadline = 22 min` in `lab4-aurora-bluegreen.spec.ts`.
- Aurora PG family: **16.x** (15.x is in deprecation per AWS docs as of early 2026). Starting state is **16.11** (Dec 2025), Blue/Green target is **16.13** (Apr 2026). Both are pinned in `lab_4/policies/engine_version_pin.rego`. If a newer minor is current when you run, update three places in lock-step:
  - `lab_environment/lab_env_student/main.tf` Aurora `engine_version`
  - LTF spec `lab4.config.ts` `targetEngineVersionFrom`/`To`
  - `lab_4/policies/engine_version_pin.rego` `approved_engine_versions` set

## Suggested order on first run

1. `./instructor/bootstrap.sh --student-id ltf-smoke --apply` (~15 min wait for EKS)
2. Run Lab 1 LTF, fix whatever it surfaces. Most likely failure: an IAM permission gap, or a buildspec env var the test expected but the TF didn't render.
3. Once Lab 1 passes, run Lab 2 → 3 → 4 in order.
4. Re-run any failed lab in isolation: `npx playwright test --grep "IO-107 Lab N"`.
5. `terraform destroy` when finished.

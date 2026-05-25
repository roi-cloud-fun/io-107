# IO-107 — LTF Handoff Note

**Date:** 2026-05-15
**Author:** labforge autonomous run (Claude)

This is what was built while you were away. Everything below is **ready to apply / run**, but I did not touch your AWS account — those steps are listed under "What you need to do" at the bottom.

---

## What got built

### Inside labforge

**New `--mode student` flag on `generate_setup_artifacts.py`.** Default is `student` now. Renders a single unified `lab_env_student/` module instead of the split `training_env/` + `student_bootstrap/`.

**New template tree:** `labforge/templates/lab_env_student/` (versions.tf.tmpl, variables.tf.tmpl, main.tf.tmpl, outputs.tf.tmpl, terraform.tfvars.example.tmpl, README.md.tmpl). One apply provisions everything: VPC, EKS, ECR, KMS, security groups, Aurora subnet group, CodeBuild + CodePipeline service roles, per-lab pipelines + CodeBuild projects + S3 artifact buckets + IRSA roles + K8s namespace + Aurora cluster.

**Lab MDs updated:** Pre-Lab Setup sections regenerated for all 4 labs in student mode (now point at `lab_env_student/` not `student_bootstrap/`).

### IO-107 course folder

**`courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/lab_environment/lab_env_student/`** — 6 files, 1132-line main.tf. `terraform init -backend=false && terraform validate` passes clean. `terraform fmt` applied.

**Snapshots in `_snapshots/`:**
- `2026-05-15_pre_unified_mode/` — lab MDs before any of today's changes
- `2026-05-15_after_lab1_ltf/` — lab MDs after Lab 1 LTF spec was authored
- `2026-05-15_final_after_ltf/` — current state (matches what's in `content/labs/`)

### Inside the LTF (Lab Testing Framework)

**New course:** `testing_framework/courses/io107/`

| File | Purpose |
|---|---|
| `lab-source.ts` | Resolves lab MD paths + fixture repo URLs |
| `lab1.inventory.ts` | 26 steps, classified by strategy (local-cli / aws-cli / manual-only). sha256 pinned. |
| `lab2.inventory.ts` | 28 steps |
| `lab3.inventory.ts` | 24 steps |
| `lab4.inventory.ts` | 24 steps |
| `tests/lab1.config.ts` | Manual inputs (`IO107_STUDENT_ID`, `IO107_LAB1_REPO_WRITE_URL`, `IO107_REGION`, `AWS_PROFILE`) + tool checks |
| `tests/lab1-eks-deployment.spec.ts` | 11 Playwright tests — clone, edit values-dev.yaml, push, poll pipeline, kubectl-verify pods + IRSA |
| `tests/lab2.config.ts` + `lab2-lambda-sam.spec.ts` | Lab 2 — add POST /items, watch SAM canary, verify alias `live` |
| `tests/lab3.config.ts` + `lab3-opa-violations.spec.ts` | Lab 3 — push violations, expect Validate FAIL with ~17 Conftest FAILs |
| `tests/lab4.config.ts` + `lab4-aurora-bluegreen.spec.ts` | Lab 4 — bump engine version, programmatically approve, watch Blue/Green |

**`lab-registry.ts`** — 4 new entries (IO-107 Lab 1-4) with required env vars, prerequisites, expected duration.

**Dry-run `npx playwright test --list courses/io107/` confirms 37 tests across 4 files parse cleanly.**

---

## What I did NOT do

These are blocked behind your AWS account access:

1. **No `terraform apply`.** I can't authorize spend on your account. The module validates, but it has not run.
2. **No CodeStar OAuth handshake.** Interactive AWS Console step — has to be a human in the browser.
3. **No `npm test`.** Without the AWS apply + OAuth, the tests would fail at preflight. I confirmed they PARSE; they have not RUN.
4. **No writable lab fork repos.** The `IO107_LAB*_REPO_WRITE_URL` env vars expect HTTPS URLs of repos LTF can `git push` to. The `jessetop/*` fixtures are read-only for non-jessetop identities. For your LTF runs, you can either reuse `jessetop/*` (since the LTF runs under your identity) or fork them under a test org.

---

## What you need to do to actually run LTF Lab 1

### Step 1 — Bootstrap Terraform state backend (one-time per AWS account)

Terraform 1.10+ supports native S3 locking via `use_lockfile = true`. No DynamoDB lock table needed.

```bash
aws s3api create-bucket --bucket io107-tfstate-us-east-1 --region us-east-1
aws s3api put-bucket-versioning --bucket io107-tfstate-us-east-1 --versioning-configuration Status=Enabled
```

Then add a `backend.tf` to `lab_environment/lab_env_student/`:

```hcl
terraform {
  backend "s3" {
    bucket       = "io107-tfstate-us-east-1"
    key          = "lab_env_student/ltf-smoke.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

### Step 2 — Create CodeStar GitHub connection (one-time per region)

AWS Console → CodePipeline → Settings → Connections → Create. Provider: GitHub. After it's created, click **Update pending connection** and complete the OAuth flow. Copy the connection ARN.

### Step 3 — Apply the unified module

```bash
cd "I:/My Drive/CourseCreationKit/courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/lab_environment/lab_env_student"

cp terraform.tfvars.example terraform.tfvars
# Edit:
#   student_id = "ltf-smoke"
#   github_codestar_connection_arn = "arn:aws:codeconnections:us-east-1:...:connection/..."

terraform init
terraform plan -out=tfplan
terraform apply tfplan       # ~15 min for EKS
terraform output -json > .tf-outputs.json
```

### Step 4 — Run Lab 1 LTF

The fork URL env var is GONE — labs now read the per-student CodeCommit URL from `terraform output -json`. The CodeCommit repo was seeded from `roi-cloud-fun/io-107` `lab_1/` during Step 3's apply.

```bash
cd "C:/Users/jesse/OneDrive/Code/testing_framework"

export IO107_STUDENT_ID="ltf-smoke"
export IO107_REGION="us-east-1"
export AWS_PROFILE="roitraining"
export LAB_ENV_TF_DIR="I:/My Drive/CourseCreationKit/courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/lab_environment/lab_env_student"

npx playwright test --grep "IO-107 Lab 1"
```

### Step 5 — When done, tear down

```bash
cd "I:/My Drive/CourseCreationKit/courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/lab_environment/lab_env_student"
terraform destroy
```

---

## Known gotchas in the LTF specs (things to expect when you run)

**Lab 1:**
- The `aws s3 ls` IRSA proof in the lab MD calls S3 directly; my spec uses `aws sts get-caller-identity` instead because the IRSA role hasn't been granted `s3:ListAllMyBuckets`. If you want the MD-literal test, grant that permission in the IRSA role's inline policy (in `main.tf`).
- The 12-minute pipeline wait may be tight on a cold EKS cluster. Bump to 15 min if you see timeouts.

**Lab 2:**
- The POST /items injection in Task 4 uses a fragile regex. If the SAM template / `app.py` content drifts from what's in `jessetop/io107-lab2-sam-app`, the regex won't match and the inject becomes a no-op. Hardening: replace the regex with a hard-coded post-edit content stub or a templating step.
- "Task 7: invoke endpoints" will `test.skip` if the CFN stack name isn't discoverable. Real LTF should read the stack name from the buildspec or compute it from `${course_id}-${student_id}-lab2`.

**Lab 3:**
- "Task 6+7: remediate" is a **STUB**. It applies a partial fix that won't actually pass OPA. The follow-on test is explicitly `test.skip`. For a full LTF run, replace the stub with a "pull the remediated branch from the fork" step. Suggested approach: keep two branches on each fork (`main` = violations, `remediated` = fixes), and have the test `git checkout remediated && git push origin remediated:main --force-with-lease` for cycle 2.

**Lab 4:**
- Auto-approval via `aws codepipeline put-approval-result` requires the LTF role to have `codepipeline:PutApprovalResult` — make sure that's in the test runner's IAM policy.
- The Blue/Green wait is the longest part (~15 min of polling). If your AWS account has unusually fast/slow RDS provisioning, the `deployDeadline = 22 min` may need tuning.
- Aurora PG family: **16.x** (15.x is in deprecation per AWS docs as of early 2026). Starting state is **16.11** (Dec 2025), Blue/Green target is **16.13** (Apr 2026). Both are pinned in the engine_version_pin Rego policy. If a newer minor is current when you run, update three places in lock-step: `lab_env_student/main.tf` Aurora `engine_version`, `lab4.config.ts` `targetEngineVersionFrom/To`, and the `approved_engine_versions` set in `jessetop/io107-lab4-aurora-bluegreen/policies/engine_version_pin.rego`.

---

## Recommended order of operations on your return

1. Skim this doc.
2. Skim the snapshot in `_snapshots/2026-05-15_final_after_ltf/` to compare against `content/labs/` if anything looks off.
3. Do Step 1 (state backend bootstrap) + Step 2 (CodeStar OAuth) once.
4. Run Step 3 (terraform apply) in a sandbox account. Confirm EKS comes up.
5. Run Step 4 (Lab 1 LTF) and fix whatever it surfaces. Most likely failure: an IAM permission gap somewhere, or a buildspec env var the test expected but the TF didn't render.
6. Once Lab 1 passes, iterate Lab 2 → 3 → 4 in order.

Total estimated tear-up-to-Lab-1-green: **~1 hour** of your time (most of which is waiting for `terraform apply`).

---

## Files touched / created in this session

**Course folder:** `I:/My Drive/CourseCreationKit/courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/`
- `lab_environment/lab_env_student/` — 6 new TF files
- `content/labs/Lab_*_Guide.md` — Pre-Lab Setup section regenerated in student mode
- `_snapshots/` — 3 snapshots
- `LTF_HANDOFF.md` — this file

**labforge:**
- `python/generate_setup_artifacts.py` — `--mode` flag added
- `templates/lab_env_student/` — 6 new templates
- `templates/pre_lab_setup_section.md.tmpl` — mode-aware path
- `CLAUDE.md` — documented `--mode student`

**LTF (testing_framework):**
- `courses/io107/` — new folder with lab-source, 4 inventories, 4 configs, 4 specs
- `lab-registry.ts` — 4 new IO-107 entries

All work is in your file system, all snapshots are in Drive. Nothing was pushed to GitHub.

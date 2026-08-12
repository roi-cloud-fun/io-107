# IO-107 cohort deploy — session log, 2026-08-10

Durable notes for the IO-107 cohort rollout. Lives **outside** the git repo
(`OneDrive/Code/io-107/`, not `OneDrive/Code/io-107/io-107/`) so it survives a
reboot and OneDrive-syncs, without adding untracked files to the repo.

**Status: ✅ ACCOUNT IS CLEAN — nothing is running, nothing is burning.**
The full trial completed 2026-08-10: 4 us-east-1 environments deployed with labs
1+2 (§9), labs 3+4 added and verified, then everything destroyed (§10). The vCPU
quota blocker is CLEARED (§3). Only the 4 state buckets and 15 KMS keys in a
7-day `PendingDeletion` window remain, both intentional. Nothing committed to git.

**The rollout path is now proven end-to-end** — full deploy, partial-lab deploy,
additive lab addition, and teardown. us-east-2 (user04–07) has never been
deployed.

> ⚠️ Before the next teardown read **§10's bug findings**, not just §8 — the
> teardown script silently skipped the SAM-stack cleanup on its first run and
> left 4 CloudFormation stacks behind. Fixed, but it failed silently.

> Run suffixes are random per apply. Every resource name in §4 and §9 is now
> stale — those environments no longer exist.

---

## 1. Target account

| | |
|---|---|
| AWS profile | **`io107`** |
| Account | **<ACCOUNT_ID>** |
| Identity | `arn:aws:iam::<ACCOUNT_ID>:user/Instructor` (AdministratorAccess) |

> The `roitraining` profile is a **different** account (029331796573). The
> earlier `ltf-smoke` smoke test ran there, not here. This account started
> empty — no VPCs beyond defaults, no EKS, no EC2, no S3 buckets.

IAM users **`user01`–`user50`** already existed, zero-padded, in group
`attendees` (TerraformPowerUser + ViewOnlyAccess + EC2InstanceConnect).
`Terraform-InstanceRole` instance profile exists.

**Pre-flight probe:** created and deleted a throwaway CodeCommit repo to confirm
`CreateRepository` works in this account. It does — important, because CodeCommit
is closed to new AWS customers since Jul-2024 and this whole module depends on it.

---

## 2. Roster / region split (as agreed)

7 students + Jesse = 8 environments, 4 per region.

| Region | Users |
|---|---|
| **us-east-1** | **user50 (Jesse — DEPLOYED)**, user01, user02, user03 |
| **us-east-2** | user04, user05, user06, user07 |

---

## 3. ✅ RESOLVED — EC2 vCPU quota

**Both increases were APPROVED on 2026-08-10** (verified 2026-08-10 via
`get-service-quota`). Filed by `OrganizationAccountAccessRole/Joe.Wolfe`, both
cases closed within ~2 minutes:

| Region | Applied value | Case | Requested |
|---|---|---|---|
| us-east-1 | **60** | 178639265500955 | 60 |
| us-east-2 | **32** | 178639275800306 | 32 |

⚠️ **us-east-2 came in at 32, not the 64 recommended below.** It covers the
4 planned students (24 vCPU steady) with 8 vCPU spare, but that is only ~1 extra
environment. If a us-east-2 env has to be rebuilt alongside a broken one, or if
node groups scale toward `max_size = 4` (8 vCPU × 4 students = 32, exactly at the
cap), it will wedge. us-east-1 at 60 has real headroom. Consider asking Joe to
bump us-east-2 to 64 as well before class.

Current consumption at time of check: **0 running instances, 0 EIPs, 0 NAT
gateways, 0 EKS clusters in both regions** — the teardown was clean.

### Original analysis (kept for reference)

Quota **`ec2` / `L-1216C47A`** — *Running On-Demand Standard (A,C,D,H,I,M,R,T,Z)
instances* — was the AWS **default of 5** in both regions, never raised.

Per-user need:

| Component | vCPU |
|---|---|
| EKS node group (`eks_node_desired_size = 2` × t3.medium) | 4 |
| Student workstation EC2 (t3.medium, STUDENT_SETUP.md Step 1) | 2 |
| **per user** | **6** |
| **4 users/region** | **24** |

`max_size = desired + 2` (`main.tf:574`) means a node group could reach 8 vCPU.
**Requested value: 64 per region** (headroom + room to rebuild a broken env
alongside the old one). You are only billed for running instances.

```bash
export AWS_PROFILE=io107
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-1216C47A --desired-value 64 --region us-east-1
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-1216C47A --desired-value 64 --region us-east-2

# check approval
aws service-quotas list-requested-service-quota-change-history-by-quota \
  --service-code ec2 --quota-code L-1216C47A --region us-east-1
```

**RDS is NOT affected** — Aurora `db.t3.medium` counts against RDS quotas
(DB instances 40, clusters 40), not EC2 vCPU. No RDS increase needed.
Everything else checked out fine: EIP 25, VPC 50, IGW 50, NAT/AZ 10,
EKS clusters 100, CodeBuild concurrency 15.

**Current consumption: us-east-1 has 4 of 5 vCPU used by user50.** Nothing else
fits there — not even Jesse's own workstation EC2. us-east-2 is empty but also
capped at 5, so exactly one more environment could fit there.
*(Superseded — user50 was torn down and the quota was raised. See the top of §3.)*

### Asked but answered NO: can we pre-deploy pipelines/CodeBuild and defer EKS?

Not without editing `main.tf`. Every `null_resource.labN_seed` has a hard
`depends_on = [aws_eks_node_group.training, ...]` (`main.tf:930`), and the seed
push is what fires the pipelines. There is no `enable_eks` toggle — shared infra
is unconditional. `eks_node_desired_size = 0` fails because `min_size = 1` is
hardcoded (`main.tf:576`). Cleaner to just wait for the quota.

---

## 4. What was actually deployed

```bash
cd io-107
export AWS_PROFILE=io107
./instructor/bootstrap.sh --student-id user50 --region us-east-1 \
    --profile io107 --force-tfvars
# then hand-added apply_host_principal_arn to terraform.tfvars (see §5)
cd lab_environment/lab_env_student
terraform init -input=false
terraform plan -input=false -out=tfplan.out
GCM_INTERACTIVE=never GIT_TERMINAL_PROMPT=0 \
  terraform apply -input=false -no-color tfplan.out
```

Result: **`Apply complete! Resources: 91 added, 0 changed, 0 destroyed.`**

- Run suffix: **`f032fd`** → everything named `io107-user50-f032fd-*`
- State bucket: `s3://io107-user50-tfstate-<ACCOUNT_ID>`, key `lab_env_student/user50.tfstate`
- VPC `vpc-0b5201a9fe9edc1b8` (10.20.0.0/16), 6 subnets across 3 AZs
- EKS `io107-user50-f032fd-eks`, 2 nodes Ready, v1.34.9-eks-254016e
- Aurora `io107-user50-f032fd-lab4-aurora` — `available`, 16.11

### Verification results

| Lab | Pipeline | Evidence |
|---|---|---|
| Lab 1 | Source ✓ Build ✓ | `myapp` pod 1/1 Running in ns `lab1-user50-f032fd`; LoadBalancer `acd5eb0c4e9264d29bcf1857930642ab-1346859695.us-east-1.elb.amazonaws.com`; `myapp-sa` annotated with IRSA role `io107-user50-f032fd-myapp-dev-role` |
| Lab 2 | Source ✓ Build ✓ | CFN stack `io107-user50-f032fd-lab2-sam-app` = CREATE_COMPLETE |
| Lab 3 | Validate **Failed** | **BY DESIGN** |
| Lab 4 | Validate **Failed** | **BY DESIGN** |

**Both Validate failures are the intended starting state, not defects:**

- **Lab 3** — conftest emitted exactly the seeded violations: bucket naming
  pattern, missing SSE, missing tags (Application/CostCenter/DataClass/
  Environment/Owner), Lambda timeout 600 > 300. `lab_3/README.md:224` states
  verbatim: *"Source and Build succeed (green); Validate fails (red); Deploy does
  not run. The pipeline overall status is Failed."*
- **Lab 4** — `target_engine_version '16.11' is not in the approved list
  {"16.13", "16.14"}`. Seed ships 16.11 (`lab_4/terraform/aurora_cluster.tf:34`);
  the student's Task 6 bumps it to 16.13, turning Validate green.

EKS access entries on the cluster confirm **both** `user/Instructor` and
`user/user50` — the fix in §5 works.

---

## 5. Two gaps in `instructor/bootstrap.sh` (instructor-pre-deploy model)

The repo assumes **each student applies their own stack**. When the *instructor*
pre-deploys, two things break:

### 5a. Students get no kubectl access — MUST FIX per student

`main.tf:481` grants EKS cluster admin only to the **apply-host** principal.
Pre-deploying as Instructor means students can't run Lab 1 Part B
(`kubectl get pods`, `kubectl exec`, `helm uninstall`, steps 17–26).

Fix — no code change, uses the existing `variables.tf:95` variable. Append to
`terraform.tfvars` before apply:

```hcl
apply_host_principal_arn = "arn:aws:iam::<ACCOUNT_ID>:user/userNN"
```

Instructor keeps admin regardless via
`bootstrap_cluster_creator_admin_permissions = true` (`main.tf:400`).

### 5b. Windows: apply HANGS FOREVER on the CodeCommit seed push

**Always export these before `terraform apply` on Jesse's Windows box:**

```bash
export GCM_INTERACTIVE=never
export GIT_TERMINAL_PROMPT=0
```

The `null_resource.labN_seed` provisioners push with
`git -c credential.helper='!aws codecommit credential-helper $@'`. `git -c`
**appends** to the helper list rather than replacing it, and this machine's
global config has `credential.helper manager` (Git Credential Manager). GCM runs
first, finds no cached credential for the new repo path, and opens an
**interactive prompt** — which blocks a non-interactive `local-exec` forever, at
roughly 90% through the apply, with no error message.

With the vars set, the log shows
`fatal: Cannot prompt because user interactivity has been disabled`, git falls
through to the AWS helper, and the push succeeds. **This was observed on all four
seeds during the user50 apply.** Does not affect students — they apply from
Amazon Linux EC2, which has no GCM. Only needed for `apply`, not `plan`.

### 5c. Unrelated Git Bash gotcha

`export MSYS_NO_PATHCONV=1` for any AWS CLI arg starting with `/` (e.g.
`--log-group-name /aws/codebuild/...`). Without it MSYS rewrites it to a Windows
path and the API rejects it with a confusing `InvalidParameterException` about a
regex constraint.

---

## 6. Rollout procedure for the remaining 7 (once quota clears)

Use `deploy_cohort.sh` (sits next to this file, in `OneDrive/Code/io-107/`).
It wraps `bootstrap.sh` and adds §5a + §5b + `init -reconfigure`.

```bash
export AWS_PROFILE=io107
./deploy_cohort.sh user01 us-east-1
./deploy_cohort.sh user02 us-east-1
./deploy_cohort.sh user03 us-east-1
./deploy_cohort.sh user04 us-east-2
./deploy_cohort.sh user05 us-east-2
./deploy_cohort.sh user06 us-east-2
./deploy_cohort.sh user07 us-east-2
```

**`terraform init -reconfigure` is mandatory between students.** `backend.tf`
gets rewritten to a different per-student bucket/key each time; without
`-reconfigure` Terraform offers to **migrate** the previous student's state into
the next student's bucket.

~20 min each → ~2.5 h sequential. Can be parallelized to ~30 min by copying the
module into per-student working directories (not yet done).

Per-student outputs are saved to `outputs-<student>.json` — plain
`terraform output` only reflects whichever student was applied last, since all
students share one working directory.

---

## 7. Open items / decisions deferred

- [ ] **Jesse files the vCPU quota increases** (§3) — the long pole.
- [ ] Deploy user01–07 once approved (§6).
- [ ] **Not committed, by request:** `deploy_cohort.sh` → `instructor/`.
- [ ] **Doc bug, not fixed:** `instructor/LTF_HANDOFF.md:77` claims 16.11 and
      16.13 are "both pinned in `lab_4/policies/engine_version_pin.rego`". Only
      `{16.13, 16.14}` are approved — 16.11 is deliberately excluded, which is
      what forces the student's bump. Misleading; worth a one-line correction.
- [ ] Stale comment: `main.tf` header says lab1 creates a K8s namespace via
      Terraform. It doesn't — Helm creates it via `--create-namespace`
      (`outputs.tf:118`). Harmless.
- [ ] Untracked files left in the repo by this session (safe to delete):
      `lab_environment/lab_env_student/{apply-user50.log,plan.json,tfplan.out}`.
      Note `backend.tf` + `terraform.tfvars` there are gitignored and currently
      point at **user50** — re-run `bootstrap.sh` before touching another student.

## 8. Teardown — DONE for user50, and what it revealed

user50 was torn down the same day to stop the burn while waiting on the quota.
**Result: `Destroy complete! Resources: 91 destroyed.` — 0 errors.** Account
verified clean afterwards: no EC2, no VPC (bar the default), no EKS, no RDS, no
ECR, no CodeCommit/CodePipeline/CodeBuild, no CFN stacks, no load balancers, no
EIPs, no NAT gateways, no non-default security groups, no IAM roles matching
`user50`, no OIDC providers. Only `s3://io107-user50-tfstate-<ACCOUNT_ID>`
remains, which is intentional (cheap, and `bootstrap.sh` reuses it).

### ⚠️ `terraform destroy` alone is NOT sufficient — 3 classes of leftover

**1. Resources created BY THE PIPELINES are outside Terraform state.**
Lab 2's CodeBuild runs `sam deploy`, which creates a CloudFormation stack that
`terraform destroy` knows nothing about. For user50 that orphaned:

```
io107-user50-f032fd-lab2-sam-app
  ├─ AWS::Lambda::Function + Alias + Version + 2 Permissions
  ├─ AWS::ApiGateway::RestApi / Deployment / Stage
  ├─ AWS::CodeDeploy::Application + DeploymentGroup
  ├─ AWS::IAM::Role  × 2
  └─ AWS::CloudWatch::Alarm
```

Delete it **before** `terraform destroy` (it may reference the lab2 artifact
bucket, which Terraform deletes):

```bash
aws cloudformation delete-stack --stack-name io107-<id>-<suffix>-lab2-sam-app --region <region>
```

> **NOT YET VALIDATED — the bigger version of this problem.** For user50 only
> Lab 2 actually deployed; Labs 3 and 4 stopped at Validate (by design), so their
> Deploy stages never ran. **A student who COMPLETES Labs 3 and 4 will orphan
> more.** Lab 3's Deploy runs `terraform apply` with its backend in the *artifact
> bucket* — creating an S3 bucket `client-dev-lab3-<id>` and a `myapp` Deployment
> in namespace `lab3`. `terraform destroy` of `lab_env_student` deletes the
> artifact bucket **including that state file**, orphaning those resources with no
> state left to destroy them from. Lab 4's Blue/Green switchover also swaps the
> physical Aurora cluster behind the `aws_rds_cluster` in state. **Do a full
> end-of-class teardown rehearsal on ONE student who has completed all four labs
> before relying on `terraform destroy` for the cohort.**

**2. CloudWatch log groups are never destroyed.** CodeBuild / EKS / RDS create
them implicitly, so they're not in state. Six were left for user50 and had to be
deleted by hand. They cost almost nothing but accumulate — and because the run
suffix is a fresh random on every apply, *every redeploy leaves another set
forever*:

```bash
aws logs delete-log-group --log-group-name /aws/codebuild/io107-<id>-<suffix>-lab{1,2,3,4}
aws logs delete-log-group --log-group-name /aws/eks/io107-<id>-<suffix>-eks/cluster
aws logs delete-log-group --log-group-name /aws/rds/cluster/io107-<id>-<suffix>-lab4-aurora/postgresql
```

**3. KMS keys go to `PendingDeletion`, not gone.** The 3 keys (rds/s3/logs)
entered a 7-day window (deleted 2026-08-17). Still billed (~$1/key/month, so
pennies) until the window expires. Nothing to do — and **they will not collide on
redeploy**, since the module creates no `aws_kms_alias`.

### Validated teardown sequence

Order matters — the Helm LoadBalancer must go first or the VPC destroy hangs on
ENI/EIP `DependencyViolation`. (`null_resource.vpc_lb_cleanup` is a safety net
that also handles this, and it logged "No resources found" because the manual
`helm uninstall` had already succeeded.)

```bash
cd io-107/lab_environment/lab_env_student
export AWS_PROFILE=io107
export MSYS_NO_PATHCONV=1

# 1. Helm LoadBalancer (created in-cluster, NOT by Terraform)
aws eks update-kubeconfig --name io107-<id>-<suffix>-eks --region <region>
helm uninstall myapp -n lab1-<id>-<suffix> || true
#    wait until this returns empty before continuing:
aws elb describe-load-balancers --region <region> \
  --query 'LoadBalancerDescriptions[?VPCId==`<vpc-id>`].LoadBalancerName' --output text

# 2. Pipeline-created CFN stack (see leftover class 1)
aws cloudformation delete-stack --stack-name io107-<id>-<suffix>-lab2-sam-app --region <region>

# 3. The main stack
terraform destroy -auto-approve

# 4. Orphaned log groups (see leftover class 2)

# 5. optional: aws s3 rb s3://io107-<id>-tfstate-<ACCOUNT_ID> --force
```

Full transcript: `destroy-user50.log` (in the repo's `lab_env_student/`, gitignored).

---

## 9. Trial rollout — us-east-1, labs 1+2 only (2026-08-10)

Jesse asked for a 4-environment trial: instructor + user01–03, **labs 1 and 2
only**. All four applied cleanly: **69 resources each, 0 errors**.

| Student | Run suffix | EKS cluster | Finished (UTC) |
|---|---|---|---|
| user50 (instructor) | `6fbd14` | `io107-user50-6fbd14-eks` | 22:39 |
| user01 | `39cf82` | `io107-user01-39cf82-eks` | 22:55 |
| user02 | `8316e3` | `io107-user02-8316e3-eks` | 23:09 |
| user03 | `4b989a` | `io107-user03-4b989a-eks` | 23:21 |

~14 min each, ~60 min total. Per-student outputs in
`lab_env_student/outputs-<id>.json`, apply transcripts in `apply-<id>.log`.

### How the lab restriction was done

`bootstrap.sh --force-tfvars` hardcodes all four `enable_labN = true` into the
generated `terraform.tfvars` and has **no flag to change them**. Appending
overrides to that file does NOT work — a second assignment to the same variable
in one tfvars file is a Terraform error. Solution: pass `-var`, which outranks
tfvars. `deploy_cohort.sh` now reads `ENABLE_LAB1..4` (default true) and forwards
them to `terraform plan`.

```bash
ENABLE_LAB3=false ENABLE_LAB4=false ./deploy_cohort.sh user01 us-east-1
```

`deploy_trial_use1.sh` (next to this file) is the sequential driver for all four.
**It must stay sequential** — every student shares the single working directory
`lab_environment/lab_env_student` and `backend.tf` is rewritten per student, so
concurrent runs corrupt state.

**69 resources vs 91 for the full four labs:** lab1 = 13, lab2 = 9, lab3/lab4 = 0,
and critically **no Aurora** — that is the expensive piece Lab 4 brings.

### Labs 3 and 4 are additive later

Shared infra (VPC, EKS, ECR, KMS, IAM) is created unconditionally regardless of
the toggles, so adding the remaining labs is just a re-apply — it does not
disturb labs 1–2 or rebuild the cluster:

```bash
ENABLE_LAB3=true ENABLE_LAB4=true ./deploy_cohort.sh user01 us-east-1
```

Note this re-runs `bootstrap.sh --force-tfvars`, which is fine (same bucket, same
`name_suffix` comes from state, not tfvars).

### Verified after apply

- 4 EKS clusters **ACTIVE**; 8 × t3.medium nodes = **16 vCPU of the 60** quota.
  Add 2 vCPU per student workstation EC2 if they launch them → 24.
- 8 pipelines, **lab1 + lab2 only** — no lab3/lab4 pipelines exist.
- All lab1/lab2 pipelines **Succeeded** except user03's, which were still in
  Build at check time simply because it applied last. Expected, not a failure.
  Note this differs from labs 3/4, whose Validate-stage failure IS correct (§ the
  deliberately policy-violating fixtures).
- **§5a fix confirmed on all four** — `aws eks list-access-entries` shows both
  `user/<studentNN>` and `user/Instructor` on each cluster, so students can run
  Lab 1 Part B (`kubectl`, `helm`) against their own cluster.
- **§5b GCM workaround confirmed** — each apply log has exactly 2
  `Cannot prompt because user interactivity has been disabled` lines (one per
  seeded lab; 2 seeds now instead of 4). That message is the **benign expected
  behaviour**: GCM fails fast, git falls through to the AWS credential helper,
  push succeeds. 0 real errors in all four logs.

### Not yet done

- us-east-2 (user04–07) not deployed.
- Labs 3 and 4 not deployed anywhere.
- Teardown of this trial not rehearsed — see §8 first.

---

## 10. Labs 3+4 added, verified, and FULL TEARDOWN (2026-08-10, late)

Labs 3 and 4 were added to all four live us-east-1 environments, verified, left
to settle 10 min, then everything was destroyed. **Account is clean.**

### Add (additive re-apply)

`ENABLE_LAB3=true ENABLE_LAB4=true` → **22 added, 0 changed, 0 destroyed** on all
four (69 → 91). ~8 min each. Suffixes were preserved: the run suffix comes from
`random_id.run`, which persists in state (`main.tf:54`), so nothing was rebuilt.
**Confirm this with a plan before any re-apply** — if the suffix ever did
regenerate, a re-apply would destroy and recreate all 91 resources.

### Verified state after a 10-minute settle — ALL FOUR IDENTICAL

| Lab | Stages | Correct? |
|---|---|---|
| lab1 | Source ✓ Build ✓ | green as intended |
| lab2 | Source ✓ Build ✓ | green as intended |
| lab3 | Source ✓ Build ✓ **Validate ✗** Deploy not run | **by design** |
| lab4 | Source ✓ Build ✓ **Validate ✗** Approval/Deploy not run | **by design** |

4 Aurora clusters `available` on **16.11** — the seeded non-compliant version
Lab 4's Validate rejects (approved list is `{16.13, 16.14}`). Correct, not a bug.

### Teardown result

`Destroy complete! Resources: 91 destroyed.` ×4, 0 errors, ~12 min each.
Final sweep: **0** EC2 / EKS / RDS / VPC / NAT / EIP / ELB / pipelines / CodeBuild
/ CodeCommit / ECR / CFN / Lambda / API Gateway / OIDC providers / io107 log
groups / io107 IAM roles. Kept intentionally: 4 state buckets, and 15 KMS keys in
`PendingDeletion` (expiring 2026-08-17). The only `Enabled` KMS keys are the 3
AWS-managed defaults (CodeCommit/Lambda/S3) — free, not leftovers.

### 🐞 Two findings from this teardown

**1. `teardown_use1.sh` silently skipped the SAM cleanup (FIXED).** Git Bash was
passing an MSYS path (`/c/Users/...`) to **Windows** python, which cannot open it.
`CLUSTER`/`SUFFIX` came back empty, the stack name collapsed to
`io107-user50--lab2-sam-app` (double dash), `describe-stacks` found nothing, and
the script printed "no SAM stack" and moved on. All four SAM stacks — plus 8 IAM
roles, Lambdas, API Gateways, CodeDeploy apps and alarms — survived the teardown
and had to be deleted by hand afterwards. **This is the exact failure mode §8
warns about, and it failed silently.** Fixed two ways: `cygpath -m` for the path,
a hard-fail guard instead of continuing with empty names, and the SAM stack is now
*discovered* via `list-stacks` rather than trusting a constructed name.

> General lesson for this repo's tooling on Windows: any MSYS path handed to a
> Windows-native binary (python, terraform var files, aws CLI args) needs
> `cygpath -m`. Related but distinct from the `MSYS_NO_PATHCONV=1` gotcha in §5c.

**2. `helm uninstall` before destroy turned out NOT to be load-bearing.** The
same bug also skipped step 1 entirely, yet all four VPCs destroyed cleanly with
no ENI/EIP `DependencyViolation`. `null_resource.vpc_lb_cleanup` handled the
LoadBalancers on its own. The manual helm step in §8 is belt-and-braces, not a
requirement — useful to know for the end-of-class teardown.

**3. Deleting the SAM stack AFTER `terraform destroy` works fine.** §8 recommends
deleting it first because it references the lab2 artifact bucket. In practice all
four deleted cleanly *after* Terraform had already removed those buckets. The
recommended order is still safer, but the reverse is recoverable.

### Still NOT rehearsed → ✅ CLOSED 2026-08-11, see §11a

Labs 3 and 4 stopped at Validate (nobody remediated the fixtures), so their
**Deploy stages never ran**. The dangerous orphan case in §8 — Lab 3's Deploy
writing its own tfstate *into* the artifact bucket that `terraform destroy` later
deletes, plus Lab 4's blue/green Aurora swap — is therefore **still untested**.
Rehearsing it needs one environment where the fixtures are actually fixed so
Deploy executes, followed by a destroy.

---

## 11. user50 full-lab rehearsal + aborted cohort deploy (2026-08-11)

Written 2026-08-11 ~22:50 after the PC locked up mid-run and the session was
lost. All statements below were re-verified against **live AWS**, not just logs.

### 11a. The §10 "Still NOT rehearsed" gap is now CLOSED

The dangerous orphan case — Lab 3's Deploy writing its own tfstate *into* the
artifact bucket that `terraform destroy` later deletes, plus Lab 4's blue/green
Aurora swap — was rehearsed end-to-end on **user50, suffix `e2ecbd`**, us-east-1.

| Step | Artifact | Result |
|---|---|---|
| Deploy all 4 labs | `rehearsal-deploy-user50.log` (20:26) | **91 added, 0 changed, 0 destroyed**, no errors |
| Remediate fixtures + drive pipelines | `drive-labs34.log` (20:53) | **lab3 Succeeded, lab4 Succeeded** — Deploy stages actually ran |
| Full teardown | `teardown-complete-user50.log` (21:22) | clean, all 6 phases |

Lab 4's manual approval gate was auto-approved by the driver
(`action=ApproveDeploy`, 20:29:37). Both pipelines showed `Validate Failed` on
the first pass — that is the **correct** starting state (deliberately
policy-violating fixtures); remediation flipped them to Succeeded.

`teardown_complete.sh` handled every leftover class, in this order:
A) lab3 pipeline-created CFN stack (**6 destroyed**) → B) Aurora blue/green
leftovers (deleted bgd record `bgd-rmatjixm6tsptsgz` + orphaned cluster
`...-lab4-aurora-old1` and its writer) → C) `helm uninstall` + ns delete →
D) lab2 SAM stack → E) `terraform destroy` (**91 destroyed**) → F) 8 log groups.

**The blue/green swap leaves an `-old1` cluster and a `bgd-*` record that
`terraform destroy` does NOT remove.** That is now handled by phase B of
`teardown_complete.sh` — it is load-bearing, do not drop it.

### 11b. The cohort deploy was launched and DIED before applying anything

At 21:26 `deploy_cohort_parallel.sh` (new — replaces the ~2h sequential path with
per-student dirs under `cohort/`) was started for all 8 students, labs 1–4.
`cohort-deploy.log` ends mid-`init`:

```
==> bootstrap user50 ... user07     <- all 8 completed
==> init user50 ... init user04     <- died here, ~21:45-21:50
```

It never printed a single `==> apply`. Phase 2 runs `terraform init`
**sequentially** (the shared `TF_PLUGIN_CACHE_DIR` is not concurrency-safe), so
the lockup hit during init and **no apply ever started**. `cohort-status.txt` is
0 bytes. No surviving processes (only VS Code's `terraform-ls`).

### 11c. Verified live account state — CLEAN, nothing running

Swept both regions 2026-08-11 22:48:

- EKS clusters: **none** · EC2 instances (any state): **none** · RDS clusters:
  **none** · non-default VPCs: **none** · NAT gateways: **none** ·
  CloudFormation stacks: **none** · CodePipelines: **none**
- All 8 `io107-*-tfstate` buckets exist; the 4 holding state objects
  (user50/01/02/03) are all **`resources: 0`** — empty post-destroy state
  (user50 serial 45, user01 serial 15). user04–07 buckets are **empty**
  (created 21:27–21:28 by the aborted run's bootstrap phase).
- **No DynamoDB tables in either region** → no lock table → **no stale
  Terraform locks** to force-unlock before re-running.
- 18 KMS keys in us-east-1 `PendingDeletion` (7-day window, expiring 08-17/08-18);
  us-east-2 none. Intentional and harmless.

**Nothing needs cleaning up before the cohort deploy is re-run.** The 4 new
empty state buckets are reused as-is; re-running the script is idempotent
(bootstrap re-writes backend.tf/tfvars, then `rm -rf`s and re-snapshots each
`cohort/<id>` dir).

---

## 12. us-east-1 cohort deployed and VERIFIED — LIVE (2026-08-11 23:47)

Re-ran after the §11b abort, us-east-1 only:
`./deploy_cohort_parallel.sh user50 user01 user02 user03`, all 4 labs.
Transcript: `cohort-deploy-use1.log` (the aborted run's `cohort-deploy.log` was
deliberately preserved, not overwritten).

**~21 minutes wall clock** (23:26 launch → 23:47 last apply) vs ~2h sequential.
The parallel rewrite is validated. All 4 applies ran concurrently after a
sequential bootstrap + init phase.

| Student | Suffix | Apply | Cluster |
|---|---|---|---|
| user50 | `cbb2ad` | **91 added, 0 changed, 0 destroyed** | ACTIVE |
| user01 | `246c6d` | **91 added, 0 changed, 0 destroyed** | ACTIVE |
| user02 | `8cfd95` | **91 added, 0 changed, 0 destroyed** | ACTIVE |
| user03 | `6f7456` | **91 added, 0 changed, 0 destroyed** | ACTIVE |

Zero `Error:` lines across all four apply logs. 91 resources matches §11a's
rehearsal exactly.

### Verified against live AWS (not just exit codes)

- 4 EKS clusters **ACTIVE**, each with its nodegroup · 8 × t3.medium **running**
  (16 vCPU of the 60 limit) · 4 Aurora clusters **available** · 4 non-default
  VPCs · 16 CodePipelines.
- **EKS access entries carry the student's own IAM user** on every cluster
  (`user/user01`, `user/user02`, `user/user03`, `user/user50`) alongside
  `user/Instructor`. This is the §5a gap `bootstrap.sh` does not handle —
  confirmed correctly applied by the `apply_host_principal_arn` append. Lab 1
  Part B will work for students.

### Pipeline starting state — uniform across all 4 students ✅

After settle-out, all 16 pipelines terminal, identical pattern per student:

```
lab1 :: Source Succeeded | Build Succeeded
lab2 :: Source Succeeded | Build Succeeded
lab3 :: Source Succeeded | Build Succeeded | Validate FAILED | Deploy None
lab4 :: Source Succeeded | Build Succeeded | Validate FAILED | Approval None | Deploy None
```

`Validate Failed` on lab3/lab4 is the **CORRECT** starting state — deliberately
policy-violating fixtures the student remediates. **Do not "fix" them.**

### Still to do

- Teardown when the class ends: `./teardown_complete.sh` per student — the
  6-phase sequence in §11a, **including phase B (Aurora blue/green `-old1` +
  `bgd-*` records)** for any student who actually completes Lab 4.

---

## 13. 🚨 us-east-2 deployed, then FOUND: the labs hardcode `us-east-1` (2026-08-12 00:36)

us-east-2 (user04–07) deployed cleanly — **91 added / 0 changed / 0 destroyed**
each, 0 errors, 4 EKS ACTIVE, 4 Aurora available, student access entries correct,
16 vCPU of the 32 quota. **The Terraform infrastructure is fine.**

**The lab CONTENT is not.** Pipeline end state does NOT match us-east-1:

| Pipeline | us-east-1 (correct) | us-east-2 (broken) |
|---|---|---|
| lab1 | Build ✓ | Build ✓ |
| lab2 | Build ✓ | **Build FAILED** |
| lab3 | Build ✓ → Validate Failed ✓ | Build ✓ → Validate Failed *(looks OK — it is not, see below)* |
| lab4 | Build ✓ → Validate Failed ✓ | **Build FAILED** (never reaches Validate) |

### Root cause: three hardcoded `us-east-1` values in student-facing lab source

| File | Line | Effect in us-east-2 |
|---|---|---|
| `lab_2/samconfig.toml` | 19 `region = "us-east-1"` | `sam deploy` creates the stack **in us-east-1**; its Lambda then can't `GetObject` the code from the us-east-2 artifact bucket → cross-region error → `ROLLBACK_COMPLETE` |
| `lab_4/terraform/providers.tf` | 36 `region = "us-east-1"` | provider pinned to us-east-1, so `data.aws_rds_cluster` → `couldn't find resource` (the Aurora cluster is in us-east-2) |
| `lab_3/terraform/main.tf` | 33 `region = "us-east-1"` | **LATENT AND SNEAKY** — plan succeeds and Validate fails *as designed*, so it looks correct. But once a student remediates the fixture, **Deploy creates resources in us-east-1** |

Also latent: `lab_1/charts/myapp/templates/deployment.yaml:32` hardcodes
`AWS_REGION: "us-east-1"` (runtime), and `lab_5/charts/myapp/values.yaml:38`
does the same (lab 5 not deployed).

Proof the lab2 stacks landed in the wrong region — `list-stacks` in **us-east-1**:

```
io107-user04-97cc7d-lab2-sam-app  ROLLBACK_COMPLETE   <- us-east-2 student!
io107-user05-886efe-lab2-sam-app  ROLLBACK_COMPLETE   <- us-east-2 student!
io107-user06-acb832-lab2-sam-app  ROLLBACK_COMPLETE   <- us-east-2 student!
io107-user07-1642e5-lab2-sam-app  ROLLBACK_COMPLETE   <- us-east-2 student!
io107-user01/02/03/50-...-lab2-sam-app  CREATE_COMPLETE  (correct)
```

This is why the whole us-east-1 trial passed every check: **every prior test ran
in the one region the labs are hardcoded to.**

Note the `lab_3`/`lab_4` **buildspecs already carry comments saying "Do NOT
hardcode it, or non-us-east-1 …"** — the buildspecs were made region-agnostic but
the Terraform `provider` blocks were missed. Half-fixed.

### Fixing it is not just a local edit

`null_resource.lab{2,3,4}_seed` clones the fixtures from
**`https://github.com/roi-cloud-fun/io-107.git`** (the `origin` of this repo), not
from the local working copy. So a fix must be **committed and pushed to GitHub**
first. Worse, the seed `triggers` are only `repo_arn` / `monorepo_url` /
`fixture_subdir` — **no content hash** — so a plain re-apply will NOT re-seed.
Re-seeding needs `terraform apply -replace=null_resource.lab2_seed[0]` (etc.) per
student, or a direct push to each CodeCommit repo.

### Cleanup debt created by this bug

The 4 `ROLLBACK_COMPLETE` lab2 SAM stacks are sitting **in us-east-1** while their
owners are us-east-2 students. `teardown_complete.sh user04..07` targets
us-east-2 and **will miss them** — they must be deleted from us-east-1 explicitly.
*(Done — see §14.)*

---

## 14. Region bug FIXED and both regions verified green (2026-08-12 ~02:30)

### The fix — commit `a1bf33d`, pushed to `roi-cloud-fun/io-107` main

Pushed to **main** deliberately: the seed provisioners `git clone --depth=1` the
default branch, so a side branch would never reach students.

| File | Change |
|---|---|
| `lab_2/samconfig.toml` | dropped `region` — SAM now uses `AWS_REGION`/`AWS_DEFAULT_REGION` |
| `lab_3/terraform/main.tf` | dropped provider `region` |
| `lab_4/terraform/providers.tf` | dropped provider `region` |
| `lab_1/charts/.../deployment.yaml` | `AWS_REGION` now `{{ .Values.awsRegion \| default "us-east-1" }}` |
| `lab_1/charts/myapp/values.yaml` | added `awsRegion: ""` |
| `lab_1/buildspec.yml` | passes `--set awsRegion=$AWS_DEFAULT_REGION` |

Pre-push validation: `terraform validate` passed for lab_3 and lab_4;
`helm template` rendered `us-east-1` by default and `us-east-2` when injected.

### Re-seeding hit two NEW Windows/CodeCommit failures — both now handled

`reseed_labs.sh` (new, in `OneDrive/Code/io-107/`) forces the seed provisioners
to re-run via `-replace=null_resource.labN_seed[0]`, needed because the seed
`triggers` contain no content hash.

1. **HTTP 403 on every re-push.** `git -c credential.helper=…` *appends*; Git for
   Windows has `credential.helper = manager` at SYSTEM level, so GCM answers
   first. On the FIRST seed it has nothing cached and git falls through to the
   AWS helper — and GCM then stores that short-lived CodeCommit credential. Every
   later push replays the expired one → 403. A fresh repo always works, which is
   why this stayed hidden until the first re-seed. Fixed by resetting the helper
   list (an empty value resets it; `GIT_CONFIG_*` is read after system config but
   before `-c`):
   ```bash
   export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
   ```
2. **HTTP 429 from CodeCommit.** 4 students x 4 labs pushing at once throttled 2
   of 4. Fixed with `-parallelism=1` plus running students a couple at a time.

Both are now baked into `reseed_labs.sh` **and** `deploy_cohort_parallel.sh`.

### Verified end state — us-east-2 now matches us-east-1 exactly

All 16 us-east-2 pipelines terminal, identical per student:

```
lab1 :: Source ✓ | Build ✓
lab2 :: Source ✓ | Build ✓
lab3 :: Source ✓ | Build ✓ | Validate FAILED (correct)  | Deploy None
lab4 :: Source ✓ | Build ✓ | Validate FAILED (correct)  | Approval None | Deploy None
```

Fixture content re-verified directly out of all 16 CodeCommit repos: zero
hardcoded-region lines in lab2/lab3/lab4, `awsRegion` present in lab1.

**Definitive proof the fix worked** — each region now owns exactly its own
stacks, all `CREATE_COMPLETE`:

```
us-east-2: io107-user04/05/06/07-*-lab2-sam-app   <- was landing in us-east-1
us-east-1: io107-user50/01/02/03-*-lab2-sam-app
```

The 4 orphaned `ROLLBACK_COMPLETE` stacks from §13 were deleted from us-east-1.

### Known remaining hardcode → ✅ FIXED in commit `15a2527` (see §14b)

### Cohort status: BOTH REGIONS LIVE AND VERIFIED

8 environments, 91 resources each, 0 errors. us-east-1: user50/01/02/03.
us-east-2: user04/05/06/07.

### 14a. us-east-1 re-seeded too — all 8 students now byte-identical (02:45)

Jesse asked for us-east-1 to be re-seeded as well so both cohorts run the same
lab source (otherwise walking through e.g. `samconfig.toml` on screen would not
match half the room). Run in 2 batches of 2 students (`reseed_labs.sh user50
user01`, then `user02 user03`) to stay under the CodeCommit throttle.

**All 4 OK, no 403 and no 429** — the `GIT_CONFIG_*` helper reset and
`-parallelism=1` both held on a re-push, which is the exact case that failed
before.

Fixture content verified directly out of **all 32 CodeCommit repos** (8 students
x 4 labs): zero hardcoded-region lines in lab2/lab3/lab4, `awsRegion` present in
lab1. All 32 pipelines re-ran and returned to the correct end state — re-seeding
did **not** disturb the running environments.

### FINAL VERIFIED STATE — 2026-08-12 02:45

| | us-east-1 | us-east-2 |
|---|---|---|
| EKS clusters | 4 (4 ACTIVE) | 4 (4 ACTIVE) |
| EC2 running | 8 | 8 |
| Aurora available | 4 | 4 |
| non-default VPCs | 4 | 4 |
| CodePipelines | 16 | 16 |
| CFN stacks good / bad | 4 / **0** | 4 / **0** |
| vCPU in use / quota | 16 / 60 (44 spare) | 16 / 32 (16 spare) |

Pipeline state uniform across all 8 students: lab1 ✓, lab2 ✓,
lab3 Validate FAILED *(correct)*, lab4 Validate FAILED *(correct)*.

**Ready for class.** Burn rate ~$2.60–3.20/hr for all 8 environments.

### 14b. Lab 5 region — fixed, commit `15a2527` (03:10)

**Correcting §14's characterisation:** lab 5 was *not* broken the way labs 1–4
were. Its chart already templates `.Values.region`, the README already installs
with `--set region="$LAB5_REGION"` (fed by the `lab5_region` output), and its
provider already uses `var.aws_region`. The real defect was two **silent
defaults** — a student outside us-east-1 who omitted either one got us-east-1
with no error at all.

| Change | Effect |
|---|---|
| `terraform/variables.tf` | dropped `default = "us-east-1"` on `aws_region` — Terraform now asks, or errors under `-input=false` |
| `charts/myapp/values.yaml` + `_helpers.tpl` | `region: ""` wrapped in `required`, so a missing `--set` fails at template time naming the flag |
| `terraform.tfvars.example`, `backend.tf.example` | region fields → `REPLACE-WITH-YOUR-REGION`, matching how student_id/account are already handled, plus a cross-region note |
| `README.md` | warning under the worked example: use your own region, and how to look it up |

Why no default is right: `main_remote_state` would still read the student's
*real* state while the provider pointed at the wrong region — a confusing
cross-region failure rather than a clean one.

Verified: `terraform validate` passes and `plan -input=false` now errors with
"No value for required variable"; `helm template` without `--set region` fails
with the new message, and with it renders `AWS_REGION` correctly leaving **zero**
`us-east-1` literals in rendered output; `helm lint` clean.

Left alone: `lab_5/src/app.py`'s `or "us-east-1"` fallback, now unreachable
because the chart requires the value.

**No re-seed needed.** Confirmed there are no lab5 CodeCommit repos — students
have exactly 4 repos each (lab1–lab4) in both regions, so lab 5 is consumed
straight from the GitHub monorepo. The push is sufficient.

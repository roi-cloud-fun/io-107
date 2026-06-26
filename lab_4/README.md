# Lab 4: Aurora Blue/Green Deployment via Terraform + Pipeline

**Duration:** 30 minutes

---

## Objectives

By completing this lab, you will:

- Modify a single Terraform `local` (`target_engine_version`) to declare a new engine version for your per-student Aurora cluster.
- Push the change and observe AWS CodePipeline run `terraform plan`, OPA validation against the planned change, and a manual approval gate before any AWS RDS API call.
- Approve and observe the buildspec's apply phase drive the AWS RDS Blue/Green API — provisioning the green cluster, waiting for replication, and switching over atomically.
- Locate the blue and green clusters in the Amazon RDS console during the deployment window, and read the `CreateBlueGreenDeployment` / `SwitchoverBlueGreenDeployment` events in AWS CloudTrail.

---

## Prerequisites

Before starting this lab, ensure you have:

- [ ] Chapters 1–5 completed (you understand pipelines, IaC, OPA, and Aurora Blue/Green concepts)
- [ ] Labs 1–3 completed (you understand the per-student bootstrap, CodeCommit, OPA validation stage, and reading CodeBuild logs)
- [ ] Your per-student bootstrap is applied for Lab 4 (`enable_lab4=true`) — **your per-student Aurora cluster has been provisioned** (this takes ~10 minutes; verify `$LAB4_AURORA_CLUSTER_ID` is non-empty)
- [ ] `git` installed and CodeCommit credential helper configured (from Lab 1 Pre-Lab Setup)
- [ ] Lab instructions document open (this guide)

**Course Repository:** **[https://github.com/roi-cloud-fun/io-107](https://github.com/roi-cloud-fun/io-107)** — contains the upstream lab fixtures. Your per-student CodeCommit repo was seeded from the `lab_4/` subdirectory.

From the `lab_environment/lab_env_student/` directory, capture your env vars:

```bash
eval "$(terraform output -json | jq -r '
  to_entries[] | select(.value.value != "(disabled)") |
  "export \(.key | ascii_upcase)=\"\(.value.value)\""
')"

echo "Pipeline:       $LAB4_PIPELINE_NAME"
echo "CodeCommit:     $LAB4_CODECOMMIT_CLONE_URL"
echo "Aurora cluster: $LAB4_AURORA_CLUSTER_ID"
```

> **Why per-student Aurora?** Aurora Blue/Green deployments lock the cluster while in progress — concurrent students would collide on a shared cluster. Each student gets their own.

> **Note on the cluster's lifecycle:** The Aurora cluster is owned by `lab_env_student/` (the bootstrap), not by `lab_4/terraform/`. This lab's Terraform reads the cluster as a data source — it does NOT own the cluster. You will see why in Part 1.

---

## Part 1: Inspect the Pipeline and Terraform Wiring

### Task 1: Pre-flight Checks

1. Open your terminal. Confirm AWS CLI access and that your Aurora cluster exists:

    ```bash
    aws sts get-caller-identity
    aws rds describe-db-clusters \
        --db-cluster-identifier "$LAB4_AURORA_CLUSTER_ID" \
        --query 'DBClusters[0].[DBClusterIdentifier,Status,Engine,EngineVersion]' \
        --output table
    ```

    **Expected Result:** `describe-db-clusters` returns one row showing your cluster ID (e.g. `io107-user07-<suffix>-lab4-aurora`), `available`, `aurora-postgresql`, and the current engine version (`16.11` on first apply).

    > **Troubleshooting:** If `describe-db-clusters` returns `DBClusterNotFoundFault`, the bootstrap apply hasn't completed. Re-run `terraform apply` from `lab_env_student/` with `enable_lab4=true` and wait for `Apply complete!`.

2. Confirm your pipeline exists:

    ```bash
    aws codepipeline get-pipeline-state --name "$LAB4_PIPELINE_NAME" \
        --query 'stageStates[].[stageName,latestExecution.status]' --output table
    ```

    **Expected Result:** A table listing the pipeline's stages (`Source`, `Build`, `Validate`, `Approval`, `Deploy`).

---

### Task 2: Clone the Repository

3. Return to your home directory first (so you don't clone inside a previous lab's folder or the Terraform dir), then clone your per-student CodeCommit repo:

    ```bash
    cd ~
    git clone "$LAB4_CODECOMMIT_CLONE_URL" lab4
    cd lab4
    ```

4. Confirm you are on `main`:

    ```bash
    git branch --show-current
    ```

    **Expected Result:** `main`.

5. List the structure:

    ```bash
    ls -la
    ```

    **Expected Result:**

    ```
    lab4/
    ├── terraform/
    │   ├── aurora_cluster.tf   # data source + target-version locals + OPA shim
    │   ├── variables.tf        # declares var.cluster_identifier
    │   └── outputs.tf
    ├── policies/
    │   └── engine_version_pin.rego  # OPA gate on the target engine version
    ├── buildspec.yml           # plan / validate / apply phases
    └── README.md
    ```

---

### Task 3: Read the Terraform Wiring (read-only)

This is the most important conceptual step in the lab — read it carefully before you touch any code.

6. Open `terraform/aurora_cluster.tf`. It is unusually small. There is no `resource "aws_rds_cluster"` block in this file, even though the lab is about an Aurora cluster:

    ```hcl
    locals {
      # >>> STUDENT EDIT (next task): bump to trigger a Blue/Green engine-version upgrade <<<
      target_engine_version = "16.11"
    }

    # OPA observability shim — surfaces `target_engine_version` to Conftest as a
    # `resource_change` in the plan JSON. Without this, the value isn't visible
    # in the plan output and the policy gate can't validate it before approval.
    resource "terraform_data" "engine_version_target" {
      input = local.target_engine_version
    }

    # Read-only reference to the per-student Aurora cluster provisioned by the
    # bootstrap (lab_env_student/).
    data "aws_rds_cluster" "training" {
      cluster_identifier = var.cluster_identifier
    }
    ```

7. Open `terraform/variables.tf` and confirm `cluster_identifier` is declared:

    ```hcl
    variable "cluster_identifier" {
      description = "Identifier of the per-student Aurora cluster (provisioned by the bootstrap)."
      type        = string
    }
    ```

8. Understand why the file is shaped this way. Three reasons:

    1. **The cluster isn't owned by this lab.** It's owned by `lab_env_student/main.tf`. Re-declaring `aws_rds_cluster` here would cause a "resource already exists" conflict. The `data` source lets this lab reference cluster attributes without trying to manage them.

    2. **The Terraform AWS provider does NOT support `blue_green_update` on `aws_rds_cluster`.** That argument exists on `aws_db_instance` (single-instance RDS) but not on `aws_rds_cluster` (Aurora). Even if you DID re-declare the cluster as a managed resource, Terraform couldn't drive the Blue/Green flow — only an in-place modify, which is the unsafe path Chapter 5 told you to avoid.

    3. **The `terraform_data` shim exists to feed OPA.** Aurora Blue/Green runs from the AWS CLI inside the buildspec's apply phase (`aws rds create-blue-green-deployment` → `switchover-blue-green-deployment`), NOT from `terraform apply`. But the OPA policy gate runs against the Terraform plan JSON. If `target_engine_version` only existed as a `local`, it would never appear in plan JSON — OPA wouldn't see it. The `terraform_data.engine_version_target` resource gives Terraform a `resource_change` to emit so OPA can see and validate the value.

> **Key Insight:** The upgrade path matters more than the tool used to drive it. Aurora Blue/Green is the safe pattern whether it is invoked by Terraform, by AWS CLI in a pipeline, or by the console. The lab uses the CLI-in-buildspec approach because it is the supported path for Aurora today.

> **Note:** If you want to see the actual cluster definition (engine, parameter group, credential management, `lifecycle.ignore_changes = [engine_version]`), open `lab_environment/lab_env_student/main.tf` and search for `aws_rds_cluster.lab4_aurora`. That's where the per-student cluster is declared.

---

## Part 2: Drive an Engine Version Bump

### Task 4: Bump the Target Version

9. Edit `terraform/aurora_cluster.tf`. Make exactly one change: bump `local.target_engine_version` from `"16.11"` to `"16.13"` (your instructor will confirm the target version on the lab whiteboard if a different patch level is current):

    ```hcl
    locals {
      target_engine_version = "16.13"  # was "16.11"
    }
    ```

10. Save the file. Do not edit anything else — keep the change set minimal so the `terraform plan` output is easy to read.

> **What Just Happened?** You declared, in code, the new target engine version. The pipeline's apply phase reads this from the plan (via the `terraform_data` shim), calls `aws rds create-blue-green-deployment` with the target, waits for the green cluster, then triggers the switchover. The application connecting to the cluster's writer endpoint does not need to know any of that happened — the endpoint name does not change across switchover.

---

### Task 5: Commit and Push

11. Stage, commit, push:

    ```bash
    git add terraform/aurora_cluster.tf
    git commit -m "Lab 4: opt training-aurora into blue/green for 16.13 upgrade"
    git push origin main
    ```

---

## Part 3: Plan + OPA Validate

### Task 6: Watch the Plan Stage

12. Open the CodePipeline console and find `$LAB4_PIPELINE_NAME` (format `io107-<your-id>-<suffix>-lab4`). Watch Source → Build → Validate execute.

13. Click into the Build stage → **Details** to open the CodeBuild execution. Locate the `terraform plan` output. Because the cluster is a **data source** (read-only) and the only managed resource that touches `target_engine_version` is the `terraform_data` shim, the plan output is small:

    ```
    Terraform will perform the following actions:

      # terraform_data.engine_version_target will be updated in-place
      ~ resource "terraform_data" "engine_version_target" {
          ~ input = "16.11" -> "16.13"
            id    = "..."
        }

    Plan: 0 to add, 1 to change, 0 to destroy.
    ```

    **Expected Result:** Exactly **one** resource changing — `terraform_data.engine_version_target` — transitioning `input` from `"16.11"` to `"16.13"`.

    > **Troubleshooting:** If you see any additional resource diffs (especially anything touching `aws_rds_cluster`), reset the file: `git checkout origin/main -- terraform/aurora_cluster.tf` and reapply only the one edit.

---

### Task 7: Watch the OPA Validate Stage

14. Return to the CodePipeline view. Watch the Validate stage. Conftest runs `engine_version_pin.rego` against the plan JSON, reading the `input` field of the `terraform_data` shim resource_change and checking it against an approved-versions list.

    **Expected Result:** Validate is **Succeeded** (green) with the instructor-confirmed target version, and the pipeline proceeds to **Approval**.

    > **Troubleshooting:** If Validate is red with a message like `Aurora engine version '16.13' not in approved list`, that's a real OPA denial. Confirm with your instructor which version is approved (`policies/engine_version_pin.rego` shows the list) and use that one. Do NOT edit the OPA policy.

---

## Part 4: Approve and Apply

### Task 8: Approve the Change

15. Wait for the pipeline to reach the **Approval** stage. Aurora training is treated as prod-tier because it's a persistent data store; engine version changes are irreversible.

16. Click the **Review** button on the approval action. Read the planned change one more time. When ready, enter an approval comment (e.g. `Lab 4: approve engine bump 16.11 → 16.13 via blue/green`) and click **Approve**.

---

### Task 9: Watch the Blue/Green Deployment

17. The Deploy stage executes. Inside it, the buildspec:

    1. Reads the target version from the plan (via `jq` on `tfplan.json`).
    2. Reads the current cluster engine via `aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID"`.
    3. If they differ, calls `aws rds create-blue-green-deployment` to provision the green cluster.
    4. Calls `aws rds wait blue-green-deployment-available` while AWS provisions and replicates.
    5. Calls `aws rds switchover-blue-green-deployment` to atomically swap the cluster endpoint.
    6. Finally runs `terraform apply tfplan` for any non-engine-version changes.

    The cluster's `engine_version` itself is gated by `lifecycle.ignore_changes` in `lab_env_student/main.tf`, so Terraform does not try to modify it after the CLI has already promoted the green cluster.

> **Note:** Real Aurora Blue/Green typically takes 5-15 minutes end-to-end. `aws rds wait blue-green-deployment-available` blocks on AWS provisioning + replication catch-up; the final switchover completes in well under a minute. CodeBuild streams log output throughout — you don't need to refresh.

---

## Part 5: Observe the Switchover

### Task 10: Watch Blue and Green Clusters in the RDS Console

18. Open a second browser tab and navigate to **RDS > Databases**.

19. Find the row for your cluster (`$LAB4_AURORA_CLUSTER_ID`). While the deployment is in progress, you will see **two** related clusters:

    - The original (blue) cluster: `io107-<your-id>-<suffix>-lab4-aurora` — `available`, still serving traffic.
    - The green cluster: `io107-<your-id>-<suffix>-lab4-aurora-green-<random-suffix>` — status will transition `creating` → `available` → disappears after switchover.

    **Expected Result:** Both blue and green clusters are visible in the **Databases** list during the deployment window. Click your blue cluster → **Configuration** tab to see the active engine version transition from `16.11` to `16.13` at the moment of switchover.

20. Click the **Blue/Green Deployments** sub-section of the RDS console (left navigation) to see the deployment record itself: status transitions through `AVAILABLE` → `SWITCHOVER_IN_PROGRESS` → `SWITCHOVER_COMPLETED`, with source and target ARNs.

---

### Task 11: Find the Switchover Events in CloudTrail

21. Navigate to **CloudTrail > Event history**.

22. Filter: **Lookup attributes = Event source**, **Value = `rds.amazonaws.com`**. Time window: last 30 minutes. Optionally narrow further by **Resource name = `$LAB4_AURORA_CLUSTER_ID`**.

23. Locate the events that correspond to your Blue/Green run:

    - `CreateBlueGreenDeployment` — emitted when the buildspec invoked `aws rds create-blue-green-deployment`.
    - `ModifyDBCluster` — on the green cluster, recording the engine-version applied during green provisioning.
    - `SwitchoverBlueGreenDeployment` — emitted when the buildspec invoked `aws rds switchover-blue-green-deployment`. **This is the moment of the cluster endpoint cut-over.**

    **Expected Result:** `CreateBlueGreenDeployment` and `SwitchoverBlueGreenDeployment` both appear, sourced from `rds.amazonaws.com`, with calling identity matching the CodeBuild execution role. Clicking **SwitchoverBlueGreenDeployment** → **Event record** shows the source and target cluster ARNs and the timestamp.

> **Key Insight:** `SwitchoverBlueGreenDeployment` is the auditable record that the cluster's serving endpoint actually moved to the new engine version. `CreateBlueGreenDeployment` shows the green cluster was provisioned; only the switchover event proves the endpoint flipped.

> **What Just Happened?** A one-line edit to a Terraform `local` made the buildspec call the AWS RDS Blue/Green API, provision an entirely new Aurora cluster, replicate to it, and atomically swap the cluster endpoint — with OPA gating the version, CodePipeline gating the apply behind your explicit approval, and CloudTrail recording every API call.

---

## Checkpoint: Verify Your Progress

Before finishing, confirm you have completed:

- [ ] `aws sts get-caller-identity` and `aws rds describe-db-clusters` against `$LAB4_AURORA_CLUSTER_ID` both succeeded
- [ ] Lab 4 repo cloned and `terraform/aurora_cluster.tf` + `variables.tf` + `buildspec.yml` opened
- [ ] Confirmed `terraform/aurora_cluster.tf` declares the cluster as `data`, not `resource`, and understood why
- [ ] `local.target_engine_version` edited from `"16.11"` to the instructor-confirmed target (single-line change)
- [ ] Change committed and pushed; CodePipeline triggered
- [ ] Build stage's CodeBuild log shows exactly one resource changing (`terraform_data.engine_version_target`)
- [ ] Validate stage (OPA / Conftest) shows **Succeeded**
- [ ] Approval action was reviewed and approved with a comment
- [ ] Deploy stage's apply ran without error (CodeBuild log shows `aws rds create-blue-green-deployment` → wait → switchover → final `terraform apply`)
- [ ] Blue and green clusters were both visible in the **RDS > Databases** view during the deployment window
- [ ] **Blue/Green Deployments** RDS console page showed `AVAILABLE` → `SWITCHOVER_IN_PROGRESS` → `SWITCHOVER_COMPLETED`
- [ ] CloudTrail event history shows `CreateBlueGreenDeployment` and `SwitchoverBlueGreenDeployment` for `rds.amazonaws.com` in your apply window

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| `terraform plan` shows changes on the cluster | Plan output includes diffs on `aws_rds_cluster` resources | Reset the file: `git checkout origin/main -- terraform/aurora_cluster.tf` and reapply only the `local.target_engine_version` edit. |
| `data "aws_rds_cluster"` fails to find the cluster | Plan fails with `DBClusterNotFoundFault` | The bootstrap apply didn't complete. Re-run `terraform apply` from `lab_env_student/`. |
| Validate stage fails with engine-version denial | Conftest output names the engine version | Real OPA denial. Confirm the approved versions list in `policies/engine_version_pin.rego` and use one of them. Don't edit the policy. |
| Apply hangs in `Still modifying...` for > 15 min | Deploy stage looks stuck | Open RDS console → **Blue/Green Deployments**. If `SWITCHOVER_IN_PROGRESS`, replication lag isn't zero yet (active writers somewhere). Pause writers; Aurora completes once lag reaches zero. |
| `CreateBlueGreenDeployment` fails with master-credential combination | `Error: Cannot use ... and ... simultaneously` | Aurora Blue/Green historically didn't support Secrets-Manager-managed master credentials. AWS relaxed this in late 2024 but specific engine versions may still be affected. Tell your instructor — they'll switch `lab_env_student/main.tf` to literal `master_password`. |
| CloudTrail does not show `SwitchoverBlueGreenDeployment` | Event missing from filter | CloudTrail can lag up to 15 min. Widen the time window. If still missing after 30 min, the apply didn't reach the switchover phase — re-read the CodeBuild Deploy log. |

---

## Cost Considerations

Aurora Blue/Green provisions a full second cluster (the green) for the duration of the deployment. The green cluster is billed at full Aurora rates while it exists (~15 min).

| Component | Type | Hourly Cost |
|-----------|------|-------------|
| Amazon Aurora (blue cluster, training-tier instance) | Per-student cluster | ~$0.08/hour |
| Amazon Aurora (green cluster, ~15 min) | Full-rate during deployment | ~$0.02 (~$0.08/hour × 0.25 hour) |
| Aurora storage (copy-on-write green) | Per GB-month | <$0.01 share |
| AWS CodePipeline (one active pipeline) | Per active pipeline-month | <$0.02/hour share |
| AWS CodeBuild (plan + validate + apply minutes) | `general1.small` build-minute | ~$0.005/build-minute |
| AWS CloudTrail (Event history, free tier) | Management events | $0 |
| **Total (this lab, ~30 min)** | | **~$0.05-$0.15** |

<!-- source: https://aws.amazon.com/rds/aurora/pricing/ + https://aws.amazon.com/codepipeline/pricing/ verified 2026-04-07 -->

**Cleanup:** The per-student Aurora cluster, the AWS CodePipeline, and the AWS CodeBuild project are torn down by `terraform destroy` against `lab_env_student/` at end-of-cohort — do not delete them manually mid-cohort, and do not run `terraform destroy` against this lab's own `lab_4/terraform/` directory (it has no managed resources to destroy, only a data source). The green cluster tears itself down automatically when the Blue/Green deployment completes its switchover.

---

## Knowledge Check

**Question 1:** Why does the pipeline require a manual approval gate before the apply phase runs against your Aurora cluster, when Lab 1's EKS pipeline targeting `dev` did not? Refer to what Chapter 5 said about the difference between application deployments and database changes.
<!-- source: Module_5_narrative.md §"Section 1: Why Pipeline-Driven Database Changes" -->

**Question 2:** This lab's `terraform/aurora_cluster.tf` declares the cluster as a `data` source rather than a `resource`, and adds a small `terraform_data.engine_version_target` shim. Explain (a) where the actual `aws_rds_cluster` resource is declared, (b) why declaring it twice would break the pipeline, and (c) what specific job the `terraform_data` shim does that wouldn't happen if `target_engine_version` were left as a bare `local`.
<!-- source: Module_5_narrative.md §"Section 4: Aurora Blue/Green Deployments" + lab_env_student/main.tf -->

**Question 3:** Naming the RDS API events you saw in CloudTrail, which is the **auditable** record that the cluster's serving endpoint actually moved to the new engine version? Why is observing the others not sufficient for compliance evidence?
<!-- source: Module_5_narrative.md §"Section 4: Aurora Blue/Green Deployments" -->

**Question 4:** A teammate proposes "speeding up the Lab 4 pattern in production" by removing the `terraform_data.engine_version_target` marker, dropping `lifecycle.ignore_changes` on the `aws_rds_cluster` (in `lab_env_student/`), and just letting `terraform apply` do an in-place engine upgrade. Citing Chapter 5, give two reasons that is unacceptable for a prod-tier Aurora cluster.
<!-- source: Module_5_narrative.md §"Section 4: Aurora Blue/Green Deployments" -->

*Answers are in the Knowledge Check Bank.*

---

## Next Steps

This is the final hands-on lab in IO-107. The course wrap-up ties the four labs back to the end-to-end SDLC model: container deployments (Lab 1), serverless deployments (Lab 2), policy enforcement (Lab 3), and data-tier changes (Lab 4) — all driven by the same pipeline pattern with the same guardrails.

---

## Resources

- [Amazon RDS User Guide — Blue/Green Deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html)
- [Amazon RDS User Guide — Viewing a Blue/Green Deployment](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-viewing.html)
- [Amazon RDS API Reference — ModifyDBCluster](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_ModifyDBCluster.html)
- [Terraform AWS provider — `aws_rds_cluster`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster)
- [Terraform AWS provider — `data "aws_rds_cluster"`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/rds_cluster)
- [Terraform — `terraform_data` resource](https://developer.hashicorp.com/terraform/language/resources/terraform-data)
- [AWS CloudTrail User Guide — Logging Amazon RDS API calls](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/logging-using-cloudtrail.html)
- [AWS CodePipeline User Guide — Manage Approval Actions](https://docs.aws.amazon.com/codepipeline/latest/userguide/approvals-action-add.html)

---

*Lab 4 Complete*

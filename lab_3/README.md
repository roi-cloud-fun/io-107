# Lab 3: Policy-as-Code Evaluation and Failure Remediation

**Duration:** 45 minutes

---

## Objectives

By completing this lab, you will:

- Identify the policy violations in a deliberately broken Terraform + Kubernetes manifest by reading the resource definitions against the OPA Rego policies (naming, encryption, tagging, Lambda timeout, EKS image registry, container resource limits).
- Trigger the pipeline, observe AWS CodePipeline halt at the OPA validation stage, and read the Conftest `FAIL` lines in the AWS CodeBuild log.
- Remediate every violation by editing only the resource definitions — never the policies themselves.
- Re-run the pipeline and confirm Conftest reports zero failures, allowing the deploy stage to proceed.

---

## Prerequisites

Before starting this lab, ensure you have:

- [ ] Chapter 6 (Policy-as-Code with OPA) completed
- [ ] Labs 1–2 completed (you understand the per-student bootstrap, CodeCommit, and CodeBuild log mechanics)
- [ ] Your per-student bootstrap is applied for Lab 3 (`enable_lab3=true`) — your `LAB3_*` env vars are non-empty
- [ ] `git` installed and CodeCommit credential helper configured (from Lab 1 Pre-Lab Setup)
- [ ] Lab instructions document open (this guide)

**Course Repository:** **[https://github.com/roi-cloud-fun/io-107](https://github.com/roi-cloud-fun/io-107)** — contains the upstream lab fixtures. Your per-student CodeCommit repo was seeded from the `lab_3/` subdirectory.

From the `lab_environment/lab_env_student/` directory, capture your env vars:

```bash
eval "$(terraform output -json | jq -r '
  to_entries[] | select(.value.value != "(disabled)") |
  "export \(.key | ascii_upcase)=\"\(.value.value)\""
')"

echo "Pipeline:    $LAB3_PIPELINE_NAME"
echo "CodeCommit:  $LAB3_CODECOMMIT_CLONE_URL"
```

---

## Part 1: Inspect the Broken Code

### Task 1: Clone the Repository

1. Open your terminal. Clone your per-student CodeCommit repo:

    ```bash
    git clone "$LAB3_CODECOMMIT_CLONE_URL" lab3
    cd lab3
    ```

2. List the top-level structure:

    ```bash
    ls -la
    ```

    **Expected Result:**

    ```
    lab3/
    ├── terraform/
    │   ├── main.tf          # Infrastructure with violations
    │   └── ...
    ├── kubernetes/
    │   └── deployment.yaml  # K8s manifest with violations
    ├── policies/
    │   ├── naming.rego
    │   ├── encryption.rego
    │   ├── tagging.rego
    │   ├── lambda.rego
    │   └── eks.rego
    ├── src/
    │   └── app.py
    ├── buildspec.yml
    └── README.md
    ```

3. Confirm you are on `main`:

    ```bash
    git branch --show-current
    ```

    **Expected Result:** `main`.

> **Note:** This repository is deliberately broken at the resource level. The infrastructure described inside will never reach AWS in this state — the OPA policy stage is designed to stop it. Your goal is to make the policies pass without weakening them.

---

### Task 2: Identify the Terraform Violations

4. Open `terraform/main.tf`. You will see an S3 bucket, a Lambda function, and the Lambda's execution role. The bucket and the function are deliberately non-compliant; the execution role is NOT a violation — it's wired in so `terraform apply` will run once the real violations are fixed:

    ```hcl
    # Lambda execution role -- NOT a teaching target.
    data "aws_iam_policy_document" "lambda_assume" {
      statement {
        actions = ["sts:AssumeRole"]
        principals {
          type        = "Service"
          identifiers = ["lambda.amazonaws.com"]
        }
      }
    }

    resource "aws_iam_role" "lambda_exec" {
      name               = "lab3-lambda-exec"
      assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
    }

    resource "aws_iam_role_policy_attachment" "lambda_basic" {
      role       = aws_iam_role.lambda_exec.name
      policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
    }

    # VIOLATION 1: Bucket naming
    # VIOLATION 2: Missing encryption resource
    # VIOLATION 3: Missing required tags
    resource "aws_s3_bucket" "data_bucket" {
      bucket = "my-bucket"

      tags = {
        Name = "My Bucket"
      }
    }

    # VIOLATION 4: Lambda timeout > 300s
    # VIOLATION 5: Lambda missing required tags
    resource "aws_lambda_function" "processor" {
      function_name    = "data-processor"
      runtime          = "python3.11"
      handler          = "app.handler"
      timeout          = 600
      memory_size      = 512
      filename         = data.archive_file.processor_zip.output_path
      source_code_hash = data.archive_file.processor_zip.output_base64sha256
      role             = aws_iam_role.lambda_exec.arn

      tags = {
        Name = "Processor"
      }
    }
    ```

5. List the Terraform-side violations before running the pipeline. From the file:

    - S3 bucket name `my-bucket` does not match `client-{env}-{app}-{purpose}`.
    - S3 bucket has no paired `aws_s3_bucket_server_side_encryption_configuration` resource.
    - S3 bucket is missing required tags `Environment`, `Application`, `Owner`, `CostCenter`, `DataClass`.
    - Lambda function `data-processor` has `timeout = 600`, exceeds the 300-second maximum.
    - Lambda function is missing the same required tags (minus `DataClass` — only applies to data-handling resources).

> **Note:** The execution role attached to the Lambda is intentionally NOT one of the violations. Chapter 6's policy library does not enforce anything on the execution role — the bucket and the function are the teaching targets. The role is here because Terraform's `aws_lambda_function` schema requires the `role` argument and `terraform plan` would fail without it.

---

### Task 3: Identify the Kubernetes Violations

6. Open `kubernetes/deployment.yaml`. The manifest deploys a single-replica web app — and breaks three EKS-specific policies:

    ```yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: myapp
      namespace: default
      # VIOLATION: Missing required labels
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: myapp
      template:
        metadata:
          labels:
            app: myapp
        spec:
          containers:
            - name: myapp
              # VIOLATION: Image from unapproved registry
              image: docker.io/library/nginx:latest
              # VIOLATION: Missing resource limits
              ports:
                - containerPort: 80
    ```

7. Add the Kubernetes-side violations to your list:

    - Deployment metadata is missing the required labels `environment` and `owner`.
    - Container `myapp` pulls from `docker.io/library/nginx:latest`. Only AWS-hosted images allowed (per-account ECR or `public.ecr.aws/*`).
    - Container `myapp` has no `resources.limits` block — neither memory nor CPU.

> **Key Insight:** Open `policies/eks.rego` and look at the two approved-registry regexes. `approved_ecr_private_regex` (`^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/`) matches any 12-digit AWS account's private ECR; `approved_ecr_public_regex` (`^public\.ecr\.aws/`) matches Amazon's public mirror. The intent is "must come from AWS-hosted infrastructure (not Docker Hub, not GHCR)". The per-account regex is NOT pinned to a specific account because each student has their own.

> **What Just Happened?** You read the rules off the resource definitions before deployment, with no console or wiki lookup. Every item on your list maps directly to a Rego rule.

---

## Part 2: Watch the Pipeline Fail

### Task 4: Trigger and Observe the Failure

8. Make a trivial change to force a new commit:

    ```bash
    echo "# Lab 3 test run" >> terraform/main.tf
    ```

9. Stage, commit, and push to trigger CodePipeline:

    ```bash
    git add terraform/main.tf
    git commit -m "Lab 3: trigger OPA validation run"
    git push origin main
    ```

10. Open the AWS CodePipeline console and find your pipeline (`$LAB3_PIPELINE_NAME`). Watch the stages execute.

    **Expected Result:** AWS CodePipeline shows four stages — **Source**, **Build**, **Validate**, **Deploy**. Source and Build succeed (green); Validate fails (red); Deploy does not run. The pipeline overall status is **Failed**.

> **Note on the pipeline shape:** This pipeline has four stages. Build runs `terraform plan` and produces a `tfplan.json` artifact. Validate runs `conftest test tfplan.json` against that artifact — this is the policy gate. Deploy runs `terraform apply` + `kubectl apply` only if Validate passed. All three CodeBuild stages reuse the same CodeBuild project; the pipeline overrides a `LAB_PHASE` environment variable per stage so the buildspec runs the right phase.

> **Note:** The pipeline runs OPA against the Terraform PLAN JSON, not the raw `.tf` source. The Build stage runs `terraform plan -out=tfplan` and `terraform show -json tfplan > tfplan.json`, passes them as artifacts to Validate, which runs Conftest against the plan output. The `tfplan.json` is generated at runtime and not checked into the repo.

---

### Task 5: Read the Conftest Output

11. Click into the failed **Validate** stage → **Details** to open the CodeBuild execution that ran Conftest.

12. Scroll the log to the Conftest output section. Expect lines like these (totals may differ slightly — match each `FAIL` to a rule, don't depend on line count):

    ```
    Running policy validation...

    FAIL - tfplan.json - main - S3 bucket 'my-bucket' does not match naming pattern 'client-{env}-{app}-{purpose}'
    FAIL - tfplan.json - main - S3 bucket 'data_bucket' must have server-side encryption enabled
    FAIL - tfplan.json - main - S3 bucket 'data_bucket' missing required tag: Environment
    FAIL - tfplan.json - main - S3 bucket 'data_bucket' missing required tag: Application
    FAIL - tfplan.json - main - S3 bucket 'data_bucket' missing required tag: Owner
    FAIL - tfplan.json - main - S3 bucket 'data_bucket' missing required tag: CostCenter
    FAIL - tfplan.json - main - S3 bucket 'data_bucket' missing required tag: DataClass
    FAIL - tfplan.json - main - Lambda 'data-processor' timeout 600 exceeds maximum of 300 seconds
    FAIL - tfplan.json - main - Lambda 'data-processor' missing required tag: Environment
    FAIL - tfplan.json - main - Lambda 'data-processor' missing required tag: Application
    FAIL - tfplan.json - main - Lambda 'data-processor' missing required tag: Owner
    FAIL - tfplan.json - main - Lambda 'data-processor' missing required tag: CostCenter
    FAIL - kubernetes/deployment.yaml - main - Container 'myapp' must have memory limit defined
    FAIL - kubernetes/deployment.yaml - main - Container 'myapp' must have CPU limit defined
    FAIL - kubernetes/deployment.yaml - main - Container 'myapp' uses image from unapproved registry 'docker.io'
    FAIL - kubernetes/deployment.yaml - main - Deployment 'myapp' missing required label: environment
    FAIL - kubernetes/deployment.yaml - main - Deployment 'myapp' missing required label: owner

    Policy validation failed. Fix violations before deployment.
    ```

13. Map each `FAIL` line to your list from Tasks 2-3. For each:

    1. Read the message — what is wrong?
    2. Identify the resource named in the message.
    3. Find that resource in `terraform/main.tf` or `kubernetes/deployment.yaml`.
    4. Confirm what the policy requires (`policies/*.rego` has the actual rules).
    5. Plan the smallest change that satisfies the policy.

> **What Just Happened?** The Validate stage exited with a non-zero status because Conftest produced at least one denial. That non-zero exit code is what causes AWS CodePipeline to fail the stage and stop progression. No human-in-the-loop blocked anything — the policy engine did.

---

## Part 3: Remediate the Violations

### Task 6: Fix the Terraform File

14. Edit `terraform/main.tf`. Leave the execution role + assume-role policy doc + role-policy attachment as-is. Edit the `aws_s3_bucket`, add the missing `aws_s3_bucket_server_side_encryption_configuration`, and fix the `aws_lambda_function`.

    > **Bucket name uniqueness:** S3 bucket names are globally unique across all AWS accounts. The policy regex (`policies/naming.rego`) is `^client-(dev|stg|prd)-[a-z0-9]+-[a-z0-9-]+$` — `client-`, then env, then app (letters + digits), then purpose (letters + digits + hyphens). Use the `purpose` segment for your unique identifier: your student ID, initials, or anything that distinguishes your bucket from your classmates'.

    Replace `<your-id>` below with something unique (e.g. `alice`, `bob`, `student-07`). Don't use `client-dev-lab3-data` literally — your classmate just claimed it.

    ```hcl
    # FIXED: Bucket name matches client-{env}-{app}-{purpose}
    #        Replace <your-id> with your unique student identifier.
    # FIXED: Required tags added
    resource "aws_s3_bucket" "data_bucket" {
      bucket = "client-dev-lab3-<your-id>"

      tags = {
        Environment = "dev"
        Application = "lab3"
        Owner       = "training@client.com"
        CostCenter  = "CC-TRAINING"
        DataClass   = "internal"
      }
    }

    # FIXED: Paired encryption configuration resource (SSE-S3 / AES256)
    resource "aws_s3_bucket_server_side_encryption_configuration" "data_bucket" {
      bucket = aws_s3_bucket.data_bucket.id

      rule {
        apply_server_side_encryption_by_default {
          sse_algorithm = "AES256"
        }
      }
    }

    # FIXED: Timeout within limit + all required tags
    resource "aws_lambda_function" "processor" {
      function_name    = "data-processor"
      role             = aws_iam_role.lambda_exec.arn
      runtime          = "python3.11"
      handler          = "app.handler"
      timeout          = 30
      memory_size      = 512
      filename         = data.archive_file.processor_zip.output_path
      source_code_hash = data.archive_file.processor_zip.output_base64sha256

      tags = {
        Environment = "dev"
        Application = "lab3"
        Owner       = "training@client.com"
        CostCenter  = "CC-TRAINING"
      }
    }
    ```

15. Verify each fix matches the original `FAIL` lines:

    - Bucket name matches the `client-{env}-{app}-{purpose}` regex.
    - Standalone `aws_s3_bucket_server_side_encryption_configuration` resource paired with the bucket. (Inline `server_side_encryption_configuration` blocks on `aws_s3_bucket` were removed from the schema in AWS provider v4.0; using one is a `terraform plan` error, not a policy failure.)
    - All four required tags present on both resources, plus `DataClass` on the S3 bucket.
    - Lambda timeout reduced to `30` — well below the 300-second cap.

> **Common Pitfall:** Don't "fix" a tagging policy by removing the resource, and don't "fix" the timeout policy by raising the cap. Both work-arounds defeat the guardrail. Per Chapter 6, policy changes go through PR review on the policy repo, not local edits.

---

### Task 7: Fix the Kubernetes Manifest

The EKS policy accepts images from EITHER your per-account ECR OR `public.ecr.aws/*` (Amazon's public mirror — anonymous-pull, no rate limits). For the default lab path, use `public.ecr.aws/docker/library/nginx:1.21` — it works out of the box. The per-account ECR option is covered as a bonus below.

16. Edit `kubernetes/deployment.yaml`. Replace its contents with the remediated version:

    ```yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: myapp
      namespace: lab3
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
              # FIXED: Image from Amazon ECR Public Gallery (allowed by policy)
              image: public.ecr.aws/docker/library/nginx:1.21
              ports:
                - containerPort: 80
              # FIXED: Memory and CPU limits + requests
              resources:
                limits:
                  memory: "256Mi"
                  cpu: "500m"
                requests:
                  memory: "128Mi"
                  cpu: "100m"
    ```

17. Confirm the EKS-specific policies are satisfied:

    - `metadata.labels` and the pod template's `metadata.labels` both carry `environment` and `owner`.
    - `image:` matches `approved_ecr_public_regex` (`^public\.ecr\.aws/`). Per-account ECR is also accepted — see the bonus task below.
    - `resources.limits.memory` and `resources.limits.cpu` are both set.
    - Image is pinned to a specific version (`1.21`) rather than `latest`.

> **Bonus (instructor demo): use per-account ECR instead.** [Client]'s production rule is "no public registries at runtime — all images flow through the controlled per-account ECR boundary." Your instructor will demo mirroring `nginx:1.21` from `public.ecr.aws` into your per-student ECR via `docker pull` → `docker tag` → `docker push`. After the demo, you can update your manifest to use `<your-account-id>.dkr.ecr.us-east-1.amazonaws.com/nginx:1.21` instead of `public.ecr.aws/...`, push, and watch the pipeline pass with the production-style image source.

> **Note:** The remediated manifest also moves the workload out of `default` namespace and into `lab3`. This is not enforced by an OPA policy — it's a best practice carried over from Lab 1's `lab1-<student-id>` pattern, so each lab's resources stay isolated.

---

## Part 4: Watch the Pipeline Pass

### Task 8: Re-run the Pipeline

19. Stage, commit, and push both files:

    ```bash
    git add terraform/main.tf kubernetes/deployment.yaml
    git commit -m "Lab 3: remediate all OPA policy violations"
    git push origin main
    ```

20. Return to the CodePipeline console and watch the new execution.

    **Expected Result:** CodePipeline shows all four stages — **Source**, **Build**, **Validate**, **Deploy** — as **Succeeded** (green). The Validate stage that turned red on the previous run is now green, and Deploy runs to completion.

21. Click into the **Validate** stage's CodeBuild execution and confirm the Conftest summary now reports zero failures:

    ```
    Running policy validation...

    (no FAIL lines)
    ```

22. Click into the **Deploy** stage's CodeBuild execution. Confirm `terraform apply tfplan` and `kubectl apply -f kubernetes/deployment.yaml` ran without error.

    **Expected Result:** Overall pipeline status reads **Succeeded**, all four stage tiles green. Your `client-dev-lab3-<your-id>` S3 bucket and the `myapp` Deployment in namespace `lab3` now exist.

> **What Just Happened?** You took a deployment that was blocked by every policy denial Conftest could produce and made it deployable by changing only the resource definitions — never the policies themselves. That is the policy-as-code workflow: policies are the contract, the pipeline enforces them, and the human work is bringing the configuration into compliance.

---

## Checkpoint: Verify Your Progress

Before finishing, confirm you have completed:

- [ ] Repo cloned and `terraform/main.tf`, `kubernetes/deployment.yaml`, `policies/`, `buildspec.yml` opened
- [ ] Identified that the Lambda execution role is scaffolding, NOT a violation
- [ ] Terraform violations enumerated on paper before running the pipeline
- [ ] Kubernetes violations enumerated on paper before running the pipeline
- [ ] First pipeline run reached the **Validate** stage and failed
- [ ] Conftest output located in the Validate stage's CodeBuild log
- [ ] Each `FAIL` line mapped back to its source rule and source file
- [ ] S3 bucket renamed to match `client-{env}-{app}-{purpose}` pattern
- [ ] Separate `aws_s3_bucket_server_side_encryption_configuration` resource added
- [ ] All required tags added to both Terraform resources (+ `DataClass` on S3)
- [ ] Lambda `timeout` reduced to a value ≤ 300
- [ ] Container image swapped from `docker.io/library/nginx:latest` to `public.ecr.aws/docker/library/nginx:1.21` (or, after the instructor's bonus demo, your own per-account ECR), pinned to a version
- [ ] Container `resources.limits` block added with both `memory` and `cpu`
- [ ] `environment` and `owner` labels added at Deployment + pod-template level
- [ ] Re-run pipeline shows Conftest reporting zero failures
- [ ] Pipeline reaches overall **Succeeded**

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| Pipeline doesn't trigger after push | No new execution in CodePipeline | Verify you pushed to `main`. If pushed to a feature branch, merge or push to main. |
| Conftest output empty in CodeBuild log | Build phase completed but no FAIL/PASS lines | Build phase failed before Conftest could run. Look earlier in the log for terraform plan errors. |
| Re-run still shows S3 encryption failure | Validate stage red after remediation | You added an inline `server_side_encryption_configuration {}` block instead of a separate `aws_s3_bucket_server_side_encryption_configuration` resource. The inline form was removed from the AWS provider schema in v4.0. |
| Lambda still flagged for missing tag | Conftest log shows tag-missing FAIL after you added the tag | Tag keys are case-sensitive. Confirm exact spelling: `Environment`, not `environment`. |
| Container image policy still fails | "uses image from unapproved registry" after you changed it | Confirm the image string starts with EITHER a 12-digit account `.dkr.ecr.<region>.amazonaws.com/` OR `public.ecr.aws/`. No `docker.io/`, `ghcr.io/`, or bare `nginx:latest`. |
| Pod stuck in `ImagePullBackOff` (bonus per-account ECR path) | Pod can't pull from your per-account ECR | The `nginx:1.21` image isn't in your per-account ECR yet -- run the instructor's `docker pull / tag / push` flow first. If you're on the default `public.ecr.aws` path, this shouldn't happen. |
| Deploy stage fails after Validate passes | Deploy stage red but Validate was green | OPA gate passed; the actual apply hit a different problem (IAM perms, network, K8s namespace). Read the Deploy stage's CodeBuild log. |

---

## Cost Considerations

Lab 3 is almost entirely a *policy evaluation* exercise — the Validate stage stops the pipeline before any chargeable resources are created on the first run, and the remediated re-run deploys only small training-scale resources.

| Component | Type | Approximate Cost |
|-----------|------|------------------|
| AWS CodePipeline (one active pipeline) | Per active pipeline-month | <$0.02/hour share |
| AWS CodeBuild (build + validate minutes) | `general1.small` build-minute | ~$0.005/build-minute |
| Amazon S3 bucket (empty) | Standard storage | <$0.01/hour share |
| AWS Lambda function (idle) | Per-request + GB-second | $0 at zero invocations |
| Amazon EKS workload (1 pod) | Fraction of shared worker | ~$0.01/hour share |
| **Total (this lab, ~45 min)** | | **~$0.05** |

<!-- source: https://aws.amazon.com/codepipeline/pricing/ + https://aws.amazon.com/codebuild/pricing/ verified 2026-04-07 -->

**Cleanup:** The CodePipeline, CodeBuild project, IAM roles, and S3 artifact bucket persist between cohorts. To release just the resources your remediated push created:

```bash
kubectl delete -f kubernetes/deployment.yaml
kubectl delete namespace lab3
```

The Terraform-created S3 bucket and Lambda function are torn down by `terraform destroy` against `lab_env_student/` at end-of-cohort — do not run `terraform destroy` directly against the shared training account unless your instructor asks.

---

## Knowledge Check

**Question 1:** The pipeline runs OPA against the plan JSON output, not against `terraform/main.tf`. Why does the validation stage evaluate the Terraform *plan* in JSON form rather than the source `.tf` file directly?
<!-- source: Module_6_narrative.md §"Terraform Plan Evaluation" -->

**Question 2:** The EKS policy accepts EITHER per-account ECR (regex over "any 12-digit AWS account") OR `public.ecr.aws/*`. Why is the per-account regex written as "any 12-digit account" rather than pinned to one specific account? Why is ECR Public allowed at all when [Client]'s production rule is "private ECR only"?
<!-- source: policies/eks.rego + Module_6_narrative.md §"EKS-Specific Policies" -->

**Question 3:** A teammate proposes "fixing" the Lambda timeout violation by editing the OPA policy to raise the maximum from 300 to 900 seconds. Why is this not an acceptable remediation?
<!-- source: Module_6_narrative.md §"Section 6: Policy Versioning and Lifecycle" -->

**Question 4:** Name the three EKS-specific violations you remediated. For each, identify the class of failure it would have caused in production (cost / blast-radius / supply-chain / operational).
<!-- source: Module_6_narrative.md §"EKS-Specific Policies" -->

*Answers are in the Knowledge Check Bank.*

---

## Next Steps

In **Lab 4: Aurora Blue/Green Deployment via Terraform + Pipeline**, you'll bump the target engine version on an Amazon Aurora PostgreSQL cluster through the same pipeline shape (Source → Plan → OPA Validate → Approval → Apply), then watch AWS RDS provision a green cluster and switch the cluster endpoint over atomically. The pipeline-driven model is the same; the workload changes from compute to a stateful data tier with zero-downtime upgrade guarantees.

---

## Resources

- [Open Policy Agent — Documentation](https://www.openpolicyagent.org/docs/latest/)
- [Conftest — Documentation](https://www.conftest.dev/)
- [Rego built-in functions — `regex.match`](https://www.openpolicyagent.org/docs/latest/policy-reference/#builtin-regex-regexmatch)
- [AWS CodePipeline User Guide](https://docs.aws.amazon.com/codepipeline/latest/userguide/)
- [Terraform AWS provider — `aws_s3_bucket_server_side_encryption_configuration`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration)
- [Amazon ECR — Private repository concepts](https://docs.aws.amazon.com/AmazonECR/latest/userguide/Repositories.html)
- [Kubernetes — Resource limits on Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

---

*Lab 3 Complete*

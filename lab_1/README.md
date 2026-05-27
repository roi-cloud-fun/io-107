# Lab 1: End-to-End EKS Deployment Pipeline

**Duration:** 60 minutes

---

## Objectives

By completing this lab, you will:

- Clone your per-student CodeCommit repository and inspect the application code, Helm chart, and `buildspec.yml` that drives the AWS CodeBuild stage.
- Walk through the three places the IRSA role ARN lives (bootstrap output, CodeBuild environment variable, Helm `--set` injection) and explain why none of them is hardcoded in committed YAML.
- Modify a Helm value, push to your CodeCommit repo, and observe the resulting AWS CodePipeline execution end-to-end through the Build stage to a live `helm upgrade` against Amazon EKS.
- Verify the deployed pods, the LoadBalancer service, and that IRSA (IAM Roles for Service Accounts) is granting the pod AWS API access without static credentials.

---

## Prerequisites

Before starting this lab, ensure you have:

- [ ] Chapters 1–3 completed (you understand pipelines, IaC, and the EKS deployment model)
- [ ] Your per-student bootstrap has been applied — your CodeCommit repo, CodePipeline, CodeBuild project, EKS namespace, and IRSA roles exist
- [ ] AWS CLI v2 + `kubectl` + `git` installed on your lab workstation (or available in the shared lab EC2 host)
- [ ] Your IAM identity has access to the training AWS account
- [ ] Lab instructions document open (this guide)

**Course Repository:** **[https://github.com/roi-cloud-fun/io-107](https://github.com/roi-cloud-fun/io-107)** — contains the upstream lab fixtures. Your per-student CodeCommit repo was seeded from the `lab_1/` subdirectory.

Before you begin, capture your per-student environment variables. From the `lab_environment/lab_env_student/` directory, run:

```bash
eval "$(terraform output -json | jq -r '
  to_entries[] | select(.value.value != "(disabled)") |
  "export \(.key | ascii_upcase)=\"\(.value.value)\""
')"

# Sanity check — all should print non-empty values
echo "CodeCommit:   $LAB1_CODECOMMIT_CLONE_URL"
echo "Pipeline:     $LAB1_PIPELINE_NAME"
echo "Namespace:    $LAB1_NAMESPACE"
echo "Cluster:      $EKS_CLUSTER_NAME"
echo "IRSA (dev):   $LAB1_MYAPP_DEV_ROLE_ARN"
echo "IRSA (stg):   $LAB1_MYAPP_STG_ROLE_ARN"
```

> **Note:** The variables persist for the rest of this shell session. If you open a new terminal, re-run the `eval` block.

Then configure git to authenticate with CodeCommit (one-time per shell, uses your IAM identity — no SSH keys needed):

```bash
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
```

> **Why per-student?** IRSA roles bind to a specific Kubernetes ServiceAccount in a specific namespace — your role trusts only your namespace, not anyone else's. Your pipeline is wired to your own CodeCommit repo so your `git push` triggers your build only.

---

## Part 1: Inspect the Application and Pipeline Configuration

### Task 1: Clone Your Per-Student Repository

1. Open your terminal. Confirm the env vars from the Pre-Lab Setup are loaded by running `echo $LAB1_CODECOMMIT_CLONE_URL` — it should print a `https://git-codecommit.us-east-1.amazonaws.com/...` URL. If empty, re-run the `eval` block above.

2. Clone your per-student CodeCommit repo. The bootstrap seeded it from the upstream `roi-cloud-fun/io-107` repo's `lab_1/` subdirectory:

    ```bash
    git clone "$LAB1_CODECOMMIT_CLONE_URL" myapp
    cd myapp
    ```

3. List the top level and confirm the structure:

    ```bash
    ls -la
    ```

**Expected Result:**

```
myapp/
├── src/                    # Flask application source code
├── charts/
│   └── myapp/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-dev.yaml
│       ├── values-stg.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── serviceaccount.yaml
├── Dockerfile
├── buildspec.yml
└── README.md
```

> **Note:** If `git clone` returns an authentication error, confirm you ran the credential-helper config in the Prerequisites section. The error message is usually `fatal: could not read Username`.

---

### Task 2: Read the buildspec.yml

4. Open `buildspec.yml` in your editor. It is the contract between your `git push` and the cluster. Walk through each phase:

    - **install** — installs Helm and configures `kubectl` against the cluster.
    - **pre_build** — authenticates to ECR, derives the image tag from the commit SHA.
    - **build** — runs `docker build` and `docker push` to your per-student ECR repo.
    - **post_build** — picks the per-environment IRSA role ARN, runs `helm upgrade --install` with three `--set` overrides, waits for the rollout.

5. Note three things in particular:

    - `aws eks update-kubeconfig` writes a kubeconfig for the CodeBuild role so `kubectl` and `helm` authenticate to the cluster.
    - The `--atomic` flag on `helm upgrade --install` causes Helm to automatically roll back the release if any resource fails to become ready within `--timeout`. `--atomic` is required in all production pipelines.
    - The three `--set` flags (`image.repository`, `image.tag`, `serviceAccount.annotations…role-arn`) inject per-student, per-environment values into the chart at deploy time. **None of these values are hardcoded in committed YAML.**

> **Key Insight:** The `buildspec.yml` is the single, reviewable source for how Amazon EKS will be updated. There is no console click path that performs this deployment. That is the central guardrail of the SDLC model.

---

### Task 3: Trace Where the IRSA Role ARN Comes From

The chart's `values.yaml` ships with `eks.amazonaws.com/role-arn: ""`. Your real role is `io107-<your-id>-<suffix>-myapp-dev-role` in your own AWS account. Reconcile these by walking through the three places the ARN lives.

6. **Bootstrap output.** Confirm the bootstrap published your real ARN as an output:

    ```bash
    echo "$LAB1_MYAPP_DEV_ROLE_ARN"
    ```

    **Expected Result:** A non-empty ARN of the form `arn:aws:iam::<your-account>:role/io107-<your-id>-<suffix>-myapp-dev-role`. If empty, re-run the Pre-Lab Setup `eval` block.

7. **CodeBuild env var.** Confirm the bootstrap also injected that ARN into your CodeBuild project's environment variables:

    ```bash
    aws codebuild batch-get-projects --names "$LAB1_CODEBUILD_PROJECT" \
      --query 'projects[0].environment.environmentVariables[?starts_with(name,`IRSA_ROLE_ARN`)]' --output table
    ```

    **Expected Result:** Two rows — `IRSA_ROLE_ARN_DEV` and `IRSA_ROLE_ARN_STG` — each holding the ARN of the matching IAM role.

8. **Pipeline injection.** Open `buildspec.yml` once more. Locate the `case` block in `post_build` that picks `IRSA_ROLE_ARN` based on `$ENVIRONMENT`, and the `helm upgrade --install` line that injects it via `--set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$IRSA_ROLE_ARN"`.

> **Key Insight:** Hardcoding an AWS account ID in chart values would tie the chart to one account — useless for multi-tenant delivery and a security smell in production. Treating per-environment IRSA ARNs as build-time secrets (sourced from CodeBuild env vars, injected via `--set`) keeps the chart portable and the truth in one place: the IAM role resource Terraform created.

---

## Part 2: Drive a Pipeline Run

### Task 4: Modify a Helm Value and Push

9. Confirm you are on the `main` branch — your pipeline's CodeCommit source action watches `main`. Don't create a feature branch for this lab:

    ```bash
    git branch --show-current
    ```

    **Expected Result:** `main`. If anything else, switch back with `git checkout main`.

    > **Note:** In production, the workflow is feature-branch → PR → review → merge to `main` → pipeline fires. This lab compresses that to a direct push to `main` for simplicity. Don't carry the direct-push pattern into prod — the lab teaches pipeline mechanics, not the change-management workflow that wraps them.

10. Edit `charts/myapp/values-dev.yaml`. Change `replicaCount: 1` to `replicaCount: 2`. Save.

11. Stage, commit, and push:

    ```bash
    git add charts/myapp/values-dev.yaml
    git commit -m "Lab 1: bump dev replicaCount to 2"
    git push origin main
    ```

> **Note:** The push triggers an EventBridge rule that the bootstrap created. CodePipeline starts within a few seconds.

---

### Task 5: Watch the Pipeline Execute

12. In the AWS Console, navigate to **CodePipeline > Pipelines** and find your pipeline (the name is in `$LAB1_PIPELINE_NAME`, format `io107-<your-id>-<suffix>-lab1`).

13. Click into the pipeline. Watch the **Source** stage turn green within seconds of your push, then **Build** start.

> **Note:** You will see TWO executions in the pipeline history — the first one fired during the bootstrap when the seed pushed the lab code initially. The execution you triggered with `git push` is the second one. From here on the lab is talking about *your* execution.

14. Click into the **Build** stage > **Details** to open the CodeBuild console for your execution. Watch the live log stream.

15. Scan the log for these checkpoints, in order:

    - `aws eks update-kubeconfig` returned `Updated context ... in /root/.kube/config`
    - `docker build` and `docker push` completed without errors
    - The `case "$ENVIRONMENT"` block resolved `IRSA_ROLE_ARN` correctly (you should see `IRSA_ROLE_ARN_DEV` referenced)
    - `helm upgrade --install` was invoked with **all three** `--set` overrides (`image.repository`, `image.tag`, `serviceAccount.annotations…role-arn`)
    - Helm printed `STATUS: deployed` and a revision number
    - `kubectl rollout status deployment/myapp` returned `successfully rolled out`

16. Return to the CodePipeline view. Confirm the pipeline status is **Succeeded**.

> **Note:** Your pipeline has two stages — **Source** and **Build**. There is no separate Deploy stage; the Helm deploy runs as the `post_build` phase of the Build stage's CodeBuild project. The standard pattern requires a manual approval gate on any pipeline targeting `stg` or `prd`. This lab's pipeline targets `dev` only, so no approval stage exists. Never extrapolate the dev path to higher environments — staging and prod always require approval before apply.

> **What Just Happened?** A single Git push moved a configuration change through source control, image build, container registry, OPA policy validation, and a live `helm upgrade` against Amazon EKS — without anyone touching the cluster directly. This is the exact flow used for every container deployment.

---

## Part 3: Verify the Deployment

### Task 6: Confirm Pods and LoadBalancer

17. Ensure `kubectl` is pointing at the training cluster. If you haven't done this in this session yet:

    ```bash
    aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
    ```

18. List the pods in your namespace:

    ```bash
    kubectl get pods -n "$LAB1_NAMESPACE" -l app=myapp
    ```

    **Expected Result:** **Two** pods, both `Running` with `READY 1/1`. The new replica count from your push should now be reflected.

19. Describe one pod and confirm it is using the expected ServiceAccount:

    ```bash
    kubectl describe pod -n "$LAB1_NAMESPACE" -l app=myapp | grep -i "service account"
    ```

    **Expected Result:** `Service Account:  myapp-sa`

20. Get the LoadBalancer service and copy the `EXTERNAL-IP` (or hostname) it has been assigned:

    ```bash
    kubectl get svc -n "$LAB1_NAMESPACE"
    ```

    **Expected Result:** The `myapp` service is listed with type `LoadBalancer` and an `EXTERNAL-IP` populated. If `<pending>`, wait 2-3 minutes for the AWS Load Balancer to provision and DNS to propagate.

21. Hit the health endpoint:

    ```bash
    LB=$(kubectl get svc myapp -n "$LAB1_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    curl http://$LB/health
    ```

    **Expected Result:** `{"status": "healthy"}`

    > **Troubleshooting:** AWS-managed LoadBalancers can take 2-4 minutes after the pods are healthy before DNS resolves and accepts traffic. If `curl` fails immediately, wait a minute and retry before assuming the deployment is broken.

---

### Task 7: Validate IRSA from Inside the Pod

22. Confirm the ServiceAccount object carries the IAM role annotation:

    ```bash
    kubectl get sa myapp-sa -n "$LAB1_NAMESPACE" -o yaml
    ```

    **Expected Result:** An `eks.amazonaws.com/role-arn:` annotation under `metadata.annotations`, pointing to `arn:aws:iam::<your-account>:role/io107-<your-id>-<suffix>-myapp-dev-role`. This is the role the bootstrap created in your account, injected by the pipeline at deploy time.

23. Capture one pod name and inspect the IRSA environment variables that the IRSA admission webhook injected:

    ```bash
    POD=$(kubectl get pods -n "$LAB1_NAMESPACE" -l app=myapp -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -n "$LAB1_NAMESPACE" $POD -- env | grep AWS
    ```

    **Expected Result:** At minimum:
    - `AWS_ROLE_ARN=arn:aws:iam::<your-account>:role/io107-<your-id>-<suffix>-myapp-dev-role`
    - `AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token`

    These are the two variables the AWS SDKs key off of to assume the role via `sts:AssumeRoleWithWebIdentity`.

24. Confirm the pod can actually call an AWS API using IRSA. The fixture's Flask app ships with `boto3` (but not the standalone `awscli`), so invoke STS through the Python interpreter:

    ```bash
    kubectl exec -n "$LAB1_NAMESPACE" "$POD" -- python -c "import boto3, json; print(json.dumps(boto3.client('sts').get_caller_identity(), default=str))"
    ```

    **Expected Result:** A JSON document where `Arn` ends with `:assumed-role/io107-<your-id>-<suffix>-myapp-dev-role/<session>`. This confirms the pod assumed your IRSA role via `sts:AssumeRoleWithWebIdentity` using the projected service-account token.

    > **Troubleshooting:** If you see `Unable to locate credentials`, IRSA is not wired correctly. Check the ServiceAccount annotation from step 22 first; if the annotation is missing, your `helm upgrade` ran without the `--set "serviceAccount.annotations…role-arn=…"` override.

> **Key Insight:** The pod has no AWS access keys baked in anywhere — no environment variables with secrets, no instance profile shared broadly across the node. The AWS SDK inside the container exchanged the projected service-account token for short-lived STS credentials scoped to your `myapp-dev-role`. That is the entire point of IRSA: pod-level, least-privilege AWS access without long-lived credentials.

---

## Checkpoint: Verify Your Progress

Before finishing, confirm you have completed:

- [ ] Repository cloned and directory structure confirmed
- [ ] `buildspec.yml` read end-to-end; all four phases (`install` / `pre_build` / `build` / `post_build`) understood
- [ ] Helm chart `values.yaml` and `values-dev.yaml` reviewed; confirmed `image.repository` and `role-arn` both default to `""`
- [ ] `aws codebuild batch-get-projects` confirmed `IRSA_ROLE_ARN_DEV` and `IRSA_ROLE_ARN_STG` are set on the CodeBuild project
- [ ] `replicaCount` change committed and pushed to `main`
- [ ] AWS CodePipeline executed Source → Build to **Succeeded**
- [ ] AWS CodeBuild log shows `helm upgrade` invoked with all three `--set` overrides
- [ ] AWS CodeBuild log shows `helm upgrade` printed `STATUS: deployed`
- [ ] AWS CodeBuild log shows `kubectl rollout status` returned `successfully rolled out`
- [ ] `kubectl get pods -n "$LAB1_NAMESPACE"` shows **2** pods in `Running` 1/1
- [ ] LoadBalancer service has an `EXTERNAL-IP` and `/health` returns `{"status": "healthy"}`
- [ ] `kubectl get sa myapp-sa -n "$LAB1_NAMESPACE" -o yaml` shows the IRSA `eks.amazonaws.com/role-arn` annotation pointing to `io107-<your-id>-<suffix>-myapp-dev-role`
- [ ] `kubectl exec ... env | grep AWS` shows `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`
- [ ] `kubectl exec ... python -c "...sts get-caller-identity..."` returns an `assumed-role/...` ARN — confirms IRSA worked end-to-end

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| Pipeline doesn't fire after `git push` | No new execution in CodePipeline | Verify you pushed to `main` (`git branch --show-current` should print `main`). If pushed to a feature branch, merge to main and push again. Worst case, click **Release change** in the pipeline console. |
| `docker push` fails with "no basic auth credentials" | CodeBuild log shows ECR auth error | Scroll up to the `aws ecr get-login-password` line. If it errored, the CodeBuild service role is missing `ecr:GetAuthorizationToken`. Check the role's policy. |
| `helm upgrade` fails with "release in progress" | `Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress` | A prior pipeline run was killed mid-flight. The buildspec's self-heal block should detect and clear this. If it didn't, run `helm uninstall myapp -n "$LAB1_NAMESPACE"` once, then re-trigger the pipeline. |
| `helm upgrade` deploys but no Service in cluster | `kubectl get svc -n "$NAMESPACE"` shows nothing | Helm 3-way-merge bug after a manual `kubectl delete svc`. Run `helm uninstall myapp -n "$LAB1_NAMESPACE"`, then trigger a fresh pipeline run. |
| Pods stuck in `ImagePullBackOff` | Pod status never reaches `Running` | The image tag in the deployment doesn't match what's in ECR. Confirm `docker push` succeeded in the CodeBuild log for this commit. If not, the build failed before push — fix that first. |
| LoadBalancer EXTERNAL-IP stays `<pending>` | More than 5 min after pods are Ready | Confirm the cluster has the AWS Load Balancer Controller installed (`kubectl get deploy -n kube-system aws-load-balancer-controller`). Confirm the public subnets are tagged with `kubernetes.io/role/elb = 1`. |
| `aws sts get-caller-identity` from pod returns "Unable to locate credentials" | IRSA test step fails | The ServiceAccount is missing the `eks.amazonaws.com/role-arn` annotation. Confirm `helm upgrade` passed the `--set` override (see Task 5 step 15). |

---

## Cost Considerations

| Component | Type | Hourly Cost (us-east-1, on-demand) |
|-----------|------|------------------------------------|
| Amazon EKS cluster (control plane) | Per-student | ~$0.10/hour |
| Worker capacity for 2 pods | Fraction of shared `t3.medium` worker | ~$0.02/hour share |
| Network Load Balancer | ELB | ~$0.0225/hour + data |
| Amazon ECR storage | Per GB-month | <$0.01/hour share |
| AWS CodePipeline + CodeBuild | Active pipeline + build-minutes | <$0.05/hour share |
| **Total (this lab, ~1 hour)** | | **~$0.15-$0.25** |

<!-- source: https://aws.amazon.com/eks/pricing/ + https://aws.amazon.com/elasticloadbalancing/pricing/ + https://aws.amazon.com/codepipeline/pricing/ verified 2026-04-07 -->

**Cleanup:** The training EKS cluster, your CodePipeline, your CodeCommit repo, and your namespace persist between cohorts and into Lab 2-4 — do **not** delete them by hand. The namespace in particular is Helm-managed; deleting it breaks Helm's release state. To release just the application your deployment created (without removing your bootstrap infrastructure):

```bash
helm uninstall myapp -n "$LAB1_NAMESPACE"
```

Removing the Helm release also removes the LoadBalancer service, which terminates the ELB and stops its hourly charge. Leave everything else alone — `terraform destroy` from `lab_env_student/` at end-of-cohort is what removes the per-student namespace, IRSA role, CodeCommit repo, and pipeline.

---

## Knowledge Check

**Question 1:** Why does the `buildspec.yml` pass the `--atomic` flag to `helm upgrade --install`, and what does Helm do when a deployment under `--atomic` fails to become healthy before `--timeout`?
<!-- source: Module_3_narrative.md §"Rollback Strategies" -->

**Question 2:** A teammate proposes putting AWS access keys into a Kubernetes Secret and mounting it as environment variables on the pod, so the application can call S3. Citing what you saw in Task 7, give two specific reasons IRSA is preferred over that approach.
<!-- source: Module_3_narrative.md §"The IRSA Problem" + Module_3_narrative.md §"How IRSA Works" -->

**Question 3:** In the IRSA trust policy that backs `myapp-dev-role`, what string under the `Condition` block ties the role to a specific namespace and ServiceAccount, and what would happen if that string were left as `*`?
<!-- source: Module_3_narrative.md §"IAM Role Trust Policy for IRSA" -->

**Question 4:** Walking from your `git push` to pods running in Amazon EKS, name the four AWS services that participated in the deployment, in order of involvement.
<!-- source: facts_extracted_v2.md §"AWS CodePipeline" + facts_extracted_v2.md §"AWS CodeBuild" + Module_3_narrative.md §"EKS Deployment Pipeline" -->

**Question 5:** The chart's `values.yaml` ships with `image.repository: ""` and `eks.amazonaws.com/role-arn: ""`. Why are these empty strings rather than reasonable defaults (e.g. `nginx:latest` and a generic IRSA role)? What error mode does the empty-string default prevent?
<!-- source: charts/myapp/values.yaml comments + buildspec.yml --set overrides -->

*Answers are in the Knowledge Check Bank.*

---

## Next Steps

In **Lab 2: Lambda Deployment with SAM**, you'll deploy a serverless application through the same pipeline shape (Source → Build → SAM package → SAM deploy → CodeDeploy canary), add a new API endpoint, and watch traffic shift gradually via a CloudWatch-alarm-gated deployment preference. The compute target changes from Amazon EKS to AWS Lambda; everything else is the same model.

---

## Resources

- [Amazon EKS User Guide — IAM Roles for Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Amazon EKS User Guide — Create or update kubeconfig](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html)
- [AWS CodePipeline User Guide](https://docs.aws.amazon.com/codepipeline/latest/userguide/)
- [AWS CodeBuild User Guide — buildspec reference](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)
- [Helm — `helm upgrade` reference](https://helm.sh/docs/helm/helm_upgrade/)
- [Helm — `--set` syntax for nested keys with dots](https://helm.sh/docs/intro/using_helm/#the-format-and-limitations-of---set)
- [Kubernetes — `kubectl rollout status`](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#rollout)

---

*Lab 1 Complete*

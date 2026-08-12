# IO-107 — Student Setup (do this before Lab 1)

This gets your workstation ready and connects it to your lab environment. You'll
launch a small EC2 instance, install the lab toolchain, clone the course repo,
and point Terraform at the environment that has **already been deployed for
you**. Budget ~10 minutes.

> Your EKS cluster, ECR repos, CodeCommit repos, pipelines and Aurora database
> are already running — the instructor built them ahead of class. You are
> connecting to them, not creating them, so there is no long provisioning wait.

Everyone shares one AWS account but you each have your own IAM user, so every
resource you create is prefixed with your `student_id` and won't collide with
anyone else's.

---

## Step 1 — Launch your management EC2 instance

In the AWS Console → **EC2 → Launch instance**:

| Setting | Value |
|---|---|
| **Name** | `io107-<your-name>` |
| **AMI** | Amazon Linux 2023 (default) |
| **Instance type** | `t3.medium` |
| **Key pair** | Create or select one (you'll need it to SSH in) |
| **Storage** | **30 GiB** gp3 (change the default 8 GiB) |
| **IAM instance profile** | **Terraform-InstanceRole** (Advanced details → IAM instance profile) |
| **Security group** | Allow inbound **SSH (22)** from your IP |

> The **Terraform-InstanceRole** instance profile is what lets Terraform create AWS
> resources from the box — you won't run `aws configure` or paste any keys.

Launch it, wait for **Instance state: Running** and a **2/2** status check.

---

## Step 2 — Connect

From your terminal (use the key pair from Step 1):

```bash
ssh -i /path/to/your-key.pem ec2-user@<EC2_PUBLIC_IP>
```

(Or use **EC2 → Connect → EC2 Instance Connect** in the browser.)

---

## Step 3 — Install the lab toolchain

Run the one-liner. It installs git, AWS CLI v2, Terraform, kubectl, Helm,
Conftest, and the SAM CLI (pinned to the versions the labs expect):

```bash
curl -sSL https://raw.githubusercontent.com/roi-cloud-fun/io-107/main/scripts/install_student_deps.sh | sudo bash
```

Confirm the versions printed at the end look sane (no `MISSING`). Open a fresh
shell afterwards so `sam` is on your PATH.

---

## Step 4 — Clone the course repo

```bash
git clone https://github.com/roi-cloud-fun/io-107.git
cd io-107
```

---

## Step 5 — Connect to your lab environment

> ### 🛑 Read this before running anything in Step 5
>
> **Your lab environment has already been deployed for you** — all four labs,
> ready to go. You are *connecting* to it, not creating it.
>
> That means you must **never run `terraform apply` or `terraform destroy`** in
> `lab_environment/lab_env_student/`. The commands below are read-only on
> purpose. Applying with a partial set of lab toggles does not "enable one lab"
> — Terraform reads your existing state and **deletes every lab that is switched
> off**, which measured out at **31 resources destroyed**, including your Aurora
> database and the pipelines for Labs 2, 3 and 4.
>
> If you apply by accident, stop and tell the instructor immediately. Do not try
> to fix it by applying again.

**5a. Point Terraform at your existing environment.** This creates no
infrastructure — it writes a `backend.tf` so Terraform can *read* the state that
already exists, and reuses your state bucket if it is already there:

```bash
./instructor/bootstrap.sh --student-id userXX --region REGION
```

Replace **both** placeholders. `userXX` → **the student id the instructor
assigned you** (e.g. `user04`) — not a nickname. Using a different id would
point Terraform at an empty state and none of your environment would show up.
`REGION` → your **assigned AWS region** (e.g. `us-east-2`). Both are
intentionally invalid as written so the command fails fast if you forget one.

**5b. Initialise and read your outputs** (still no changes to anything):

```bash
cd lab_environment/lab_env_student
terraform init
terraform output
```

You should see a full set of values — `eks_cluster_name`, four
`labN_codecommit_clone_url`s, `lab4_aurora_endpoint`, and so on. **If
`terraform output` prints nothing**, your `--student-id` or `--region` is wrong;
fix it and re-run 5a rather than applying anything.

Every lab guide starts by capturing these into environment variables, so keep
this directory around.

**5c. Connect `kubectl` to your cluster:**

```bash
eval "$(terraform output -json | jq -r '
  to_entries[] | select(.value.value != "(disabled)") |
  "export \(.key | ascii_upcase)=\"\(.value.value)\""
')"

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes
```

`kubectl get nodes` should list two `t3.medium` nodes in `Ready` state. If you
get an authorisation error, tell the instructor — it means your IAM user is
missing the cluster access entry.

**5d. Let git authenticate to CodeCommit** (one-time, uses your IAM identity —
no SSH keys, no passwords):

```bash
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
```

**Proceed to the Lab 1 guide.**

---

## How you actually change things

Each lab has its **own CodeCommit repository**, already seeded with that lab's
starting code. That repo — not this GitHub clone — is what you edit:

```bash
cd ~
git clone "$LAB1_CODECOMMIT_CLONE_URL" myapp
cd myapp
# edit, then:
git add -A && git commit -m "..." && git push
```

**Pushing is what runs the lab.** Your push fires an EventBridge rule that
starts your CodePipeline, which builds and deploys. You watch the result in the
console (CodePipeline → your pipeline) or with `aws codepipeline
get-pipeline-state --name "$LAB1_PIPELINE_NAME"`.

All four lab repos already exist — `$LAB2_CODECOMMIT_CLONE_URL`,
`$LAB3_CODECOMMIT_CLONE_URL`, `$LAB4_CODECOMMIT_CLONE_URL`. Nothing needs to be
enabled or deployed when you reach a later lab; just clone that lab's repo.

> **Labs 3 and 4 start with their pipeline FAILING at the `Validate` stage.**
> That is intentional — those labs ship deliberately policy-violating Terraform
> that you fix. A red pipeline on day one is the exercise, not a fault.

> Shortcut: to deploy **all four labs at once** instead, skip the tfvars edit
> and run `./instructor/bootstrap.sh --student-id <your-name> --apply`.

> **Lab 5 (advanced / optional capstone)** is different: it is a **separate,
> independent deploy** with its **own** Terraform state under `lab_5/terraform/`.
> It does **not** use the `enable_lab5` toggle and does **not** touch this
> environment — it only reads your existing EKS cluster read-only and creates
> its own Aurora + workloads. Follow [`lab_5/README.md`](lab_5/README.md) when
> you reach it; you can run or skip it with zero effect on Labs 1–4.

---

## Tear-down (end of class)

**Do not run `terraform destroy`.** Your environment was deployed by the
instructor and will be torn down centrally — a student-run destroy leaves
orphaned resources behind (the SAM stack, log groups, and Lab 4's blue/green
Aurora leftovers) and can race the instructor's teardown.

The one thing that is yours to clean up is **the EC2 instance you launched in
Step 1** — terminate it in the console when class ends.

If you ran Lab 5 (the optional capstone), destroy that separately — it has its
own state and is genuinely yours:

```bash
cd ~/io-107/lab_5/terraform
terraform destroy
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `bootstrap.sh: aws ... not configured` | Confirm the **Terraform-InstanceRole** instance profile is attached to the EC2 (Step 1). `aws sts get-caller-identity` should return an ARN. |
| `terraform output` prints nothing | Wrong `--student-id` or `--region` in Step 5a. Re-run 5a with the id the instructor assigned you. **Do not run `terraform apply` to "create" it** — it already exists. |
| Terraform wants to **destroy** resources | You are about to delete your own pre-built environment. Answer `no`, and re-read the warning at Step 5. |
| `kubectl` says `error: You must be logged in` / Unauthorized | Re-run `aws eks update-kubeconfig` (Step 5c). If it persists, your IAM user is missing the cluster access entry — tell the instructor. |
| `git clone` → `fatal: could not read Username` | You skipped the CodeCommit credential helper in Step 5d. |
| Labs 3/4 pipeline is red at `Validate` | Expected. Those labs ship deliberately failing policy checks for you to fix. |
| Lab 4: cannot connect to the database | The Aurora clusters are stopped between sessions to save cost — ask the instructor to start yours. |
| `BucketAlreadyExists` on bootstrap | Expected if you already ran Step 5a — the bucket is yours and is reused. Only a problem if you typo'd someone else's id. |
| `sam: command not found` after install | Open a new shell (the installer adds it to PATH). |

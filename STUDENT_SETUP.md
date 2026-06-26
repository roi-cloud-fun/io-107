# IO-107 — Student Setup (do this before Lab 1)

This gets your workstation and AWS lab environment ready. You'll launch a small
EC2 instance, install the lab toolchain, clone the course repo, and deploy your
own copy of the lab infrastructure. Budget ~25 minutes (most of it is EKS
provisioning, which runs unattended).

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
| **IAM instance profile** | **Terraform Role** (Advanced details → IAM instance profile) |
| **Security group** | Allow inbound **SSH (22)** from your IP |

> The **Terraform Role** instance profile is what lets Terraform create AWS
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

## Step 5 — Deploy your lab environment

We deploy **one lab at a time**. For Lab 1, we'll enable only `lab1` and leave
the others off (you'll flip them on as we reach each lab).

**5a. Create your state backend + config** (uses your IAM identity via the
instance profile; makes a state bucket prefixed with your name):

```bash
./instructor/bootstrap.sh --student-id <your-name>
```

Replace `<your-name>` with a short lowercase id (letters/digits/dashes, ≤16
chars), e.g. `alice`. This creates `s3://io107-<your-name>-tfstate-<account>`,
writes `backend.tf`, and writes a `terraform.tfvars` you'll edit next.

**5b. Select just Lab 1.** Edit the tfvars:

```bash
nano lab_environment/lab_env_student/terraform.tfvars
```

Set the lab toggles so only Lab 1 is on:

```hcl
enable_lab1 = true
enable_lab2 = false
enable_lab3 = false
enable_lab4 = false
```

**5c. Apply** (this is the ~15-minute EKS provision):

```bash
cd lab_environment/lab_env_student
terraform init
terraform apply        # review the plan, type 'yes'
```

When it finishes, capture your outputs — the Lab 1 guide references them:

```bash
terraform output
```

You now have your own EKS cluster, ECR repo, CodeCommit repo, and Lab 1
pipeline. **Proceed to the Lab 1 guide.**

---

## Adding later labs

When we reach Lab 2 (and 3, 4), just flip the toggle and re-apply — the shared
infra is already up, so this only adds that lab's pieces (a couple of minutes):

```bash
# edit terraform.tfvars: set enable_lab2 = true
cd lab_environment/lab_env_student
terraform apply
```

> Shortcut: to deploy **all four labs at once** instead, skip the tfvars edit
> and run `./instructor/bootstrap.sh --student-id <your-name> --apply`.

---

## Tear-down (end of class)

```bash
cd ~/io-107/lab_environment/lab_env_student
terraform destroy
```

Then terminate your EC2 instance in the console. (Removing the Helm release with
`helm uninstall myapp -n <your lab1 namespace>` first frees the LoadBalancer
faster, but `terraform destroy` handles everything.)

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `bootstrap.sh: aws ... not configured` | Confirm the **Terraform Role** instance profile is attached to the EC2 (Step 1). `aws sts get-caller-identity` should return an ARN. |
| `terraform apply` denied creating a resource | Your IAM user / Terraform Role is missing a permission — note the exact action in the error and report it to the instructor. |
| `BucketAlreadyExists` on bootstrap | Someone used the same `--student-id`. Pick a unique one. |
| `sam: command not found` after install | Open a new shell (the installer adds it to PATH). |

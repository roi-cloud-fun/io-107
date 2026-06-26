# IO-107 — SDLC Pipeline & Deployment Guardrails

Monorepo for ROI Training's IO-107 course. **Contains everything you need to stand up and run the labs end-to-end.**

## What's where

```
io-107/
├── STUDENT_SETUP.md                  ← START HERE (students): EC2 + toolchain + deploy
├── instructor/                       Instructor / LTF tooling
│   ├── bootstrap.sh                  Creates per-student S3 state backend + tfvars
│   ├── install_mgmt_tools.sh         Toolchain installer for the instructor / LTF host
│   ├── student_deploy_policy.json    IAM policy for the student group / Terraform role
│   └── LTF_HANDOFF.md                Recipe for running the Lab Testing Framework
│
├── lab_environment/
│   └── lab_env_student/              Unified Terraform — one `apply` provisions everything
│       ├── main.tf                   VPC, EKS, ECR, KMS, IRSA, CodePipeline, CodeBuild, CodeCommit
│       ├── variables.tf              student_id, region, enable_lab1..4 toggles
│       ├── outputs.tf                Per-student URLs, ARNs (LTF + lab guides read these)
│       ├── versions.tf               Terraform 1.10+ + AWS provider 5.40+
│       └── terraform.tfvars.example  Copy to terraform.tfvars and fill in
│
├── lab_1/   End-to-End EKS Deployment Pipeline (Flask + Helm + buildspec)
├── lab_2/   Lambda Deployment with SAM (template + handler + tests + buildspec)
├── lab_3/   Policy-as-Code Evaluation (non-compliant TF + K8s + Rego + buildspec)
└── lab_4/   Aurora Blue/Green Deployment via Terraform (TF + engine_version_pin Rego + buildspec)
```

## Quick start (instructor / LTF)

```bash
# 1. Clone this repo
git clone https://github.com/roi-cloud-fun/io-107.git
cd io-107

# 2. Create your per-student state backend + tfvars (no CodeStar/OAuth needed).
#    Both placeholders are intentionally invalid -- set your real values or the
#    command fails fast (keeps everyone from piling into us-east-1).
./instructor/bootstrap.sh --student-id userXX --region REGION   # your userID (lowercase) + your assigned region

# 3. (optional) edit lab_environment/lab_env_student/terraform.tfvars to enable
#    only the labs you want (enable_lab1..4 toggles); then apply
cd lab_environment/lab_env_student
terraform init
terraform apply
```

After `terraform apply` completes (~15 min for EKS), each lab's per-student CodeCommit repo is seeded with the matching `lab_<N>/` subdir of this monorepo (flattened to root). Students clone their CodeCommit URL from the Terraform outputs, edit, and push back to trigger their own pipeline.

## How the labs use this repo

| Lab | Subdir | Pipeline reads from |
|-----|--------|---------------------|
| Lab 1: EKS Deployment | `lab_1/` | Per-student CodeCommit seeded with `lab_1/*` |
| Lab 2: Lambda SAM | `lab_2/` | Per-student CodeCommit seeded with `lab_2/*` |
| Lab 3: OPA Violations | `lab_3/` | Per-student CodeCommit seeded with `lab_3/*` |
| Lab 4: Aurora Blue/Green | `lab_4/` | Per-student CodeCommit seeded with `lab_4/*` |

The seeding happens at `terraform apply` time via a `null_resource` provisioner — see `lab_environment/lab_env_student/main.tf`.

## Student-facing lab guides

Everything students follow is **markdown in this repo** — no external docs. Point students here, in order:

1. **[STUDENT_SETUP.md](STUDENT_SETUP.md)** — one-time setup: launch the EC2 workstation, install the toolchain, clone, and deploy the lab environment.
2. **[Lab 1 — End-to-End EKS Deployment Pipeline](lab_1/README.md)**
3. **[Lab 2 — Lambda Deployment with SAM](lab_2/README.md)**
4. **[Lab 3 — Policy-as-Code Evaluation](lab_3/README.md)**
5. **[Lab 4 — Aurora Blue/Green Deployment](lab_4/README.md)**
6. **[Lab 5 — Blue/Green a Stateful App on EKS + Aurora](lab_5/README.md)** *(advanced / optional capstone — independent deploy with its own Terraform state; does not touch the Labs 1–4 environment)*

This repo holds both the **code** the labs operate on and the **instructions** students follow.

## Updating lab content

When fixture code changes (e.g. a buildspec edit, a Helm values change, a Rego rule update):

1. Edit inside the relevant `lab_N/` subdirectory
2. Push to `main`
3. Re-run `terraform apply` in `lab_environment/lab_env_student/` — the seed step picks up the new content and re-mirrors it into each per-student CodeCommit
4. (Optional) re-run the LTF specs against the refreshed state

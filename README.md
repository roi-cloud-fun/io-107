# IO-107 — SDLC Pipeline & Deployment Guardrails

Monorepo for ROI Training's IO-107 course. **Contains everything you need to stand up and run the labs end-to-end.**

## What's where

```
io-107/
├── instructor/                       ← START HERE if you're an instructor / LTF runner
│   ├── pre_class_setup.md            Step-by-step: bootstrap state, apply Terraform, OAuth handshake
│   └── LTF_HANDOFF.md                Recipe for running the Lab Testing Framework
│
├── lab_environment/
│   └── lab_env_student/              Unified Terraform — one `apply` provisions everything
│       ├── main.tf                   VPC, EKS, ECR, KMS, IRSA, CodePipeline, CodeBuild, CodeCommit
│       ├── variables.tf              student_id, region, github_codestar_connection_arn
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

# 2. Walk through the instructor checklist (S3 backend bootstrap, CodeStar OAuth, apply)
open instructor/pre_class_setup.md      # macOS
# or just read it on GitHub

# 3. Run Terraform
cd lab_environment/lab_env_student
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: student_id, github_codestar_connection_arn
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

The student-facing markdown guides are NOT in this repo — they're authored in [CourseCreationKit](https://drive.google.com/drive/) and rendered as ROI-branded Google Docs for students to follow. This repo holds the **code** the labs operate on; the **instructions** are the Google Docs.

If you need the lab guide markdown for reference, they live at:
`courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/content/labs/Lab_*_Guide.md` in CourseCreationKit.

## Repo lifecycle

This repo is authored + maintained from CourseCreationKit's labforge tooling. Updates flow:
1. Edit content in `labforge_iterations/repo_additions/io107-lab*/` and templates in `labforge/templates/lab_env_student/`
2. Regenerate via `python labforge/python/generate_setup_artifacts.py --course SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline --mode student`
3. Push to this repo's `main` branch
4. Per-student CodeCommit mirrors pick up new state at next `terraform apply` (or via re-seed)

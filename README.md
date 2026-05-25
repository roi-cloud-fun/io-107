# IO-107 — SDLC Pipeline & Deployment Guardrails (Lab Fixtures)

Monorepo containing the four lab fixtures for ROI Training's IO-107 *SDLC Pipeline & Deployment Guardrails* course. Each lab lives in its own subdirectory and is self-contained — pipelines, buildspecs, Terraform, Helm charts, OPA/Rego policies, and sample app code.

## Layout

```
io-107/
├── lab_1/   End-to-End EKS Deployment Pipeline
│             Flask app + Helm chart + buildspec.yml
│             Pipeline: Source → Build (docker + ECR) → Deploy (helm upgrade --atomic on EKS)
│             Demonstrates: IRSA, --atomic rollback, kubectl rollout
├── lab_2/   Lambda Deployment with SAM
│             SAM template + Python handler + tests + buildspec.yml
│             Pipeline: Source → Build (sam build) → Deploy (sam deploy, Canary10Percent5Minutes)
│             Demonstrates: Lambda versioning, alias-based traffic shifting, CloudWatch auto-rollback
├── lab_3/   Policy-as-Code Evaluation & Failure Remediation
│             Deliberately non-compliant Terraform + K8s manifest + 5 Rego policies + buildspec.yml
│             Pipeline: Source → Build → Validate (Conftest/OPA — FAILS) → student remediates → re-pushes
│             Demonstrates: Pre-deploy policy gates, deny-by-default tag/encryption/registry rules
└── lab_4/   Aurora Blue/Green Deployment via Terraform + Pipeline
              Aurora cluster Terraform + engine_version_pin Rego + buildspec.yml
              Pipeline: Source → Build (terraform plan) → Validate (OPA) → Approval → Deploy (CLI-driven Blue/Green)
              Demonstrates: Aurora Blue/Green via aws rds create-blue-green-deployment, manual approval gate
```

## Lab pipelines

Each lab is paired with a CodePipeline + CodeBuild project provisioned by the course's `lab_env_student/` Terraform module. The CodeBuild project uses each lab's `lab_N/buildspec.yml` — configured via the project's BuildSpec setting (path-prefixed to the lab subdir).

## Course material

Student-facing lab guides, instructor checklist, and Terraform-bootstrap module live in the CourseCreationKit course folder, not in this repo:
- `courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/content/labs/Lab_*.md` (lab guides)
- `courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/lab_environment/lab_env_student/` (Terraform)
- `courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/instructor_pre_class_setup.md`

## Where this repo gets cloned

- **Lab Testing Framework (LTF):** Clones this repo, drives each lab's `lab_N/` fixture per the Playwright specs in `testing_framework/courses/io107/tests/`.
- **Student per-lab CodeCommit:** Terraform mirrors this repo into a per-student CodeCommit; the student `git clone`s their own copy, edits inside the relevant `lab_N/`, and pushes — triggering their own pipeline only.

## Repo lifecycle

Authored + maintained by the course author. Updates flow:
1. Edit lab content in `labforge_iterations/repo_additions/io107-lab*/` inside CourseCreationKit
2. Push to this repo's `main` branch
3. Per-student CodeCommit mirrors pick up new state at next Terraform apply (or via re-seed)

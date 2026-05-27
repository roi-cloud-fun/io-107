# io107-lab3-policy-violations

**Course:** IO-107 SDLC Pipeline & Deployment Guardrails
**Lab:** Lab 3 — Policy-as-Code Evaluation & Failure Remediation
**Status:** Deliberately broken. Do NOT fix without reading Lab 3 first.

This repository is the source material for IO-107 Lab 3. It contains Terraform and
Kubernetes manifests that **intentionally violate** the platform OPA policies. The
AWS CodePipeline Validate stage runs Conftest against the Terraform plan
(`tfplan.json`) and the Kubernetes manifest (`kubernetes/deployment.yaml`) and is
expected to fail on the first run.

Students remediate the violations in `terraform/main.tf` and
`kubernetes/deployment.yaml` and re-run the pipeline. **The policies under
`policies/` are the contract — do not edit them to make the build pass.**

---

## The 8 deliberate violations

Conftest reports 17 `FAIL` lines on a fresh checkout. They map to 8 root causes
across two files:

### Terraform (`terraform/main.tf`)

| # | Violation | Policy | Conftest Failures |
|---|-----------|--------|---|
| 1 | `aws_s3_bucket.data_bucket` is named `my-bucket` instead of `client-{env}-{app}-{purpose}` | `policies/naming.rego` | 1 |
| 2 | No paired `aws_s3_bucket_server_side_encryption_configuration` resource exists for `aws_s3_bucket.data_bucket` (inline `server_side_encryption_configuration` was removed from the schema in AWS provider v4.0, so the modern policy looks for the paired resource type) | `policies/encryption.rego` | 1 |
| 3 | `aws_s3_bucket.data_bucket` is missing every required tag except `Name` (`Environment`, `Application`, `Owner`, `CostCenter`, `DataClass`) | `policies/tagging.rego` | 5 |
| 4 | `aws_lambda_function.processor` has `timeout = 600`, exceeding the 300-second cap | `policies/lambda.rego` | 1 |
| 5 | `aws_lambda_function.processor` is missing `Environment`, `Application`, `Owner`, `CostCenter` tags | `policies/tagging.rego` | 4 |

### Kubernetes (`kubernetes/deployment.yaml`)

| # | Violation | Policy | Conftest Failures |
|---|-----------|--------|---|
| 6 | Deployment `myapp` metadata is missing required labels `environment` and `owner` | `policies/eks.rego` | 2 |
| 7 | Container `myapp` pulls `docker.io/library/nginx:latest` — only images from the approved Amazon ECR registry are permitted | `policies/eks.rego` | 1 |
| 8 | Container `myapp` has no `resources.limits` block — both memory and CPU limits are required | `policies/eks.rego` | 2 |

**Total:** 12 Terraform failures + 5 Kubernetes failures = **17 FAIL lines**.

---

## Layout

```
io107-lab3-policy-violations/
├── README.md
├── buildspec.yml                          # AWS CodeBuild spec for the Validate stage
├── conftest.toml                          # Conftest config (points at ./policies)
├── expected_output.txt                    # Sample Conftest output students should match
├── terraform/
│   ├── main.tf                            # DELIBERATELY broken — students remediate
│   ├── variables.tf
│   └── outputs.tf
├── kubernetes/
│   └── deployment.yaml                    # DELIBERATELY broken — students remediate
└── policies/                              # Rego policy library (DO NOT EDIT)
    ├── naming.rego                        # S3 bucket naming convention
    ├── tagging.rego                       # Required tags on S3 + Lambda
    ├── encryption.rego                    # Paired-resource encryption pattern (v4+)
    ├── lambda.rego                        # Lambda timeout + KMS for prod
    └── eks.rego                           # Container image + resource limits + labels
```

---

## Modern Rego pattern (paired-resource encryption)

All five Rego policies walk `input.resource_changes[_]` — the **modern**
`terraform show -json` shape. `policies/encryption.rego` additionally walks
`input.configuration.root_module.resources` and resolves each S3 bucket's
encryption partner via `expressions.bucket.references`, because at plan time the
encryption resource's `bucket` attribute is `(known after apply)`. See Module 6
for the full walkthrough.

---

## Running Conftest locally

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform show -json tfplan > ../tfplan.json
cd ..

conftest test tfplan.json
conftest test kubernetes/
```

You should see 17 `FAIL` lines (12 from `tfplan.json`, 5 from `deployment.yaml`)
and a non-zero exit code, exactly as in `expected_output.txt`.

---

## Remediation

Lab 3 walks students through the fixes step by step. The remediated
`terraform/main.tf` and `kubernetes/deployment.yaml` are reproduced in Tasks 6
and 7 of `content/labs/Lab_3_Guide.md`. After remediation, Conftest reports
`17 tests, 17 passed, 0 warnings, 0 failures` and the pipeline proceeds to
Deploy.

---

## What this repo does NOT contain

- A real `lambda.zip` artifact — Terraform plan succeeds because `filename =
  "lambda.zip"` is parsed without the file having to exist at plan time. The
  Validate stage is policy evaluation, not deployment. Students never reach
  `terraform apply` on the broken state.
- The full platform policy library — the five Rego files here mirror the rules
  taught in Module 6. In production those policies live in a central platform
  repo that CodeBuild mounts via S3. The local copy under `policies/` is what
  Conftest actually evaluates.

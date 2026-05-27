# io107-lab4-aurora-bluegreen

Terraform + AWS CodePipeline guardrails for a zero-downtime Aurora PostgreSQL
engine upgrade via the Aurora Blue/Green deployment path.

This repo is the lab artefact for **IO-107 Module 5 / Lab 4** — Aurora
Blue/Green Deployment via Terraform + Pipeline. The training Amazon Aurora
cluster (`training-aurora`) is pre-provisioned by the platform team. Students
**modify** the cluster through this Terraform; they do **not** create or
destroy it.

---

## Layout

```
.
├── terraform/
│   ├── aurora_cluster.tf         # aws_rds_cluster resource for training-aurora
│   ├── variables.tf              # inputs (environment, application, owner, etc.)
│   ├── outputs.tf                # cluster_endpoint, reader_endpoint, port, resource id
│   ├── providers.tf              # AWS provider + backend
│   └── terraform.tfvars.example  # copy to terraform.tfvars and fill placeholders
├── policies/
│   └── engine_version_pin.rego   # OPA / Conftest policy: only approved engine versions
├── buildspec.yml                 # CodeBuild phases: init → plan → conftest → apply
├── expected_cloudtrail_events.txt
└── README.md                     # this file
```

---

## Upgrade path — what students actually do

The starting state describes the training cluster **as it exists today**:
Aurora PostgreSQL 16.11, encrypted, Multi-AZ, with the five mandatory tags,
and **no** `blue_green_update` block. Pushing the repo as-is would fail OPA
validation, because the engine-version pin policy in `policies/` only allows
versions `16.13` and `16.14`.

The lab is the failure-into-success arc:

1. **Inspect.** Read `terraform/aurora_cluster.tf`. Confirm `engine_version
   = "16.11"` and that the resource has **no** `blue_green_update` block.
2. **Edit `terraform/aurora_cluster.tf`.** Two changes only:
   - Bump `engine_version` from `"16.11"` to `"16.13"`.
   - Add a `blue_green_update { enabled = true }` block to the
     `aws_rds_cluster.training` resource.
3. **Commit and push.** AWS CodePipeline triggers automatically:
   - **Source** — Pulls your commit.
   - **Build (plan)** — `terraform init`, `terraform plan -out=tfplan`,
     `terraform show -json tfplan > tfplan.json`.
   - **Validate (OPA)** — `conftest test tfplan.json -p policies/`. With
     `16.13` this passes; with `16.11` it fails the pin policy.
   - **Approval** — Manual approval gate, because the cluster is a prod-tier
     shared resource. Required by IO-107 Module 1 / Module 5 patterns.
   - **Deploy (apply)** — `terraform apply tfplan`. AWS RDS receives
     `ModifyDBCluster` with the Blue/Green opt-in, provisions the green
     cluster, replicates, and switches over once lag is zero.
4. **Observe.** Watch blue and green appear together in **RDS > Databases**
   while the deployment is in progress. Then find the three RDS events in
   **AWS CloudTrail**: `CreateBlueGreenDeployment`, `ModifyDBCluster`,
   `SwitchoverBlueGreenDeployment` (see `expected_cloudtrail_events.txt`).

---

## What you do **not** do

- **Do not** run `terraform destroy`. The cluster is shared infrastructure.
- **Do not** edit the OPA policy in `policies/engine_version_pin.rego` to
  add an unapproved version. That is the Module 6 anti-pattern. If the pin
  list needs updating, raise it through the platform team.
- **Do not** edit `cluster_identifier`, `engine`, `database_name`, or
  `master_username` — those attributes force replacement of the cluster.

---

## References

- [Amazon RDS Blue/Green Deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html)
- [Terraform `aws_rds_cluster` resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster)
- [AWS CloudTrail — Logging Amazon RDS API calls](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/logging-using-cloudtrail.html)
- [Open Policy Agent — Rego language](https://www.openpolicyagent.org/docs/latest/policy-language/)
- [Conftest](https://www.conftest.dev/)

###############################################################################
# IO-107 Lab 4 — Aurora Blue/Green Deployment via Terraform + Pipeline
#
# Students modify ONE thing in this file during the lab:
#   Bump `local.target_engine_version` from "16.11" to "16.13".
#
# That single edit is what the pipeline observes:
#   1. terraform plan surfaces the change as a `terraform_data` resource_change.
#   2. OPA (engine_version_pin.rego) validates the new version is on the
#      platform team's approved list.
#   3. Manual approval gate.
#   4. Apply phase: the buildspec invokes `aws rds create-blue-green-deployment`
#      with the new target version, waits for the green cluster, and
#      executes the switchover.
#
# Why a data source (not a resource block) on the cluster?
#   The Aurora cluster is created out-of-band by the per-student bootstrap
#   (lab_env_student/). The Terraform AWS provider does NOT support
#   `blue_green_update` on `aws_rds_cluster` either way -- that argument only
#   exists on `aws_db_instance`. The Blue/Green flow runs from the AWS CLI in
#   the buildspec's apply phase, not from `terraform apply`. This TF file's
#   job is:
#     - surface target_engine_version to OPA via the terraform_data shim
#     - read the existing cluster as a data source so other parts of the lab
#       can reference its attributes
#
# Sources:
#   https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/rds_cluster
###############################################################################

locals {
  # >>> STUDENT EDIT: bump to trigger a Blue/Green engine-version upgrade <<<
  target_engine_version = "16.11"
}

# OPA observability shim: surfaces `target_engine_version` to Conftest as a
# `resource_change` in the plan JSON. Without this, the value isn't visible
# in the plan and the policy gate can't validate it before approval.
resource "terraform_data" "engine_version_target" {
  input = local.target_engine_version
}

# Read-only reference to the per-student Aurora cluster provisioned by the
# bootstrap (lab_env_student/). cluster_identifier is passed in via
# var.cluster_identifier -- the buildspec sets TF_VAR_cluster_identifier from
# the CLUSTER_ID CodeBuild env var (which Terraform set when it created the
# cluster).
data "aws_rds_cluster" "training" {
  cluster_identifier = var.cluster_identifier
}

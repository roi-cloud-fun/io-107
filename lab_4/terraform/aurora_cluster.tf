###############################################################################
# IO-107 Lab 4 — Aurora Blue/Green Deployment via Terraform + Pipeline
#
# Initial state for the training-aurora cluster.
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
# Why not just put `engine_version = local.target_engine_version` on the
# cluster and let Terraform apply it?
#   The Terraform AWS provider does NOT support `blue_green_update` on
#   `aws_rds_cluster` — that argument only exists on `aws_db_instance` (RDS,
#   not Aurora). A direct `terraform apply` of an engine_version change on
#   Aurora performs an in-place modify with downtime, bypassing Blue/Green
#   safety. To keep Blue/Green as the upgrade path, we:
#     - tell Terraform to *ignore* engine_version drift (lifecycle below), so
#       direct applies don't modify it,
#     - drive the actual upgrade via the AWS CLI in the apply phase,
#     - surface the target value to OPA via a `terraform_data` marker so the
#       policy gate still fires before approval.
#
# Sources:
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster
#   https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html
###############################################################################

locals {
  # >>> STUDENT EDIT: bump to trigger a Blue/Green engine-version upgrade <<<
  target_engine_version = "16.11"
}

data "aws_db_subnet_group" "training" {
  name = var.db_subnet_group_name
}

data "aws_security_group" "training_db" {
  id = var.vpc_security_group_id
}

data "aws_kms_key" "training_rds" {
  key_id = var.kms_key_arn
}

# OPA observability shim: surfaces `target_engine_version` to Conftest as a
# `resource_change` in the plan JSON. Without this, `lifecycle.ignore_changes`
# on the cluster would hide the value from the plan and the policy gate
# couldn't validate it before approval.
resource "terraform_data" "engine_version_target" {
  input = local.target_engine_version
}

resource "aws_rds_cluster" "training" {
  cluster_identifier          = "training-aurora"
  engine                      = "aurora-postgresql"
  engine_version              = local.target_engine_version
  database_name               = "training"
  master_username             = "training_admin"
  manage_master_user_password = true

  db_subnet_group_name   = data.aws_db_subnet_group.training.name
  vpc_security_group_ids = [data.aws_security_group.training_db.id]

  db_cluster_parameter_group_name = "training-aurora-pg16-default"

  storage_encrypted = true
  kms_key_id        = data.aws_kms_key.training_rds.arn

  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"

  # Financial-services baseline controls:
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  iam_database_authentication_enabled = true
  deletion_protection                 = true

  skip_final_snapshot       = false
  final_snapshot_identifier = "training-aurora-final"

  lifecycle {
    # Engine-version changes flow through the Blue/Green path in the buildspec
    # apply phase, NOT a direct Terraform modify. See aurora_cluster.tf header
    # comment for the full rationale.
    ignore_changes = [engine_version]
  }

  tags = {
    Environment = var.environment
    Application = var.application
    Owner       = var.owner
    CostCenter  = var.cost_center
    DataClass   = "internal"
  }
}

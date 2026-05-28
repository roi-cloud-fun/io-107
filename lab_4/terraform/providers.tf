###############################################################################
# IO-107 Lab 4 — providers.tf
#
# Backend: partial S3 config. `bucket` and `region` are supplied at
# `terraform init` time by the buildspec via `-backend-config=...` flags,
# pointing at the per-student `lab4_artifacts` bucket provisioned by
# `lab_env_student/`. Keeping the key static here so the same state file
# is used across every pipeline run (Build / Validate / Deploy), letting
# the Deploy stage's apply see the resources that the Build stage's plan
# referenced.
#
# `use_lockfile = true` is Terraform 1.10+ native S3 locking -- no separate
# DynamoDB lock table needed. The CodeBuild execution role has read/write
# on the state object and lock object via the per-student artifact bucket's
# IAM policy.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key          = "lab4/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Repo      = "io107-lab4-aurora-bluegreen"
    }
  }
}

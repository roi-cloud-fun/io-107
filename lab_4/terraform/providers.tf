###############################################################################
# IO-107 Lab 4 — providers.tf
#
# The S3 backend bucket, DynamoDB lock table, and KMS key are pre-provisioned
# by the platform team. CodeBuild's execution role has read/write on the
# state object and read/write on the lock table.
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
    bucket         = "client-tfstate-training"
    key            = "io107/lab4-aurora-bluegreen/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "client-tfstate-locks"
    encrypt        = true
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

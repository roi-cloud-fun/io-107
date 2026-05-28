terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # Partial backend config -- bucket / region are passed at `terraform init`
  # time by the buildspec via `-backend-config=...` flags. Keeping the key
  # static here so the same state file is used across every pipeline run,
  # so the second run sees the first run's resources and doesn't try to
  # recreate them. `use_lockfile = true` is Terraform 1.10+ native S3 locking
  # -- no separate DynamoDB lock table needed.
  backend "s3" {
    key          = "lab3/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"
}

# Per-student suffix for plumbing resource names. The training account is
# shared across multiple students, so any hardcoded name (IAM role, Lambda
# function, etc.) would collide. State is per-student (per-student artifact
# bucket + lab3/terraform.tfstate key), so this random_string is generated
# once per student and stays stable across that student's plan/apply cycles.
# The OPA policies do NOT inspect IAM role or Lambda function names -- this
# is invisible to the policy gate. The S3 bucket name is left for the
# student to remediate manually since that IS the teaching target.
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

# The Lambda zip is built from src/app.py at plan time so the lab works
# without a pre-built artifact in the repo.
data "archive_file" "processor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/processor.zip"
}

# ---------------------------------------------------------------------------
# DELIBERATELY BROKEN — Lab 3 students remediate this file.
#
# The OPA policies under ../policies/ are the contract. Do NOT edit them to
# make the pipeline pass. Fix the resources below to comply with the policies.
# ---------------------------------------------------------------------------

# VIOLATION 1: Bucket name does not match naming convention
#   Policy:  policies/naming.rego
#   Required pattern: client-{env}-{app}-{purpose}
#                     e.g. client-dev-lab3-data
#
# VIOLATION 2: No paired aws_s3_bucket_server_side_encryption_configuration
#   Policy:  policies/encryption.rego
#   Inline server_side_encryption_configuration {} was removed from the
#   aws_s3_bucket schema in AWS provider v4.0 (Feb 2022). The current pattern
#   is a separate aws_s3_bucket_server_side_encryption_configuration resource
#   that references the bucket. This file is missing that paired resource.
#
# VIOLATION 3: Missing required tags
#   Policy:  policies/tagging.rego
#   Required on every resource:        Environment, Application, Owner, CostCenter
#   Required on data-handling buckets: DataClass
resource "aws_s3_bucket" "data_bucket" {
  bucket = "my-bucket"

  tags = {
    Name = "My Bucket"
  }
}

# Lambda execution role. NOT a teaching target -- the policies in ../policies/
# evaluate the Lambda function itself (timeout, tags), not the execution role.
# We create a real role here so `terraform apply` succeeds once the policy
# violations on the function are fixed. The random suffix prevents collisions
# across students sharing the training account.
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "lab3-lambda-exec-${random_string.suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VIOLATION 4: Lambda timeout exceeds maximum
#   Policy:  policies/lambda.rego
#   Maximum allowed: 300 seconds.
#
# VIOLATION 5: Lambda missing required tags
#   Policy:  policies/tagging.rego
#   Same four mandatory tags as above.
resource "aws_lambda_function" "processor" {
  function_name    = "data-processor-${random_string.suffix.result}"
  runtime          = "python3.11"
  handler          = "app.handler"
  timeout          = 600
  memory_size      = 512
  filename         = data.archive_file.processor_zip.output_path
  source_code_hash = data.archive_file.processor_zip.output_base64sha256
  role             = aws_iam_role.lambda_exec.arn

  tags = {
    Name = "Processor"
  }
}

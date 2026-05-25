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
  }
}

provider "aws" {
  region = "us-east-1"
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

# VIOLATION 4: Lambda timeout exceeds maximum
#   Policy:  policies/lambda.rego
#   Maximum allowed: 300 seconds.
#
# VIOLATION 5: Lambda missing required tags
#   Policy:  policies/tagging.rego
#   Same four mandatory tags as above.
resource "aws_lambda_function" "processor" {
  function_name    = "data-processor"
  runtime          = "python3.11"
  handler          = "app.handler"
  timeout          = 600
  memory_size      = 512
  filename         = data.archive_file.processor_zip.output_path
  source_code_hash = data.archive_file.processor_zip.output_base64sha256
  role             = "arn:aws:iam::123456789012:role/lab3-lambda-role"

  tags = {
    Name = "Processor"
  }
}

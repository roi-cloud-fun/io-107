###############################################################################
# IO-107 SDLC Pipeline -- lab_env_student / versions.tf
#
# UNIFIED student-mode module. Provisions EVERYTHING (IO-107 SDLC Pipeline needs
# in one `terraform apply`: the shared regional infra (VPC, EKS, ECR, KMS,
# security groups, DB subnet group)
# PLUS the per-student artifacts (pipeline, CodeBuild project, S3 artifact
# bucket, IRSA roles, K8s namespace, Aurora cluster).
#
# Use this mode for: LTF test runs, individual smoke-tests, instructor demos.
# Use --mode split for: SYF-style multi-student delivery where the shared
# regional infra is provisioned once per region.
#
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Course      = "IO-107 SDLC Pipeline"
      Environment = "training"
      Module      = "lab_env_student"
      StudentId   = var.student_id
    }
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.training.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.training.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.training.token
}

data "aws_eks_cluster_auth" "training" {
  name = aws_eks_cluster.training.name
}


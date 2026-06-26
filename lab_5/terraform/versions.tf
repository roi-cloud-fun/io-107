###############################################################################
# IO-107 Lab 5 — versions / providers
#
# Lab 5 is a FULLY INDEPENDENT deploy with its OWN state (see backend.tf.example).
# It reads the student's existing cluster/network read-only via the main
# lab_env_student remote state + AWS data sources, and creates only its own
# Aurora, namespace, IRSA role, and ECR repo.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      ManagedBy = "terraform"
      Course    = "IO-107 SDLC Pipeline"
      Module    = "lab_5"
      StudentId = var.student_id
    }
  }
}

# Both providers are configured from the read-only EKS data sources in main.tf
# (data.aws_eks_cluster.main / data.aws_eks_cluster_auth.main). Lab 5 deploys
# workloads INTO the existing cluster; it never reconfigures it.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

###############################################################################
# IO-107 Lab 5 — Stateful app on EKS + Aurora, manual Blue/Green (Part A)
#
# Independent deploy / own state. READS the student's existing environment
# (cluster, VPC, subnets, worker SG, OIDC) read-only via the main remote state
# and AWS data sources. CREATES only Lab 5's own resources: an ECR repo, an
# Aurora cluster (+ one instance), a namespace, and an IRSA role.
#
# NOTHING here imports or manages a resource owned by lab_env_student.
###############################################################################

# --- Read-only references to the main (lab_env_student) deploy --------------

data "terraform_remote_state" "main" {
  backend = "s3"
  config  = var.main_remote_state
}

data "aws_eks_cluster" "main" {
  name = data.terraform_remote_state.main.outputs.eks_cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.main.outputs.eks_cluster_name
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "io107-${var.student_id}-lab5"
  namespace   = "lab5-${var.student_id}"
  sa_name     = "myapp-sa"

  # Pulled read-only from the main deploy outputs (additive outputs added to
  # lab_env_student/outputs.tf — they add no resources there).
  main_outputs       = data.terraform_remote_state.main.outputs
  vpc_id             = local.main_outputs.vpc_id
  private_subnet_ids = local.main_outputs.private_subnet_ids
  workers_sg_id      = local.main_outputs.eks_workers_security_group_id
  oidc_provider_arn  = local.main_outputs.eks_oidc_provider_arn
  # Issuer without the https:// scheme — used in the IRSA trust conditions.
  oidc_issuer_host = replace(local.main_outputs.eks_oidc_issuer, "https://", "")
}

# --- ECR repo for the Lab 5 app image ---------------------------------------

resource "aws_ecr_repository" "lab5" {
  name                 = "io107-${var.student_id}-lab5"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "io107-${var.student_id}-lab5" }
}

# --- Aurora networking: dedicated SG (ingress 5432 from EKS workers) ---------

resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-aurora"
  description = "IO-107 Lab 5 Aurora SG -- ingress 5432 from existing EKS workers"
  vpc_id      = local.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.workers_sg_id]
    description     = "Postgres from the main deploy's EKS worker nodes"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-aurora" }
}

# Lab 5 owns its own subnet group over the main deploy's private subnets. We do
# NOT reuse the main db_subnet_group resource (that would couple the states);
# referencing the subnet IDs read-only is fine.
resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name_prefix}-aurora"
  subnet_ids = local.private_subnet_ids
  tags       = { Name = "${local.name_prefix}-aurora" }
}

# --- Aurora PostgreSQL cluster with a Secrets Manager-managed master password -

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${local.name_prefix}-aurora"
  engine             = "aurora-postgresql"
  engine_version     = "16.6"
  database_name      = "appdb"
  master_username    = "appadmin"

  # Aurora generates + rotates the master password and stores it in Secrets
  # Manager. The app reads it via IRSA (secretsmanager:GetSecretValue). This is
  # the locked DB-auth design for Lab 5.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  storage_encrypted       = true
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1

  tags = { Name = "${local.name_prefix}-aurora" }
}

resource "aws_rds_cluster_instance" "aurora_writer" {
  identifier         = "${local.name_prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  instance_class     = "db.t3.medium"

  tags = { Name = "${local.name_prefix}-aurora-writer" }
}

# --- Namespace for the Lab 5 workloads --------------------------------------

resource "kubernetes_namespace" "lab5" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/part-of" = "io107-lab5"
      "io107/student"             = var.student_id
    }
  }
}

# --- IRSA role the myapp ServiceAccount assumes -----------------------------
# The SA itself is created by Helm (don't double-create). This role trusts only
# system:serviceaccount:<lab5-ns>:myapp-sa and grants read of the Aurora secret.

data "aws_iam_policy_document" "irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${local.namespace}:${local.sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "myapp" {
  name               = "${local.name_prefix}-myapp"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust.json
  tags               = { Name = "${local.name_prefix}-myapp" }
}

# Allow reading exactly the Aurora-managed master-user secret, plus the KMS
# decrypt Secrets Manager needs to return the SecretString.
data "aws_iam_policy_document" "myapp_secret_access" {
  statement {
    sid       = "ReadAuroraSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_rds_cluster.aurora.master_user_secret[0].secret_arn]
  }

  statement {
    sid       = "DecryptAuroraSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_rds_cluster.aurora.master_user_secret[0].kms_key_id]
  }
}

resource "aws_iam_role_policy" "myapp_secret_access" {
  name   = "secret-access"
  role   = aws_iam_role.myapp.id
  policy = data.aws_iam_policy_document.myapp_secret_access.json
}

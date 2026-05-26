###############################################################################
# IO-107 SDLC Pipeline -- lab_env_student / main.tf
#
# Unified student-mode infrastructure. One `terraform apply` provisions:
#   - Network (VPC + subnets across 3 AZs + IGW + NAT)
#   - KMS keys (RDS, S3, logs)
#   - ECR repos for every containerised lab app
#   - Security groups (EKS workers, Aurora)
#   - DB subnet group (Aurora)
#   - EKS cluster + managed node group + IRSA OIDC provider
#   - Shared CodeBuild service role + CodePipeline service role
#   - Per-lab: CodePipeline + CodeBuild project + S3 artifact bucket
#   - lab1: K8s namespace `lab1-${var.student_id}`, IRSA roles, pipeline + buildspec wiring
#   - lab2: pipeline + buildspec wiring
#   - lab3: pipeline + buildspec wiring
#   - lab4: Aurora cluster `training-aurora-${var.student_id}`, pipeline + buildspec wiring
#
# Pre-requisites the caller must do MANUALLY (Terraform cannot do these):
#   1. Bootstrap an S3 bucket for the Terraform backend (one-time per account).
#      Use Terraform 1.10+ native S3 locking (`use_lockfile = true`) -- no DDB needed.
#   2. Install AWS CLI v2 + git on the apply host. The CodeCommit repos this
#      module creates are seeded from upstream fixture repos via a one-time
#      `git push --mirror` (see `null_resource.*_seed` blocks). Auth uses the
#      `aws codecommit credential-helper` and the apply host's IAM identity.
#
# Per-student source-control story:
#   - Each per-lab CodePipeline reads from a per-student `aws_codecommit_repository`
#     (NOT the upstream GitHub fixture). The CodeCommit repo is seeded once at
#     `terraform apply` from the fixture's `main` branch. Students `git clone`
#     their CodeCommit repo (URL is exposed as `<lab>_codecommit_clone_url`),
#     edit, and `git push origin main` -- that push triggers the student's own
#     pipeline only (no cross-student race, no fork required on GitHub).
#
# Tear down with `terraform destroy` -- everything is tagged with `StudentId`.
#
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  common_tags = {
    Course      = "IO-107 SDLC Pipeline"
    Environment = "training"
    ManagedBy   = "terraform"
    StudentId   = var.student_id
  }

  # Resource naming: every per-student resource carries the student_id suffix.
  name_prefix = "io107-${var.student_id}"
}

# ============================================================================
# NETWORK
# ============================================================================

resource "aws_vpc" "training" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.training.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                             = "${local.name_prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                         = "1"
    "kubernetes.io/cluster/${local.name_prefix}-eks" = "shared"
  })
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.training.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                                             = "${local.name_prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"                = "1"
    "kubernetes.io/cluster/${local.name_prefix}-eks" = "shared"
  })
}

resource "aws_internet_gateway" "training" {
  vpc_id = aws_vpc.training.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-igw" })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "training" {
  subnet_id     = aws_subnet.public[0].id
  allocation_id = aws_eip.nat.id
  tags          = merge(local.common_tags, { Name = "${local.name_prefix}-nat" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.training.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.training.id
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.training.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.training.id
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ============================================================================
# KMS
# ============================================================================

resource "aws_kms_key" "training_rds" {
  description             = "IO-107 SDLC Pipeline -- Aurora storage encryption (${var.student_id})"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_key" "training_s3" {
  description             = "IO-107 SDLC Pipeline -- S3 encryption (${var.student_id})"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.common_tags
}

resource "aws_kms_key" "training_logs" {
  description             = "IO-107 SDLC Pipeline -- CloudWatch logs encryption (${var.student_id})"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.common_tags
}

# ============================================================================
# ECR
# ============================================================================

resource "aws_ecr_repository" "app" {
  for_each = toset(["myapp", "nginx"])

  # Bare app name (no student_id prefix). The buildspec's docker push pattern is
  # `$ECR_REGISTRY/$APP_NAME:$IMAGE_TAG` where APP_NAME is "myapp" -- so the
  # repository must be named "myapp" exactly. Per-run isolation comes from the
  # whole module being torn down with `terraform destroy`; the unified module is
  # one-student-at-a-time by design.
  name                 = each.value
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.training_s3.arn
  }

  tags = merge(local.common_tags, { App = each.value })
}

# ============================================================================
# SECURITY GROUPS
# ============================================================================

resource "aws_security_group" "eks_workers" {
  name        = "${local.name_prefix}-eks-workers"
  description = "IO-107 SDLC Pipeline EKS worker nodes (${var.student_id})"
  vpc_id      = aws_vpc.training.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-eks-workers" })
}


resource "aws_security_group" "training_db" {
  name        = "${local.name_prefix}-training-db"
  description = "IO-107 SDLC Pipeline training Aurora SG -- ingress from EKS workers"
  vpc_id      = aws_vpc.training.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_workers.id]
    description     = "Postgres from EKS workers"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-training-db" })
}

resource "aws_db_subnet_group" "training" {
  name        = "${local.name_prefix}-training-aurora"
  description = "IO-107 SDLC Pipeline training Aurora -- private subnets across 3 AZs"
  subnet_ids  = aws_subnet.private[*].id
  tags        = merge(local.common_tags, { Name = "${local.name_prefix}-training-aurora" })
}



# ============================================================================
# EKS CLUSTER
# ============================================================================

resource "aws_iam_role" "eks_cluster" {
  name = "${local.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "training" {
  name     = "${local.name_prefix}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Access entries API is required so we can add the CodeBuild service role as a
  # cluster principal below. `API_AND_CONFIG_MAP` is the current EKS default but
  # we set it explicitly here so future provider versions don't surprise us.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = local.common_tags
}

# Grant the CodeBuild service role kubectl/helm access to the cluster. Without
# this, `helm upgrade` from CodeBuild fails with
#   "Kubernetes cluster unreachable: the server has asked for the client to
#    provide credentials"
# because the role is authenticated to AWS but not authorised in the cluster.
resource "aws_eks_access_entry" "codebuild" {
  cluster_name  = aws_eks_cluster.training.name
  principal_arn = aws_iam_role.codebuild_service.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "codebuild_admin" {
  cluster_name  = aws_eks_cluster.training.name
  principal_arn = aws_iam_role.codebuild_service.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.codebuild]
}

resource "aws_iam_role" "eks_nodes" {
  name = "${local.name_prefix}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "training" {
  cluster_name    = aws_eks_cluster.training.name
  node_group_name = "${local.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = var.eks_node_instance_types

  scaling_config {
    desired_size = var.eks_node_desired_size
    max_size     = var.eks_node_desired_size + 2
    min_size     = 1
  }

  depends_on = [aws_iam_role_policy_attachment.eks_nodes]
  tags       = local.common_tags
}

# IRSA OIDC provider
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.training.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_irsa" {
  url             = aws_eks_cluster.training.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  tags            = local.common_tags
}


# ============================================================================
# SHARED IAM ROLES -- CodeBuild + CodePipeline
# ============================================================================

resource "aws_iam_role" "codebuild_service" {
  name = "${local.name_prefix}-codebuild-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "codebuild_service" {
  name = "${local.name_prefix}-codebuild-service-inline"
  role = aws_iam_role.codebuild_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "eks:DescribeCluster",
          "eks:AccessKubernetesApi",
          "rds:DescribeDBClusters",
          "rds:DescribeDBInstances",
          "rds:ModifyDBCluster",
          "rds:CreateBlueGreenDeployment",
          "rds:DescribeBlueGreenDeployments",
          "rds:SwitchoverBlueGreenDeployment",
          "rds:DeleteBlueGreenDeployment",
          "rds:AddTagsToResource",
          "secretsmanager:GetSecretValue",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "sts:GetCallerIdentity",
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringLike = {
            "iam:PassedToService" = ["codebuild.amazonaws.com", "codepipeline.amazonaws.com"]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "codepipeline_service" {
  name = "${local.name_prefix}-codepipeline-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "codepipeline_service" {
  name = "${local.name_prefix}-codepipeline-service-inline"
  role = aws_iam_role.codepipeline_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild",
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:UploadArchive",
        "codecommit:CancelUploadArchive",
        "s3:GetObject",
        "s3:PutObject",
        "s3:GetBucketVersioning",
        "iam:PassRole"
      ]
      Resource = "*"
    }]
  })
}

# ============================================================================
# EVENTBRIDGE → CODEPIPELINE  (CodeCommit pushes don't auto-trigger pipelines;
# an EventBridge rule per lab fans `referenceUpdated` events into the pipeline)
# ============================================================================

resource "aws_iam_role" "eventbridge_codepipeline" {
  name = "${local.name_prefix}-eventbridge-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "eventbridge_codepipeline" {
  name = "${local.name_prefix}-eventbridge-codepipeline-inline"
  role = aws_iam_role.eventbridge_codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["codepipeline:StartPipelineExecution"]
      Resource = "*"
    }]
  })
}

# ============================================================================
# PER-LAB RESOURCES
# ============================================================================

# ----------------------------------------------------------------------------
# LAB1 -- Lab 1: End-to-End EKS Deployment Pipeline
# Fixture repo: 
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "lab1_artifacts" {
  count = var.enable_lab1 ? 1 : 0

  bucket        = "${local.name_prefix}-lab1-artifacts"
  force_destroy = true
  tags          = merge(local.common_tags, { Lab = "lab1" })
}

resource "aws_s3_bucket_versioning" "lab1_artifacts" {
  count  = var.enable_lab1 ? 1 : 0
  bucket = aws_s3_bucket.lab1_artifacts[0].id

  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lab1_artifacts" {
  count  = var.enable_lab1 ? 1 : 0
  bucket = aws_s3_bucket.lab1_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.training_s3.arn
    }
  }
}

# Per-student source-control repo. Seeded from the course monorepo
# (https://github.com/roi-cloud-fun/io-107.git) — specifically the `lab_1/`
# subdirectory, flattened to the CodeCommit repo's root. Students clone this
# (NOT the upstream monorepo) and push back to trigger their own pipeline only.
resource "aws_codecommit_repository" "lab1" {
  count = var.enable_lab1 ? 1 : 0

  repository_name = "${local.name_prefix}-lab1"
  description     = "IO-107 SDLC Pipeline lab1 -- per-student source repo (seeded from https://github.com/roi-cloud-fun/io-107.git lab_1/)"
  tags            = merge(local.common_tags, { Lab = "lab1" })
}

# One-time seeding: shallow-clone the monorepo, copy out the lab subdir as a
# fresh single-commit history, push as main to the per-student CodeCommit.
# Requires AWS CLI v2 + git on the apply host; auth via
# `aws codecommit credential-helper` (no SSH keys required).
resource "null_resource" "lab1_seed" {
  count = var.enable_lab1 ? 1 : 0

  triggers = {
    repo_arn       = aws_codecommit_repository.lab1[0].arn
    monorepo_url   = "https://github.com/roi-cloud-fun/io-107.git"
    fixture_subdir = "lab_1"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      WORK=$(mktemp -d)
      trap "rm -rf $WORK" EXIT
      git clone --depth=1 https://github.com/roi-cloud-fun/io-107.git "$WORK/seed"
      mkdir "$WORK/cc"
      cp -r "$WORK/seed/lab_1/." "$WORK/cc/"
      cd "$WORK/cc"
      git init -q -b main
      git config user.email "io107-bootstrap@example.invalid"
      git config user.name  "io107-bootstrap"
      git add -A
      git commit -q -m "Seed lab1 from https://github.com/roi-cloud-fun/io-107.git lab_1/"
      git -c credential.helper='!aws codecommit credential-helper $@' \
          -c credential.UseHttpPath=true \
          push --force ${aws_codecommit_repository.lab1[0].clone_url_http} main
    EOT
  }

  depends_on = [aws_codecommit_repository.lab1]
}

resource "aws_codebuild_project" "lab1" {
  count = var.enable_lab1 ? 1 : 0

  name         = "${local.name_prefix}-lab1-build"
  description  = "IO-107 SDLC Pipeline lab1 build project"
  service_role = aws_iam_role.codebuild_service.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "STUDENT_ID"
      value = var.student_id
    }
    environment_variable {
      name  = "CLUSTER_NAME"
      value = aws_eks_cluster.training.name
    }
    environment_variable {
      name  = "NAMESPACE"
      value = "lab1-${var.student_id}"
    }
    environment_variable {
      name  = "APP_NAME"
      value = "myapp"
    }
    environment_variable {
      name  = "ECR_REGISTRY"
      value = split("/", aws_ecr_repository.app["myapp"].repository_url)[0]
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = "dev"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.name_prefix}-lab1"
      stream_name = "build"
    }
  }

  tags = merge(local.common_tags, { Lab = "lab1" })
}

resource "aws_codepipeline" "lab1" {
  count = var.enable_lab1 ? 1 : 0

  name     = "${local.name_prefix}-lab1"
  role_arn = aws_iam_role.codepipeline_service.arn

  artifact_store {
    location = aws_s3_bucket.lab1_artifacts[0].bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName       = aws_codecommit_repository.lab1[0].repository_name
        BranchName           = "main"
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.lab1[0].name
      }
    }
  }

  tags = merge(local.common_tags, { Lab = "lab1" })

  depends_on = [null_resource.lab1_seed]
}

# EventBridge: a push to `main` on the per-student CodeCommit repo triggers
# the per-student pipeline. `PollForSourceChanges = false` on the Source action
# means CodePipeline won't poll -- this rule is the only trigger.
resource "aws_cloudwatch_event_rule" "lab1_trigger" {
  count = var.enable_lab1 ? 1 : 0

  name        = "${local.name_prefix}-lab1-trigger"
  description = "Fire lab1 pipeline on push to main of per-student CodeCommit repo"

  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [aws_codecommit_repository.lab1[0].arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })

  tags = merge(local.common_tags, { Lab = "lab1" })
}

resource "aws_cloudwatch_event_target" "lab1_trigger" {
  count = var.enable_lab1 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.lab1_trigger[0].name
  target_id = "${local.name_prefix}-lab1-pipeline"
  arn       = aws_codepipeline.lab1[0].arn
  role_arn  = aws_iam_role.eventbridge_codepipeline.arn
}


resource "kubernetes_namespace" "lab1" {
  count = var.enable_lab1 ? 1 : 0

  metadata {
    name = "lab1-${var.student_id}"
    labels = {
      "io107/course"  = "io107"
      "io107/lab"     = "lab1"
      "io107/student" = var.student_id
    }
  }

  depends_on = [aws_eks_node_group.training]
}



resource "aws_iam_role" "lab1_myapp_dev_role" {
  count = var.enable_lab1 ? 1 : 0

  name = "${local.name_prefix}-myapp-dev-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks_irsa.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.training.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:lab1-${var.student_id}:myapp-sa"
          "${replace(aws_eks_cluster.training.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Lab = "lab1", IrsaRole = "myapp-dev-role" })
}

resource "aws_iam_role_policy" "lab1_myapp_dev_role" {
  count = var.enable_lab1 ? 1 : 0
  name  = "${local.name_prefix}-myapp-dev-role-inline"
  role  = aws_iam_role.lab1_myapp_dev_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [
          aws_kms_key.training_s3.arn,
          aws_kms_key.training_logs.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "lab1_myapp_stg_role" {
  count = var.enable_lab1 ? 1 : 0

  name = "${local.name_prefix}-myapp-stg-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks_irsa.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.training.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:lab1-${var.student_id}:myapp-sa"
          "${replace(aws_eks_cluster.training.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Lab = "lab1", IrsaRole = "myapp-stg-role" })
}

resource "aws_iam_role_policy" "lab1_myapp_stg_role" {
  count = var.enable_lab1 ? 1 : 0
  name  = "${local.name_prefix}-myapp-stg-role-inline"
  role  = aws_iam_role.lab1_myapp_stg_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [
          aws_kms_key.training_s3.arn,
          aws_kms_key.training_logs.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}




# ----------------------------------------------------------------------------
# LAB2 -- Lab 2: Lambda Deployment with SAM
# Fixture repo: 
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "lab2_artifacts" {
  count = var.enable_lab2 ? 1 : 0

  bucket        = "${local.name_prefix}-lab2-artifacts"
  force_destroy = true
  tags          = merge(local.common_tags, { Lab = "lab2" })
}

resource "aws_s3_bucket_versioning" "lab2_artifacts" {
  count  = var.enable_lab2 ? 1 : 0
  bucket = aws_s3_bucket.lab2_artifacts[0].id

  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lab2_artifacts" {
  count  = var.enable_lab2 ? 1 : 0
  bucket = aws_s3_bucket.lab2_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.training_s3.arn
    }
  }
}

# Per-student source-control repo. Seeded from the course monorepo
# (https://github.com/roi-cloud-fun/io-107.git) — specifically the `lab_2/`
# subdirectory, flattened to the CodeCommit repo's root. Students clone this
# (NOT the upstream monorepo) and push back to trigger their own pipeline only.
resource "aws_codecommit_repository" "lab2" {
  count = var.enable_lab2 ? 1 : 0

  repository_name = "${local.name_prefix}-lab2"
  description     = "IO-107 SDLC Pipeline lab2 -- per-student source repo (seeded from https://github.com/roi-cloud-fun/io-107.git lab_2/)"
  tags            = merge(local.common_tags, { Lab = "lab2" })
}

# One-time seeding: shallow-clone the monorepo, copy out the lab subdir as a
# fresh single-commit history, push as main to the per-student CodeCommit.
# Requires AWS CLI v2 + git on the apply host; auth via
# `aws codecommit credential-helper` (no SSH keys required).
resource "null_resource" "lab2_seed" {
  count = var.enable_lab2 ? 1 : 0

  triggers = {
    repo_arn       = aws_codecommit_repository.lab2[0].arn
    monorepo_url   = "https://github.com/roi-cloud-fun/io-107.git"
    fixture_subdir = "lab_2"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      WORK=$(mktemp -d)
      trap "rm -rf $WORK" EXIT
      git clone --depth=1 https://github.com/roi-cloud-fun/io-107.git "$WORK/seed"
      mkdir "$WORK/cc"
      cp -r "$WORK/seed/lab_2/." "$WORK/cc/"
      cd "$WORK/cc"
      git init -q -b main
      git config user.email "io107-bootstrap@example.invalid"
      git config user.name  "io107-bootstrap"
      git add -A
      git commit -q -m "Seed lab2 from https://github.com/roi-cloud-fun/io-107.git lab_2/"
      git -c credential.helper='!aws codecommit credential-helper $@' \
          -c credential.UseHttpPath=true \
          push --force ${aws_codecommit_repository.lab2[0].clone_url_http} main
    EOT
  }

  depends_on = [aws_codecommit_repository.lab2]
}

resource "aws_codebuild_project" "lab2" {
  count = var.enable_lab2 ? 1 : 0

  name         = "${local.name_prefix}-lab2-build"
  description  = "IO-107 SDLC Pipeline lab2 build project"
  service_role = aws_iam_role.codebuild_service.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "STUDENT_ID"
      value = var.student_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.name_prefix}-lab2"
      stream_name = "build"
    }
  }

  tags = merge(local.common_tags, { Lab = "lab2" })
}

resource "aws_codepipeline" "lab2" {
  count = var.enable_lab2 ? 1 : 0

  name     = "${local.name_prefix}-lab2"
  role_arn = aws_iam_role.codepipeline_service.arn

  artifact_store {
    location = aws_s3_bucket.lab2_artifacts[0].bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName       = aws_codecommit_repository.lab2[0].repository_name
        BranchName           = "main"
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.lab2[0].name
      }
    }
  }

  tags = merge(local.common_tags, { Lab = "lab2" })

  depends_on = [null_resource.lab2_seed]
}

# EventBridge: a push to `main` on the per-student CodeCommit repo triggers
# the per-student pipeline. `PollForSourceChanges = false` on the Source action
# means CodePipeline won't poll -- this rule is the only trigger.
resource "aws_cloudwatch_event_rule" "lab2_trigger" {
  count = var.enable_lab2 ? 1 : 0

  name        = "${local.name_prefix}-lab2-trigger"
  description = "Fire lab2 pipeline on push to main of per-student CodeCommit repo"

  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [aws_codecommit_repository.lab2[0].arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })

  tags = merge(local.common_tags, { Lab = "lab2" })
}

resource "aws_cloudwatch_event_target" "lab2_trigger" {
  count = var.enable_lab2 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.lab2_trigger[0].name
  target_id = "${local.name_prefix}-lab2-pipeline"
  arn       = aws_codepipeline.lab2[0].arn
  role_arn  = aws_iam_role.eventbridge_codepipeline.arn
}







# ----------------------------------------------------------------------------
# LAB3 -- Lab 3: Policy-as-Code Evaluation & Failure Remediation
# Fixture repo: https://github.com/jessetop/io107-lab3-policy-violations
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "lab3_artifacts" {
  count = var.enable_lab3 ? 1 : 0

  bucket        = "${local.name_prefix}-lab3-artifacts"
  force_destroy = true
  tags          = merge(local.common_tags, { Lab = "lab3" })
}

resource "aws_s3_bucket_versioning" "lab3_artifacts" {
  count  = var.enable_lab3 ? 1 : 0
  bucket = aws_s3_bucket.lab3_artifacts[0].id

  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lab3_artifacts" {
  count  = var.enable_lab3 ? 1 : 0
  bucket = aws_s3_bucket.lab3_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.training_s3.arn
    }
  }
}

# Per-student source-control repo. Seeded from the course monorepo
# (https://github.com/roi-cloud-fun/io-107.git) — specifically the `lab_3/`
# subdirectory, flattened to the CodeCommit repo's root. Students clone this
# (NOT the upstream monorepo) and push back to trigger their own pipeline only.
resource "aws_codecommit_repository" "lab3" {
  count = var.enable_lab3 ? 1 : 0

  repository_name = "${local.name_prefix}-lab3"
  description     = "IO-107 SDLC Pipeline lab3 -- per-student source repo (seeded from https://github.com/roi-cloud-fun/io-107.git lab_3/)"
  tags            = merge(local.common_tags, { Lab = "lab3" })
}

# One-time seeding: shallow-clone the monorepo, copy out the lab subdir as a
# fresh single-commit history, push as main to the per-student CodeCommit.
# Requires AWS CLI v2 + git on the apply host; auth via
# `aws codecommit credential-helper` (no SSH keys required).
resource "null_resource" "lab3_seed" {
  count = var.enable_lab3 ? 1 : 0

  triggers = {
    repo_arn       = aws_codecommit_repository.lab3[0].arn
    monorepo_url   = "https://github.com/roi-cloud-fun/io-107.git"
    fixture_subdir = "lab_3"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      WORK=$(mktemp -d)
      trap "rm -rf $WORK" EXIT
      git clone --depth=1 https://github.com/roi-cloud-fun/io-107.git "$WORK/seed"
      mkdir "$WORK/cc"
      cp -r "$WORK/seed/lab_3/." "$WORK/cc/"
      cd "$WORK/cc"
      git init -q -b main
      git config user.email "io107-bootstrap@example.invalid"
      git config user.name  "io107-bootstrap"
      git add -A
      git commit -q -m "Seed lab3 from https://github.com/roi-cloud-fun/io-107.git lab_3/"
      git -c credential.helper='!aws codecommit credential-helper $@' \
          -c credential.UseHttpPath=true \
          push --force ${aws_codecommit_repository.lab3[0].clone_url_http} main
    EOT
  }

  depends_on = [aws_codecommit_repository.lab3]
}

resource "aws_codebuild_project" "lab3" {
  count = var.enable_lab3 ? 1 : 0

  name         = "${local.name_prefix}-lab3-build"
  description  = "IO-107 SDLC Pipeline lab3 build project"
  service_role = aws_iam_role.codebuild_service.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "STUDENT_ID"
      value = var.student_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.name_prefix}-lab3"
      stream_name = "build"
    }
  }

  tags = merge(local.common_tags, { Lab = "lab3" })
}

resource "aws_codepipeline" "lab3" {
  count = var.enable_lab3 ? 1 : 0

  name     = "${local.name_prefix}-lab3"
  role_arn = aws_iam_role.codepipeline_service.arn

  artifact_store {
    location = aws_s3_bucket.lab3_artifacts[0].bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName       = aws_codecommit_repository.lab3[0].repository_name
        BranchName           = "main"
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.lab3[0].name
      }
    }
  }

  tags = merge(local.common_tags, { Lab = "lab3" })

  depends_on = [null_resource.lab3_seed]
}

# EventBridge: a push to `main` on the per-student CodeCommit repo triggers
# the per-student pipeline. `PollForSourceChanges = false` on the Source action
# means CodePipeline won't poll -- this rule is the only trigger.
resource "aws_cloudwatch_event_rule" "lab3_trigger" {
  count = var.enable_lab3 ? 1 : 0

  name        = "${local.name_prefix}-lab3-trigger"
  description = "Fire lab3 pipeline on push to main of per-student CodeCommit repo"

  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [aws_codecommit_repository.lab3[0].arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })

  tags = merge(local.common_tags, { Lab = "lab3" })
}

resource "aws_cloudwatch_event_target" "lab3_trigger" {
  count = var.enable_lab3 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.lab3_trigger[0].name
  target_id = "${local.name_prefix}-lab3-pipeline"
  arn       = aws_codepipeline.lab3[0].arn
  role_arn  = aws_iam_role.eventbridge_codepipeline.arn
}







# ----------------------------------------------------------------------------
# LAB4 -- Lab 4: Aurora Blue/Green Deployment via Terraform + Pipeline
# Fixture repo: https://github.com/jessetop/io107-lab4-aurora-bluegreen
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "lab4_artifacts" {
  count = var.enable_lab4 ? 1 : 0

  bucket        = "${local.name_prefix}-lab4-artifacts"
  force_destroy = true
  tags          = merge(local.common_tags, { Lab = "lab4" })
}

resource "aws_s3_bucket_versioning" "lab4_artifacts" {
  count  = var.enable_lab4 ? 1 : 0
  bucket = aws_s3_bucket.lab4_artifacts[0].id

  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lab4_artifacts" {
  count  = var.enable_lab4 ? 1 : 0
  bucket = aws_s3_bucket.lab4_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.training_s3.arn
    }
  }
}

# Per-student source-control repo. Seeded from the course monorepo
# (https://github.com/roi-cloud-fun/io-107.git) — specifically the `lab_4/`
# subdirectory, flattened to the CodeCommit repo's root. Students clone this
# (NOT the upstream monorepo) and push back to trigger their own pipeline only.
resource "aws_codecommit_repository" "lab4" {
  count = var.enable_lab4 ? 1 : 0

  repository_name = "${local.name_prefix}-lab4"
  description     = "IO-107 SDLC Pipeline lab4 -- per-student source repo (seeded from https://github.com/roi-cloud-fun/io-107.git lab_4/)"
  tags            = merge(local.common_tags, { Lab = "lab4" })
}

# One-time seeding: shallow-clone the monorepo, copy out the lab subdir as a
# fresh single-commit history, push as main to the per-student CodeCommit.
# Requires AWS CLI v2 + git on the apply host; auth via
# `aws codecommit credential-helper` (no SSH keys required).
resource "null_resource" "lab4_seed" {
  count = var.enable_lab4 ? 1 : 0

  triggers = {
    repo_arn       = aws_codecommit_repository.lab4[0].arn
    monorepo_url   = "https://github.com/roi-cloud-fun/io-107.git"
    fixture_subdir = "lab_4"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      WORK=$(mktemp -d)
      trap "rm -rf $WORK" EXIT
      git clone --depth=1 https://github.com/roi-cloud-fun/io-107.git "$WORK/seed"
      mkdir "$WORK/cc"
      cp -r "$WORK/seed/lab_4/." "$WORK/cc/"
      cd "$WORK/cc"
      git init -q -b main
      git config user.email "io107-bootstrap@example.invalid"
      git config user.name  "io107-bootstrap"
      git add -A
      git commit -q -m "Seed lab4 from https://github.com/roi-cloud-fun/io-107.git lab_4/"
      git -c credential.helper='!aws codecommit credential-helper $@' \
          -c credential.UseHttpPath=true \
          push --force ${aws_codecommit_repository.lab4[0].clone_url_http} main
    EOT
  }

  depends_on = [aws_codecommit_repository.lab4]
}

resource "aws_codebuild_project" "lab4" {
  count = var.enable_lab4 ? 1 : 0

  name         = "${local.name_prefix}-lab4-build"
  description  = "IO-107 SDLC Pipeline lab4 build project"
  service_role = aws_iam_role.codebuild_service.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "STUDENT_ID"
      value = var.student_id
    }
    environment_variable {
      name  = "CLUSTER_ID"
      value = aws_rds_cluster.lab4_aurora[0].id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${local.name_prefix}-lab4"
      stream_name = "build"
    }
  }

  tags = merge(local.common_tags, { Lab = "lab4" })
}

resource "aws_codepipeline" "lab4" {
  count = var.enable_lab4 ? 1 : 0

  name     = "${local.name_prefix}-lab4"
  role_arn = aws_iam_role.codepipeline_service.arn

  artifact_store {
    location = aws_s3_bucket.lab4_artifacts[0].bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName       = aws_codecommit_repository.lab4[0].repository_name
        BranchName           = "main"
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.lab4[0].name
      }
    }
  }

  tags = merge(local.common_tags, { Lab = "lab4" })

  depends_on = [null_resource.lab4_seed]
}

# EventBridge: a push to `main` on the per-student CodeCommit repo triggers
# the per-student pipeline. `PollForSourceChanges = false` on the Source action
# means CodePipeline won't poll -- this rule is the only trigger.
resource "aws_cloudwatch_event_rule" "lab4_trigger" {
  count = var.enable_lab4 ? 1 : 0

  name        = "${local.name_prefix}-lab4-trigger"
  description = "Fire lab4 pipeline on push to main of per-student CodeCommit repo"

  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [aws_codecommit_repository.lab4[0].arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })

  tags = merge(local.common_tags, { Lab = "lab4" })
}

resource "aws_cloudwatch_event_target" "lab4_trigger" {
  count = var.enable_lab4 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.lab4_trigger[0].name
  target_id = "${local.name_prefix}-lab4-pipeline"
  arn       = aws_codepipeline.lab4[0].arn
  role_arn  = aws_iam_role.eventbridge_codepipeline.arn
}






resource "aws_rds_cluster" "lab4_aurora" {
  count = var.enable_lab4 ? 1 : 0

  cluster_identifier          = "${local.name_prefix}-lab4-aurora"
  engine                      = "aurora-postgresql"
  engine_version              = "16.11" # Lab 4 bumps this via Blue/Green; 16.13 is the target
  database_name               = "training"
  master_username             = "training_admin"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.training.name
  vpc_security_group_ids = [aws_security_group.training_db.id]

  storage_encrypted = true
  kms_key_id        = aws_kms_key.training_rds.arn

  backup_retention_period             = 1
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  iam_database_authentication_enabled = true
  deletion_protection                 = false
  skip_final_snapshot                 = true

  lifecycle {
    # Lab 4 flips engine_version via the CLI Blue/Green flow, not direct apply.
    ignore_changes = [engine_version]
  }

  tags = merge(local.common_tags, { Lab = "lab4" })
}

resource "aws_rds_cluster_instance" "lab4_aurora_writer" {
  count = var.enable_lab4 ? 1 : 0

  identifier         = "${local.name_prefix}-lab4-aurora-writer"
  cluster_identifier = aws_rds_cluster.lab4_aurora[0].id
  engine             = aws_rds_cluster.lab4_aurora[0].engine
  engine_version     = aws_rds_cluster.lab4_aurora[0].engine_version
  instance_class     = "db.t3.medium"

  tags = merge(local.common_tags, { Lab = "lab4" })
}



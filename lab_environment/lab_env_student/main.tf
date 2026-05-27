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
#   - lab1: K8s namespace `lab1-<student-id>-<run-suffix>`, IRSA roles, pipeline + buildspec wiring
#   - lab2: pipeline + buildspec wiring
#   - lab3: pipeline + buildspec wiring
#   - lab4: Aurora cluster `<course-id>-<student-id>-<run-suffix>-lab4-aurora`, pipeline + buildspec wiring
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

# Random suffix that uniquifies every resource name across applies. AWS doesn't
# always propagate deletes instantly (EKS namespaces, ENIs, KMS aliases, S3
# buckets in deletion-protected state, etc.) so re-applying with the same
# student_id can collide with leftovers from a prior run. The suffix sidesteps
# that entirely -- each `terraform apply` from a fresh state gets a new 6-char
# hex tag, guaranteeing no name collisions. Existing applies stay stable
# because the random_id persists in Terraform state.
#
# To pin a specific suffix (e.g. for reproducible LTF runs), set
# `name_suffix` in terraform.tfvars; the random_id is then ignored.
resource "random_id" "run" {
  byte_length = 3
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Effective unique tag: explicit override > random per-apply.
  _run_suffix          = var.name_suffix != "" ? var.name_suffix : random_id.run.hex
  effective_student_id = "${var.student_id}-${local._run_suffix}"

  common_tags = {
    Course      = "IO-107 SDLC Pipeline"
    Environment = "training"
    ManagedBy   = "terraform"
    StudentId   = var.student_id
    RunSuffix   = local._run_suffix
  }

  # Resource naming: every per-student resource carries the student_id +
  # per-run suffix. `name_prefix` is the canonical prefix used by ALL
  # resource names in this module.
  name_prefix = "io107-${local.effective_student_id}"
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

# Pre-destroy cleanup for orphaned load balancers in the VPC.
#
# WHY THIS EXISTS:
#   A Kubernetes Service of `type: LoadBalancer` (Lab 1's myapp Helm chart
#   creates one) causes the in-cluster controller -- or the AWS Load
#   Balancer Controller, if installed -- to provision an NLB/ALB in this
#   VPC's subnets. Terraform does NOT manage that LB; it was created by an
#   AWS API call from inside the cluster.
#
#   When `terraform destroy` runs, the cluster is torn down before the
#   controller gets a chance to clean up the LB. The orphaned LB holds:
#     - ENIs in the public + private subnets (blocks aws_subnet destroy)
#     - An EIP mapped to the VPC (blocks aws_internet_gateway detach/destroy)
#   Result: 20+ minute hang on `terraform destroy`, then DependencyViolation.
#
# WHAT THIS DOES (destroy-only, no-op on create):
#   1. If the cluster still exists, ask it to delete all LB-type Services
#      via kubectl, then wait 60s for the LB controller to release them.
#   2. Belt-and-braces: list any remaining LBs (v1 ELB + v2 ALB/NLB) in the
#      VPC and force-delete them via AWS CLI.
#   3. Sweep any unattached ENIs left in the VPC.
#
# WHY ON aws_vpc:
#   This resource depends on `aws_vpc.training.id`, so Terraform destroys it
#   BEFORE the VPC. The destroy provisioner runs while the VPC still exists
#   and we can still query it. By the time Terraform tries to destroy
#   subnets/IGW, the LBs (and their ENIs/EIPs) are already gone.
resource "null_resource" "vpc_lb_cleanup" {
  triggers = {
    cluster_name = aws_eks_cluster.training.name
    vpc_id       = aws_vpc.training.id
    region       = var.aws_region
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set +e
      CLUSTER="${self.triggers.cluster_name}"
      VPC="${self.triggers.vpc_id}"
      REGION="${self.triggers.region}"

      echo "Pre-destroy: cleaning up orphaned load balancers in $VPC"

      # 1) Best-effort: ask K8s to delete LB services so the in-cluster
      #    controller releases them cleanly. Skip silently if the cluster
      #    is already gone or kubectl is unavailable.
      if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
        if command -v kubectl >/dev/null 2>&1; then
          aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1
          kubectl delete svc -A --field-selector spec.type=LoadBalancer --timeout=120s 2>&1 | sed 's/^/  /'
          echo "  waiting 60s for LB controller to deprovision..."
          sleep 60
        fi
      fi

      # 2) Belt-and-braces: directly delete any LBs still in the VPC.
      for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
                     --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" \
                     --output text 2>/dev/null); do
        echo "  deleting v2 LB: $arn"
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION"
      done
      for name in $(aws elb describe-load-balancers --region "$REGION" \
                      --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" \
                      --output text 2>/dev/null); do
        echo "  deleting classic ELB: $name"
        aws elb delete-load-balancer --load-balancer-name "$name" --region "$REGION"
      done

      # 3) Give AWS a moment to release ENIs.
      sleep 30

      # 4) Sweep any unattached ENIs left in the VPC.
      for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
                     --filters "Name=vpc-id,Values=$VPC" "Name=status,Values=available" \
                     --query "NetworkInterfaces[*].NetworkInterfaceId" \
                     --output text 2>/dev/null); do
        echo "  deleting orphaned ENI: $eni"
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION"
      done

      echo "Pre-destroy LB cleanup complete."
      exit 0
    EOT
  }
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

# Grant the host running `terraform apply` cluster admin -- otherwise the
# kubernetes provider (used to create per-lab namespaces) fails with
# "Error: Unauthorized".
#
# Why this is a null_resource instead of `aws_eks_access_entry`:
#   `bootstrap_cluster_creator_admin_permissions = true` on the cluster (above)
#   makes EKS auto-create an access entry for the IAM principal that creates
#   the cluster. When that principal is the same as the apply host (the common
#   case -- you ran `terraform apply` from an EC2 instance with an instance
#   profile, and the same EC2 will keep applying), an explicit
#   `aws_eks_access_entry` resource collides with the auto-created one and
#   `terraform apply` fails with `ResourceInUseException` (409). The AWS
#   provider doesn't expose an "adopt on conflict" mode for this resource.
#
#   The AWS API itself IS idempotent if you tolerate the 409: re-calling
#   create-access-entry on an existing principal returns 409 but the cluster
#   state is correct; associate-access-policy is naturally idempotent (same
#   principal+policy+scope is a no-op). So we drive both API calls from a
#   null_resource that suppresses the 409 -- giving us a create-or-adopt
#   workflow that's also robust to stale state from prior partial applies.
#
# Derivation of the principal ARN: if `apply_host_principal_arn` is set, use
# it verbatim. Otherwise infer from the caller identity:
#   - assumed-role ARN (e.g. EC2 instance profile, SSO session, Lambda):
#       arn:aws:sts::<acct>:assumed-role/<RoleName>/<session>
#     ->  arn:aws:iam::<acct>:role/<RoleName>
#   - direct IAM user/role ARN: pass through unchanged.
locals {
  _caller_arn = data.aws_caller_identity.current.arn
  # An STS assumed-role ARN looks like:
  #   arn:aws:sts::<acct>:assumed-role/<RoleName>/<SessionName>
  # The `:assumed-role/` substring is the reliable marker. Earlier versions of
  # this logic used `contains(split(":", arn), "assumed-role")` which never
  # matched because `split(":", ...)` keeps `assumed-role/<Role>/<Session>` as
  # a single trailing element, not a bare "assumed-role" token.
  _caller_arn_is_assumed_role = can(regex(":assumed-role/", local._caller_arn))
  _derived_apply_host_arn = (
    local._caller_arn_is_assumed_role
    # split("/", "arn:aws:sts::ACCT:assumed-role/RoleName/Session")
    #   = ["arn:aws:sts::ACCT:assumed-role", "RoleName", "Session"]
    # so index [1] is the role name.
    ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${split("/", local._caller_arn)[1]}"
    : local._caller_arn
  )
  apply_host_principal_arn = var.apply_host_principal_arn != "" ? var.apply_host_principal_arn : local._derived_apply_host_arn
}

resource "null_resource" "apply_host_eks_access" {
  triggers = {
    cluster_name  = aws_eks_cluster.training.name
    principal_arn = local.apply_host_principal_arn
    region        = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CLUSTER="${self.triggers.cluster_name}"
      PRINCIPAL="${self.triggers.principal_arn}"
      REGION="${self.triggers.region}"
      ERR=$(mktemp)
      trap 'rm -f "$ERR"' EXIT

      # 1) Create access entry -- tolerate 409 (means it already exists, fine).
      if aws eks create-access-entry \
            --cluster-name "$CLUSTER" \
            --principal-arn "$PRINCIPAL" \
            --type STANDARD \
            --region "$REGION" >/dev/null 2>"$ERR"; then
        echo "created access entry for $PRINCIPAL on $CLUSTER"
      else
        if grep -q ResourceInUseException "$ERR"; then
          echo "access entry for $PRINCIPAL on $CLUSTER already exists -- adopting"
        else
          cat "$ERR" >&2
          exit 1
        fi
      fi

      # 2) Associate the cluster admin policy -- this is naturally idempotent;
      #    AWS returns the existing association on re-invocation, no error.
      aws eks associate-access-policy \
        --cluster-name "$CLUSTER" \
        --principal-arn "$PRINCIPAL" \
        --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
        --access-scope type=cluster \
        --region "$REGION" >/dev/null
      echo "ensured AmazonEKSClusterAdminPolicy on $PRINCIPAL for $CLUSTER"
    EOT
  }

  # When the cluster goes away, all access entries on it go with it -- no
  # destroy-time cleanup is needed for this null_resource.
  depends_on = [aws_eks_cluster.training]
}

# EKS access entries take ~30s to become effective in the cluster data plane
# after the API call returns. Without this wait, the very next resource that
# uses the kubernetes provider (kubernetes_namespace) hits "Unauthorized"
# even though the access entry was just created. 45s is conservative.
resource "time_sleep" "wait_for_apply_host_access" {
  create_duration = "45s"
  depends_on      = [null_resource.apply_host_eks_access]
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
            "iam:PassedToService" = [
              "codebuild.amazonaws.com",
              "codepipeline.amazonaws.com",
              "lambda.amazonaws.com",
              "apigateway.amazonaws.com",
              "cloudformation.amazonaws.com",
              "codedeploy.amazonaws.com",
            ]
          }
        }
      },
      # Lab 2 uses `sam deploy`, which deploys a CloudFormation stack that
      # creates Lambda functions and an API Gateway. CodeBuild executes
      # `sam deploy --capabilities CAPABILITY_IAM`, so the build role must
      # be able to drive CloudFormation + create/manage the Lambda + API GW
      # resources + manage the IAM roles that CFN creates for those Lambdas.
      # Scoped to "*" because the resource ARNs are not known at apply time
      # (CFN generates them); this is acceptable for a per-student lab
      # account but would NOT be acceptable in production.
      {
        Effect = "Allow"
        Action = [
          "cloudformation:CreateStack",
          "cloudformation:UpdateStack",
          "cloudformation:DeleteStack",
          "cloudformation:DescribeStacks",
          "cloudformation:DescribeStackEvents",
          "cloudformation:DescribeStackResource",
          "cloudformation:DescribeStackResources",
          "cloudformation:GetTemplate",
          "cloudformation:GetTemplateSummary",
          "cloudformation:ListStacks",
          "cloudformation:ListStackResources",
          "cloudformation:CreateChangeSet",
          "cloudformation:DescribeChangeSet",
          "cloudformation:ExecuteChangeSet",
          "cloudformation:DeleteChangeSet",
          "cloudformation:ValidateTemplate",
          "lambda:CreateFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:DeleteFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListFunctions",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:TagResource",
          "lambda:UntagResource",
          "lambda:PublishVersion",
          "lambda:CreateAlias",
          "lambda:UpdateAlias",
          "lambda:DeleteAlias",
          "lambda:GetAlias",
          "apigateway:GET",
          "apigateway:POST",
          "apigateway:PUT",
          "apigateway:PATCH",
          "apigateway:DELETE",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          # SAM's AutoPublishAlias + DeploymentPreference (Canary10Percent5Minutes)
          # provisions an AWS::CodeDeploy::Application + DeploymentGroup as part
          # of the CFN stack. CodeBuild needs these to drive CFN through that.
          # Scoped to "*" because the resource ARNs include CFN-generated suffixes
          # only known at deploy time. Acceptable for a lab account.
          "codedeploy:CreateApplication",
          "codedeploy:DeleteApplication",
          "codedeploy:GetApplication",
          "codedeploy:UpdateApplication",
          "codedeploy:CreateDeploymentGroup",
          "codedeploy:DeleteDeploymentGroup",
          "codedeploy:GetDeploymentGroup",
          "codedeploy:UpdateDeploymentGroup",
          "codedeploy:CreateDeployment",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          "codedeploy:RegisterApplicationRevision",
          "codedeploy:TagResource",
          "codedeploy:UntagResource",
          "codedeploy:ListTagsForResource",
          # SAM's DeploymentPreference references an ApiErrorAlarm
          # (AWS::CloudWatch::Alarm). The CFN stack creates that alarm.
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:DescribeAlarms",
        ]
        Resource = "*"
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

  # The seed pushes lab fixture code to main, which fires the EventBridge
  # rule, which kicks off the per-student CodePipeline. The pipeline runs
  # CodeBuild, which runs `helm upgrade --install` (lab1) / `sam deploy`
  # (lab2) / `terraform plan + apply` (lab3, lab4) against AWS.
  #
  # That auto-trigger happens DURING `terraform apply`, not after. So we
  # must not seed (and thus trigger the pipeline) until every AWS resource
  # the pipeline's build needs is fully ready. Otherwise the first
  # pipeline run races the infrastructure and fails (e.g. lab1's helm
  # install hits an EKS API that isn't accepting traffic yet, or the
  # CodeBuild project's IAM permissions are mid-propagation).
  #
  # Concretely, the EKS-using labs (lab1) need: cluster + node group +
  # CodeBuild's access entry + the apply-host's access entry + the 45s
  # propagation sleep. The non-EKS labs (lab2 SAM, lab3 OPA, lab4 Aurora
  # CLI) still wait on these same gates -- harmless, and it keeps the
  # depends_on consistent across labs.
  depends_on = [
    aws_codecommit_repository.lab1,
    aws_codebuild_project.lab1,
    aws_eks_node_group.training,
    aws_eks_access_policy_association.codebuild_admin,
    null_resource.apply_host_eks_access,
    time_sleep.wait_for_apply_host_access,
    aws_codepipeline.lab1,
    aws_cloudwatch_event_rule.lab1_trigger,
    aws_cloudwatch_event_target.lab1_trigger,
  ]
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
      value = "lab1-${local.effective_student_id}"
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
    # IRSA role ARNs injected into the Helm chart at deploy time (see
    # buildspec.yml post_build). The chart's values-*.yaml files no longer
    # hardcode an account ID -- the pipeline picks the right ARN based on
    # $ENVIRONMENT.
    environment_variable {
      name  = "IRSA_ROLE_ARN_DEV"
      value = try(aws_iam_role.lab1_myapp_dev_role[0].arn, "")
    }
    environment_variable {
      name  = "IRSA_ROLE_ARN_STG"
      value = try(aws_iam_role.lab1_myapp_stg_role[0].arn, "")
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

  # NOTE: previously this had `depends_on = [null_resource.<lab>_seed]` so
  # the pipeline was created only after the repo was populated. Reversed
  # for two reasons:
  #   1. The seed now depends on the pipeline (so its push triggers the
  #      already-existing pipeline cleanly), which would create a cycle.
  #   2. CodePipeline can be created against an unpopulated CodeCommit
  #      branch -- with PollForSourceChanges = false (above) it just
  #      sits idle until the EventBridge rule fires it.
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


# K8s namespace `lab1-${local.effective_student_id}` is
# created on demand by the lab's CodeBuild pipeline:
#   helm upgrade --install ... --create-namespace
# We deliberately do NOT manage it here as a `kubernetes_namespace` resource
# because that races with the pipeline -- the CodeCommit seed scripts above
# trigger the pipeline at apply time, and Helm's `--create-namespace` often
# creates the namespace before Terraform's kubernetes provider gets to it,
# producing "namespaces ... already exists" errors.
#
# The IRSA OIDC trust condition below references the namespace by literal
# string in the IAM policy; no Terraform resource-level dependency on the
# K8s namespace existing.



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
          "${replace(aws_eks_cluster.training.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:lab1-${local.effective_student_id}:myapp-sa"
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
          "${replace(aws_eks_cluster.training.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:lab1-${local.effective_student_id}:myapp-sa"
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

  # The seed pushes lab fixture code to main, which fires the EventBridge
  # rule, which kicks off the per-student CodePipeline. The pipeline runs
  # CodeBuild, which runs `helm upgrade --install` (lab1) / `sam deploy`
  # (lab2) / `terraform plan + apply` (lab3, lab4) against AWS.
  #
  # That auto-trigger happens DURING `terraform apply`, not after. So we
  # must not seed (and thus trigger the pipeline) until every AWS resource
  # the pipeline's build needs is fully ready. Otherwise the first
  # pipeline run races the infrastructure and fails (e.g. lab1's helm
  # install hits an EKS API that isn't accepting traffic yet, or the
  # CodeBuild project's IAM permissions are mid-propagation).
  #
  # Concretely, the EKS-using labs (lab1) need: cluster + node group +
  # CodeBuild's access entry + the apply-host's access entry + the 45s
  # propagation sleep. The non-EKS labs (lab2 SAM, lab3 OPA, lab4 Aurora
  # CLI) still wait on these same gates -- harmless, and it keeps the
  # depends_on consistent across labs.
  depends_on = [
    aws_codecommit_repository.lab2,
    aws_codebuild_project.lab2,
    aws_eks_node_group.training,
    aws_eks_access_policy_association.codebuild_admin,
    null_resource.apply_host_eks_access,
    time_sleep.wait_for_apply_host_access,
    aws_codepipeline.lab2,
    aws_cloudwatch_event_rule.lab2_trigger,
    aws_cloudwatch_event_target.lab2_trigger,
  ]
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
    # Lab 2 (SAM deploy) buildspec expects ARTIFACT_BUCKET / STACK_NAME /
    # ENVIRONMENT. ARTIFACT_BUCKET reuses the CodePipeline artifact bucket --
    # SAM only needs a bucket to upload its packaged template + zipped fns,
    # and that bucket is already provisioned + region-correct + accessible
    # to this CodeBuild role.
    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = aws_s3_bucket.lab2_artifacts[0].bucket
    }
    environment_variable {
      name  = "STACK_NAME"
      value = "${local.name_prefix}-lab2-sam-app"
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

  # NOTE: previously this had `depends_on = [null_resource.<lab>_seed]` so
  # the pipeline was created only after the repo was populated. Reversed
  # for two reasons:
  #   1. The seed now depends on the pipeline (so its push triggers the
  #      already-existing pipeline cleanly), which would create a cycle.
  #   2. CodePipeline can be created against an unpopulated CodeCommit
  #      branch -- with PollForSourceChanges = false (above) it just
  #      sits idle until the EventBridge rule fires it.
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

  # The seed pushes lab fixture code to main, which fires the EventBridge
  # rule, which kicks off the per-student CodePipeline. The pipeline runs
  # CodeBuild, which runs `helm upgrade --install` (lab1) / `sam deploy`
  # (lab2) / `terraform plan + apply` (lab3, lab4) against AWS.
  #
  # That auto-trigger happens DURING `terraform apply`, not after. So we
  # must not seed (and thus trigger the pipeline) until every AWS resource
  # the pipeline's build needs is fully ready. Otherwise the first
  # pipeline run races the infrastructure and fails (e.g. lab1's helm
  # install hits an EKS API that isn't accepting traffic yet, or the
  # CodeBuild project's IAM permissions are mid-propagation).
  #
  # Concretely, the EKS-using labs (lab1) need: cluster + node group +
  # CodeBuild's access entry + the apply-host's access entry + the 45s
  # propagation sleep. The non-EKS labs (lab2 SAM, lab3 OPA, lab4 Aurora
  # CLI) still wait on these same gates -- harmless, and it keeps the
  # depends_on consistent across labs.
  depends_on = [
    aws_codecommit_repository.lab3,
    aws_codebuild_project.lab3,
    aws_eks_node_group.training,
    aws_eks_access_policy_association.codebuild_admin,
    null_resource.apply_host_eks_access,
    time_sleep.wait_for_apply_host_access,
    aws_codepipeline.lab3,
    aws_cloudwatch_event_rule.lab3_trigger,
    aws_cloudwatch_event_target.lab3_trigger,
  ]
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

  # NOTE: previously this had `depends_on = [null_resource.<lab>_seed]` so
  # the pipeline was created only after the repo was populated. Reversed
  # for two reasons:
  #   1. The seed now depends on the pipeline (so its push triggers the
  #      already-existing pipeline cleanly), which would create a cycle.
  #   2. CodePipeline can be created against an unpopulated CodeCommit
  #      branch -- with PollForSourceChanges = false (above) it just
  #      sits idle until the EventBridge rule fires it.
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

  # The seed pushes lab fixture code to main, which fires the EventBridge
  # rule, which kicks off the per-student CodePipeline. The pipeline runs
  # CodeBuild, which runs `helm upgrade --install` (lab1) / `sam deploy`
  # (lab2) / `terraform plan + apply` (lab3, lab4) against AWS.
  #
  # That auto-trigger happens DURING `terraform apply`, not after. So we
  # must not seed (and thus trigger the pipeline) until every AWS resource
  # the pipeline's build needs is fully ready. Otherwise the first
  # pipeline run races the infrastructure and fails (e.g. lab1's helm
  # install hits an EKS API that isn't accepting traffic yet, or the
  # CodeBuild project's IAM permissions are mid-propagation).
  #
  # Concretely, the EKS-using labs (lab1) need: cluster + node group +
  # CodeBuild's access entry + the apply-host's access entry + the 45s
  # propagation sleep. The non-EKS labs (lab2 SAM, lab3 OPA, lab4 Aurora
  # CLI) still wait on these same gates -- harmless, and it keeps the
  # depends_on consistent across labs.
  depends_on = [
    aws_codecommit_repository.lab4,
    aws_codebuild_project.lab4,
    aws_eks_node_group.training,
    aws_eks_access_policy_association.codebuild_admin,
    null_resource.apply_host_eks_access,
    time_sleep.wait_for_apply_host_access,
    aws_rds_cluster_instance.lab4_aurora_writer,
    aws_codepipeline.lab4,
    aws_cloudwatch_event_rule.lab4_trigger,
    aws_cloudwatch_event_target.lab4_trigger,
  ]
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
    # Terraform reads var.cluster_identifier via the TF_VAR_<name> convention.
    # We set both because the AWS CLI in the buildspec reads CLUSTER_ID and
    # Terraform reads TF_VAR_cluster_identifier — CodeBuild does not propagate
    # `export` between phases, so we declare both here to keep the buildspec
    # simple.
    environment_variable {
      name  = "TF_VAR_cluster_identifier"
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

  # NOTE: previously this had `depends_on = [null_resource.<lab>_seed]` so
  # the pipeline was created only after the repo was populated. Reversed
  # for two reasons:
  #   1. The seed now depends on the pipeline (so its push triggers the
  #      already-existing pipeline cleanly), which would create a cycle.
  #   2. CodePipeline can be created against an unpopulated CodeCommit
  #      branch -- with PollForSourceChanges = false (above) it just
  #      sits idle until the EventBridge rule fires it.
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



###############################################################################
# IO-107 SDLC Pipeline -- lab_env_student / outputs.tf
#
###############################################################################

output "student_id" {
  value       = var.student_id
  description = "Student identifier used to tag every resource."
}

output "aws_region" {
  value       = var.aws_region
  description = "Region everything was provisioned in."
}

output "eks_cluster_name" {
  value       = aws_eks_cluster.training.name
  description = "EKS cluster name."
}

output "eks_cluster_endpoint" {
  value       = aws_eks_cluster.training.endpoint
  description = "EKS API server endpoint."
}

output "eks_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.eks_irsa.arn
  description = "OIDC provider ARN for IRSA trust policies."
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.training.name} --region ${var.aws_region}"
  description = "Run this to put the cluster into your local kubeconfig."
}


output "ecr_repos" {
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
  description = "Map of ECR repo name → registry URL."
}

output "db_subnet_group_name" {
  value       = aws_db_subnet_group.training.name
  description = "Aurora DB subnet group."
}

output "db_security_group_id" {
  value       = aws_security_group.training_db.id
  description = "Aurora security group."
}


output "codebuild_service_role_arn" {
  value       = aws_iam_role.codebuild_service.arn
  description = "Shared CodeBuild execution role."
}

output "codepipeline_service_role_arn" {
  value       = aws_iam_role.codepipeline_service.arn
  description = "Shared CodePipeline service role."
}


output "lab1_pipeline_name" {
  value       = try(aws_codepipeline.lab1[0].name, "(disabled)")
  description = "lab1 CodePipeline name."
}

output "lab1_codebuild_project" {
  value       = try(aws_codebuild_project.lab1[0].name, "(disabled)")
  description = "lab1 CodeBuild project name."
}

output "lab1_artifact_bucket" {
  value       = try(aws_s3_bucket.lab1_artifacts[0].bucket, "(disabled)")
  description = "lab1 pipeline artifact bucket."
}

output "lab1_codecommit_clone_url" {
  value       = try(aws_codecommit_repository.lab1[0].clone_url_http, "(disabled)")
  description = "lab1 per-student CodeCommit clone URL (HTTPS). Students clone this in Task 1."
}

output "lab1_codecommit_repo_name" {
  value       = try(aws_codecommit_repository.lab1[0].repository_name, "(disabled)")
  description = "lab1 per-student CodeCommit repository name."
}

# Namespace name is a deterministic string -- helm creates it at deploy time
# via `--create-namespace`. We surface it as an output so the lab body can
# reference it as `$LABN_NAMESPACE` without depending on a Terraform
# kubernetes_namespace resource (that resource raced the helm install and
# was removed -- see main.tf for the rationale).
output "lab1_namespace" {
  value       = var.enable_lab1 ? "lab1-${local.effective_student_id}" : "(disabled)"
  description = "lab1 K8s namespace (created by helm at first pipeline run)."
}
output "lab1_myapp_dev_role_arn" {
  value       = try(aws_iam_role.lab1_myapp_dev_role[0].arn, "(disabled)")
  description = "lab1 IRSA role ARN for myapp-dev-role. Substitute into chart values-dev.yaml before push."
}
output "lab1_myapp_stg_role_arn" {
  value       = try(aws_iam_role.lab1_myapp_stg_role[0].arn, "(disabled)")
  description = "lab1 IRSA role ARN for myapp-stg-role. Substitute into chart values-dev.yaml before push."
}

# BONUS (gated by enable_lab1_prod_promotion). "(disabled)" unless the bonus is on.
output "lab1_prod_namespace" {
  value       = var.enable_lab1 && var.enable_lab1_prod_promotion ? "lab1-${local.effective_student_id}-prod" : "(disabled)"
  description = "lab1 production K8s namespace (bonus; created by helm at first prod promotion)."
}
output "lab1_myapp_prod_role_arn" {
  value       = try(aws_iam_role.lab1_myapp_prod_role[0].arn, "(disabled)")
  description = "lab1 IRSA role ARN for myapp-prod-role (bonus; only present when enable_lab1_prod_promotion = true)."
}

output "lab2_pipeline_name" {
  value       = try(aws_codepipeline.lab2[0].name, "(disabled)")
  description = "lab2 CodePipeline name."
}

output "lab2_codebuild_project" {
  value       = try(aws_codebuild_project.lab2[0].name, "(disabled)")
  description = "lab2 CodeBuild project name."
}

output "lab2_artifact_bucket" {
  value       = try(aws_s3_bucket.lab2_artifacts[0].bucket, "(disabled)")
  description = "lab2 pipeline artifact bucket."
}

output "lab2_codecommit_clone_url" {
  value       = try(aws_codecommit_repository.lab2[0].clone_url_http, "(disabled)")
  description = "lab2 per-student CodeCommit clone URL (HTTPS). Students clone this in Task 1."
}

output "lab2_codecommit_repo_name" {
  value       = try(aws_codecommit_repository.lab2[0].repository_name, "(disabled)")
  description = "lab2 per-student CodeCommit repository name."
}


output "lab3_pipeline_name" {
  value       = try(aws_codepipeline.lab3[0].name, "(disabled)")
  description = "lab3 CodePipeline name."
}

output "lab3_codebuild_project" {
  value       = try(aws_codebuild_project.lab3[0].name, "(disabled)")
  description = "lab3 CodeBuild project name."
}

output "lab3_artifact_bucket" {
  value       = try(aws_s3_bucket.lab3_artifacts[0].bucket, "(disabled)")
  description = "lab3 pipeline artifact bucket."
}

output "lab3_codecommit_clone_url" {
  value       = try(aws_codecommit_repository.lab3[0].clone_url_http, "(disabled)")
  description = "lab3 per-student CodeCommit clone URL (HTTPS). Students clone this in Task 1."
}

output "lab3_codecommit_repo_name" {
  value       = try(aws_codecommit_repository.lab3[0].repository_name, "(disabled)")
  description = "lab3 per-student CodeCommit repository name."
}


output "lab4_pipeline_name" {
  value       = try(aws_codepipeline.lab4[0].name, "(disabled)")
  description = "lab4 CodePipeline name."
}

output "lab4_codebuild_project" {
  value       = try(aws_codebuild_project.lab4[0].name, "(disabled)")
  description = "lab4 CodeBuild project name."
}

output "lab4_artifact_bucket" {
  value       = try(aws_s3_bucket.lab4_artifacts[0].bucket, "(disabled)")
  description = "lab4 pipeline artifact bucket."
}

output "lab4_codecommit_clone_url" {
  value       = try(aws_codecommit_repository.lab4[0].clone_url_http, "(disabled)")
  description = "lab4 per-student CodeCommit clone URL (HTTPS). Students clone this in Task 1."
}

output "lab4_codecommit_repo_name" {
  value       = try(aws_codecommit_repository.lab4[0].repository_name, "(disabled)")
  description = "lab4 per-student CodeCommit repository name."
}

output "lab4_aurora_cluster_id" {
  value       = try(aws_rds_cluster.lab4_aurora[0].id, "(disabled)")
  description = "lab4 Aurora cluster identifier."
}

output "lab4_aurora_endpoint" {
  value       = try(aws_rds_cluster.lab4_aurora[0].endpoint, "(disabled)")
  description = "lab4 Aurora writer endpoint."
}


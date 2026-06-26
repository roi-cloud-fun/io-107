###############################################################################
# IO-107 Lab 5 — outputs (the README references these)
###############################################################################

output "lab5_namespace" {
  value       = kubernetes_namespace.lab5.metadata[0].name
  description = "Kubernetes namespace Lab 5 deploys into."
}

output "lab5_ecr_repo_url" {
  value       = aws_ecr_repository.lab5.repository_url
  description = "ECR repo URL for the Lab 5 app image (docker build && push here)."
}

output "lab5_db_endpoint" {
  value       = aws_rds_cluster.aurora.endpoint
  description = "Aurora writer endpoint (set as the chart's db.host)."
}

output "lab5_db_secret_name" {
  value       = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
  description = "ARN of the Aurora-managed master-user secret (chart db.secretName)."
}

output "lab5_myapp_role_arn" {
  value       = aws_iam_role.myapp.arn
  description = "IRSA role ARN for the myapp ServiceAccount (chart serviceAccount.roleArn)."
}

output "lab5_region" {
  value       = var.aws_region
  description = "Region Lab 5 deployed into."
}

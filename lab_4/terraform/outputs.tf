###############################################################################
# IO-107 Lab 4 — outputs.tf
#
# These outputs are read by downstream Terraform consumers (the application's
# connection-string Secrets Manager entry, the read-replica monitoring stack,
# etc.). The cluster endpoint never changes across a Blue/Green switchover —
# that's the whole point — so consumers do not need to update on upgrade.
###############################################################################

output "cluster_endpoint" {
  description = "Writer endpoint for the training Aurora cluster. Stable across Blue/Green switchovers."
  value       = aws_rds_cluster.training.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint for the training Aurora cluster. Stable across Blue/Green switchovers."
  value       = aws_rds_cluster.training.reader_endpoint
}

output "port" {
  description = "Port the training Aurora cluster listens on."
  value       = aws_rds_cluster.training.port
}

output "cluster_resource_id" {
  description = "Immutable resource ID for the training Aurora cluster. Used in IAM policy resource ARNs."
  value       = aws_rds_cluster.training.cluster_resource_id
}

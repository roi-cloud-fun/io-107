###############################################################################
# IO-107 Lab 4 -- outputs.tf
#
# All outputs are sourced from the data.aws_rds_cluster.training data source
# (the cluster is owned + provisioned by lab_env_student/, not by this TF).
# The cluster endpoint is stable across Blue/Green switchovers -- that's the
# whole point -- so downstream consumers don't need to update on upgrade.
###############################################################################

output "cluster_endpoint" {
  description = "Writer endpoint for the training Aurora cluster. Stable across Blue/Green switchovers."
  value       = data.aws_rds_cluster.training.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint for the training Aurora cluster. Stable across Blue/Green switchovers."
  value       = data.aws_rds_cluster.training.reader_endpoint
}

output "port" {
  description = "Port the training Aurora cluster listens on."
  value       = data.aws_rds_cluster.training.port
}

output "engine_version_current" {
  description = "The engine version currently live on the cluster (post-switchover this matches local.target_engine_version)."
  value       = data.aws_rds_cluster.training.engine_version
}

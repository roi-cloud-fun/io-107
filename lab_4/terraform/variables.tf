###############################################################################
# IO-107 Lab 4 -- variables.tf
###############################################################################

variable "cluster_identifier" {
  description = "Identifier of the per-student Aurora cluster (provisioned by the bootstrap). The buildspec sets this via TF_VAR_cluster_identifier from the CLUSTER_ID env var."
  type        = string
}

###############################################################################
# IO-107 Lab 4 — variables.tf
#
# All five mandatory tag values are surfaced as variables so the terraform.tfvars
# at the pipeline level is the single source of values. The KMS key, DB subnet
# group, and VPC security group are owned by the platform team and looked up
# as data sources in aurora_cluster.tf.
###############################################################################

variable "environment" {
  description = "Mandatory Environment tag value. Expected: training, dev, stg, or prod."
  type        = string
  default     = "training"
}

variable "application" {
  description = "Mandatory Application tag value. Identifies the logical app the cluster serves."
  type        = string
  default     = "io107-lab"
}

variable "owner" {
  description = "Mandatory Owner tag value. Team email or distribution list."
  type        = string
  default     = "platform-team@client.com"
}

variable "cost_center" {
  description = "Mandatory CostCenter tag value. Used for chargeback reporting."
  type        = string
  default     = "CC-TRAINING"
}

variable "kms_key_arn" {
  description = "ARN of the platform-managed KMS key used for storage encryption on the training Aurora cluster."
  type        = string
}

variable "db_subnet_group_name" {
  description = "Name of the pre-provisioned DB subnet group for the training Aurora cluster."
  type        = string
}

variable "vpc_security_group_id" {
  description = "ID of the pre-provisioned VPC security group attached to the training Aurora cluster."
  type        = string
}

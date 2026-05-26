###############################################################################
# IO-107 SDLC Pipeline -- lab_env_student / variables.tf
#
###############################################################################

variable "aws_region" {
  description = "AWS region for the whole lab environment."
  type        = string
  default     = "us-east-1"
}

variable "student_id" {
  description = "Short identifier for the student running these labs (e.g. alice, ltf-smoketest). Used as a uniqueness suffix on every per-student resource. Must be lowercase, 1-16 chars, [a-z0-9-]."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,16}$", var.student_id))
    error_message = "student_id must be lowercase letters, digits, or dashes, 1-16 characters."
  }
}

variable "name_suffix" {
  description = <<-DESC
    Optional override for the per-apply uniqueness suffix appended to
    resource names. Leave empty (default) to use a random 6-char hex
    string generated once and persisted in Terraform state. Set this
    when you need reproducible names across teardown/rebuild cycles
    (e.g. LTF smoke tests that expect a fixed cluster name).
  DESC
  type        = string
  default     = ""

  validation {
    condition     = var.name_suffix == "" || can(regex("^[a-z0-9-]{1,12}$", var.name_suffix))
    error_message = "name_suffix must be empty or lowercase alphanumeric/dashes, 1-12 chars."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the lab VPC. Pick something that doesn't overlap with anything else in the account."
  type        = string
  default     = "10.20.0.0/16"
}

variable "eks_kubernetes_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.34"
}

variable "eks_node_instance_types" {
  description = "Instance types for the EKS managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "Desired worker node count."
  type        = number
  default     = 2
}


variable "enable_lab1" {
  description = "Provision per-lab resources for lab1."
  type        = bool
  default     = true
}

variable "enable_lab2" {
  description = "Provision per-lab resources for lab2."
  type        = bool
  default     = true
}

variable "enable_lab3" {
  description = "Provision per-lab resources for lab3."
  type        = bool
  default     = true
}

variable "enable_lab4" {
  description = "Provision per-lab resources for lab4."
  type        = bool
  default     = true
}


variable "apply_host_principal_arn" {
  description = <<-DESC
    IAM role/user ARN of the host running `terraform apply`. Granted EKS
    cluster admin via aws_eks_access_entry + AmazonEKSClusterAdminPolicy so
    Terraform's kubernetes provider can create the per-lab namespaces.

    Leave empty to auto-derive from the caller identity:
      - assumed-role ARN -> the underlying IAM role ARN
      - direct IAM user/role ARN -> passed through unchanged

    Override if the auto-derivation isn't right for your environment
    (e.g. federated identity, role chaining, or you want to grant a
    different principal than the one running apply).
  DESC
  type        = string
  default     = ""
}

# Note: in student mode the CodePipeline Source action reads from each lab's
# per-student CodeCommit repo (seeded once from the public monorepo at apply
# time). No GitHub CodeStar connection is needed -- the seed clone is from a
# public repo and the runtime source is CodeCommit. Split mode (multi-student
# delivery) is the path that still needs a CodeStar GitHub connection.

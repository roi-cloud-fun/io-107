###############################################################################
# IO-107 Lab 5 — input variables
###############################################################################

variable "student_id" {
  type        = string
  description = "Short lowercase student identifier (matches your main deploy)."

  validation {
    condition     = can(regex("^[a-z0-9-]{1,16}$", var.student_id))
    error_message = "student_id must be 1-16 chars of lowercase letters, digits, or dashes."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region (must match where your main lab environment is deployed)."
  # No default on purpose. This must match the region your lab_env_student
  # deploy lives in, and there is no safe guess: defaulting to us-east-1 meant a
  # student outside us-east-1 who forgot this line silently got a provider
  # pointed at the wrong region, while main_remote_state still read their real
  # state -- a confusing cross-region failure. Terraform now asks (or errors
  # under -input=false) instead of guessing.
}

variable "main_remote_state" {
  type        = map(string)
  description = <<-EOT
    S3 backend config of your lab_env_student state, so Lab 5 can read its
    outputs read-only. Keys: bucket, key, region. Example:
      {
        bucket = "io107-<your-id>-tfstate-<account>"
        key    = "lab_env_student/<your-id>.tfstate"
        region = "<your-region>"
      }
  EOT
}

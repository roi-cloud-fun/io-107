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
  default     = "us-east-1"
}

variable "main_remote_state" {
  type        = map(string)
  description = <<-EOT
    S3 backend config of your lab_env_student state, so Lab 5 can read its
    outputs read-only. Keys: bucket, key, region. Example:
      {
        bucket = "io107-<your-id>-tfstate-<account>"
        key    = "lab_env_student/<your-id>.tfstate"
        region = "us-east-1"
      }
  EOT
}

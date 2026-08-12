variable "aws_region" {
  type        = string
  description = "Region to build workstations in. Must match the region the students' lab environments are in — apply this module once per region."
  # No default: the cohort is split across regions and a wrong guess here puts a
  # student's workstation in a different region from their cluster.
}

variable "students" {
  type        = list(string)
  description = "Student ids to build a workstation for, e.g. [\"user01\",\"user02\"]. Use the SAME ids as their lab environments."
}

variable "instance_type" {
  type        = string
  description = "Workstation size. t3.medium matches what STUDENT_SETUP.md asks students to launch by hand."
  default     = "t3.medium"
}

variable "root_volume_gb" {
  type        = number
  description = "Root disk. 30 GiB, not the 8 GiB default — Docker images plus the toolchain fill 8 GiB during Lab 3."
  default     = 30
}

variable "instance_profile" {
  type        = string
  description = "Instance profile granting Terraform/AWS access from the box. Must already exist."
  default     = "Terraform-InstanceRole"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names and tags."
  default     = "io107"
}

variable "monorepo_url" {
  type        = string
  description = "Course repo pre-cloned onto each workstation."
  default     = "https://github.com/roi-cloud-fun/io-107.git"
}

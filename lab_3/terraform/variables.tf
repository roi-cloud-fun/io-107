variable "environment" {
  description = "Deployment environment (dev | stg | prd)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be one of: dev, stg, prd."
  }
}

variable "application" {
  description = "Application short-name slug used in resource naming and tagging."
  type        = string
  default     = "lab3"
}

variable "owner" {
  description = "Owning team contact (email or distribution list)."
  type        = string
  default     = "training@client.com"
}

variable "cost_center" {
  description = "Finance cost-centre code for chargeback."
  type        = string
  default     = "CC-TRAINING"
}

variable "data_class" {
  description = "Data classification for resources that store or process data."
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["public", "internal", "confidential", "restricted"], var.data_class)
    error_message = "data_class must be one of: public, internal, confidential, restricted."
  }
}

# variables.tf -- input declarations (actual values live in terraform.tfvars)
variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Short suffix that keeps resource names unique. Lowercase."
  type        = string
}

variable "operator_object_id" {
  description = "Entra object ID of the user to grant VM-restart access."
  type        = string
}

variable "alert_email" {
  description = "Email address that receives the budget alert."
  type        = string
}

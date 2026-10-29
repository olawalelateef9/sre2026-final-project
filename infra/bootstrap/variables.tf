variable "region" {
  description = "AWS region for all project resources."
  type        = string
  default     = "eu-west-2"
}

variable "alert_email" {
  description = "Email address that receives budget alerts. Set in terraform.tfvars (git-ignored)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly spend that triggers alerts at 50%, 80% and 100% (actual) and 100% (forecast)."
  type        = number
  default     = 20
}

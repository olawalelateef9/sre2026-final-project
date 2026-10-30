variable "datadog_site" {
  description = "Datadog site of the account, e.g. datadoghq.eu (scripts/datadog.sh passes DD_SITE)."
  type        = string
  default     = "datadoghq.eu"
}

variable "region" {
  description = "AWS region of the deployment."
  type        = string
  default     = "eu-west-2"
}

variable "notify_email" {
  description = "Email address that receives Datadog alerts. Set in terraform.tfvars (git-ignored)."
  type        = string
}

variable "datadog_aws_account_id" {
  description = "Datadog's AWS account that assumes the integration role (commercial sites)."
  type        = string
  default     = "464622532012"
}

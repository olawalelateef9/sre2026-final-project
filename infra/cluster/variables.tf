variable "region" {
  description = "AWS region; must match the bootstrap stack."
  type        = string
  default     = "eu-west-2"
}

variable "name" {
  description = "Name prefix for the cluster and its resources."
  type        = string
  default     = "techbleat"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version (standard support only). 1.36 because Istio 1.30, the newest release with published Helm charts, supports Kubernetes up to 1.36."
  type        = string
  default     = "1.36"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. scripts/up.sh sets this to the operator's current IP /32."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "admin_cidrs must list specific operator addresses, never 0.0.0.0/0."
  }
}

variable "node_instance_types" {
  description = "Instance types for the Spot node group; several types improve Spot availability."
  type        = list(string)
  default     = ["t3.large", "t3a.large", "m5.large", "m6i.large"]
}

variable "node_capacity_type" {
  description = "SPOT for cost (sandbox) or ON_DEMAND for stability."
  type        = string
  default     = "SPOT"
}

variable "node_count" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

# Datadog configuration as code: AWS integration, monitors, SLO and dashboard.
#
# Persistent (Datadog objects cost nothing while the environment is down); applied with
# scripts/datadog.sh. Datadog keys come from the operator's environment (DD_API_KEY,
# DD_APP_KEY); the alert email address from the git-ignored terraform.tfvars.
#
# Monitors do not notify on missing data, so the routine teardown between sessions does
# not page anyone.

provider "datadog" {
  api_url = "https://api.${var.datadog_site}/"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "techbleat-global-bank"
      Stack     = "datadog"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  runbook = "https://github.com/olawalelateef9/sre2026-final-project/blob/main/docs/runbook.md"
  notify  = "@${var.notify_email}"
  tags    = ["env:sandbox", "project:techbleat-global-bank", "managed-by:terraform"]

  # The gateway's view of every public request (Istio standard metrics).
  gateway_requests = "istio.mesh.request.count{reporter:source,source_workload:public-istio}"
  gateway_errors   = "istio.mesh.request.count{reporter:source,source_workload:public-istio,response_code:5*}"
}

# ---- AWS integration: CloudWatch metrics for the managed data services and Keycloak ------
# Read-only role that Datadog's AWS account assumes with an external ID (protects against
# the confused-deputy problem). Limited to the namespaces this system uses.

resource "datadog_integration_aws_external_id" "this" {}

data "aws_iam_policy_document" "datadog_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.datadog_aws_account_id}:root"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [datadog_integration_aws_external_id.this.id]
    }
  }
}

resource "aws_iam_role" "datadog" {
  name               = "techbleat-datadog-integration"
  assume_role_policy = data.aws_iam_policy_document.datadog_trust.json
}

data "aws_iam_policy_document" "datadog_read" {
  statement {
    sid    = "ReadMetricsForUsedServices"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "tag:GetResources",
      "rds:DescribeDBInstances",
      "rds:ListTagsForResource",
      "elasticache:DescribeCacheClusters",
      "elasticache:DescribeReplicationGroups",
      "elasticache:ListTagsForResource",
      "ecs:DescribeClusters",
      "ecs:DescribeServices",
      "ecs:ListClusters",
      "ecs:ListServices",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "datadog_read" {
  name   = "read-metrics"
  role   = aws_iam_role.datadog.id
  policy = data.aws_iam_policy_document.datadog_read.json
}

resource "datadog_integration_aws_account" "this" {
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_partition  = "aws"
  account_tags   = local.tags

  auth_config {
    aws_auth_config_role {
      role_name   = aws_iam_role.datadog.name
      external_id = datadog_integration_aws_external_id.this.id
    }
  }

  aws_regions {
    include_only = [var.region]
  }

  metrics_config {
    namespace_filters {
      include_only = ["AWS/RDS", "AWS/ElastiCache", "AWS/ECS", "AWS/NetworkELB"]
    }
  }

  resources_config {
    cloud_security_posture_management_collection = false
    extended_collection                          = false
  }

  logs_config {
    lambda_forwarder {}
  }

  traces_config {
    xray_services {}
  }

  depends_on = [aws_iam_role_policy.datadog_read]
}

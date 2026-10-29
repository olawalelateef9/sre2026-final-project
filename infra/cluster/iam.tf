# IAM for in-cluster controllers, granted through EKS Pod Identity: each role is bound
# to exactly one Kubernetes service account in one namespace.

data "aws_caller_identity" "current" {}

# ---- External Secrets Operator: read-only on techbleat/cluster/* -------------------------

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid     = "ReadClusterSecretsOnly"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_prefix}/*",
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-cluster-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

# ---- AWS Load Balancer Controller: official policy for the installed version ------------

resource "aws_iam_role" "lb_controller" {
  name               = "${var.name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_policy" "lb_controller" {
  name        = "${var.name}-aws-load-balancer-controller"
  description = "kubernetes-sigs/aws-load-balancer-controller v3.6.2 docs/install/iam_policy.json"
  policy      = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}

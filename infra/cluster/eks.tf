module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # API reachable privately from the VPC, and publicly only from the operator's IP.
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs

  # Access entries only (no aws-auth ConfigMap); the identity running Terraform is admin.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Kubernetes Secrets are envelope-encrypted with a KMS key created by the module.
  kms_key_deletion_window_in_days = 7

  # Control-plane audit trail for security evidence; short retention keeps cost low.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  # Sandbox: allow `down` to delete the cluster.
  deletion_protection = false

  addons = {
    vpc-cni = {
      before_compute = true
      # Enforce Kubernetes NetworkPolicies with the VPC CNI's eBPF policy agent.
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = 1
      max_size     = var.node_count + 1
      desired_size = var.node_count

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
}

# ---- EBS CSI driver (persistent volumes for Kafka) via EKS Pod Identity ------------------

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

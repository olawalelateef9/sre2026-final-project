data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Two AZs, private subnets for nodes and data services, public subnets only for the
# NAT gateway and the ingress load balancer. One NAT gateway keeps sandbox cost down
# (documented: an AZ outage would cut egress until the other AZ gets its own).
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = "${var.name}-vpc"
  cidr = "10.40.0.0/16"
  azs  = local.azs

  private_subnets = ["10.40.0.0/20", "10.40.16.0/20"]
  public_subnets  = ["10.40.128.0/24", "10.40.129.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nothing is placed in the default security group; it denies all traffic.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

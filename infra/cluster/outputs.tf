output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Subnets for the internet-facing ingress load balancer."
  value       = module.vpc.public_subnets
}

output "ingress_public_ip" {
  description = "Static IP of the ingress load balancer; scripts/up.sh points DuckDNS at it."
  value       = aws_eip.ingress.public_ip
}

output "ingress_eip_allocation_id" {
  value = aws_eip.ingress.allocation_id
}

output "ingress_subnet_id" {
  description = "Public subnet whose AZ the Elastic IP is attached in."
  value       = module.vpc.public_subnets[0]
}

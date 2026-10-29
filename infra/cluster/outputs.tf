output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "postgres_endpoint" {
  description = "Private RDS endpoint (TLS required)."
  value       = aws_db_instance.postgres.address
}

output "valkey_endpoint" {
  description = "Private ElastiCache primary endpoint (TLS and AUTH required)."
  value       = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "secret_prefix" {
  description = "Secrets Manager prefix readable by External Secrets."
  value       = local.secret_prefix
}

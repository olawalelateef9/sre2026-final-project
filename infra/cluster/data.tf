# Managed data services and the credentials the cluster reads from Secrets Manager.
#
# Every secret the cluster may read is under techbleat/cluster/*; the External Secrets
# role is limited to that prefix. Secrets are force-deleted on destroy (no recovery
# window) so the next `up` can recreate them. Generated values also live in the
# Terraform state, which is encrypted and private in the bootstrap S3 bucket.

locals {
  secret_prefix = "techbleat/cluster"

  # One least-privilege database role per service; grants are applied by the db-init Job.
  # Keycloak has its own database instance (identity.tf).
  db_roles = ["user_service", "transaction_service", "activity_service"]
}

# ---- Passwords --------------------------------------------------------------------------

resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "random_password" "db_role" {
  for_each = toset(local.db_roles)
  length   = 32
  special  = false
}

resource "random_password" "valkey_auth" {
  length  = 48
  special = false
}

resource "random_password" "keycloak_provisioner" {
  length  = 48
  special = false
}

# ---- PostgreSQL (RDS) -------------------------------------------------------------------

resource "aws_security_group" "postgres" {
  name        = "${var.name}-postgres"
  description = "PostgreSQL reachable only from EKS nodes (pods use the node security group)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_db_subnet_group" "postgres" {
  name       = "${var.name}-postgres"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_parameter_group" "postgres" {
  name   = "${var.name}-postgres17"
  family = "postgres17"

  # Reject unencrypted client connections. Static parameter: applied when the instance is
  # created with this group (AWS records it as pending-reboot).
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.name}-postgres"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "bankingdb"
  username = "bankadmin"
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false
  multi_az               = false

  auto_minor_version_upgrade = true
  backup_retention_period    = 1
  copy_tags_to_snapshot      = true

  # Ephemeral sandbox: data does not outlive the session (see Phase 4 for backup/restore).
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true
}

# ---- Valkey (ElastiCache) ---------------------------------------------------------------

resource "aws_security_group" "valkey" {
  name        = "${var.name}-valkey"
  description = "Valkey reachable only from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Valkey from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_elasticache_subnet_group" "valkey" {
  name       = "${var.name}-valkey"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "${var.name}-valkey"
  description          = "Balance cache for the transaction service"
  engine               = "valkey"
  engine_version       = "9.1"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.valkey.name
  security_group_ids = [aws_security_group.valkey.id]

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.valkey_auth.result

  automatic_failover_enabled = false
  snapshot_retention_limit   = 0
  apply_immediately          = true
}

# ---- Secrets for the cluster ------------------------------------------------------------

locals {
  cluster_secrets = merge(
    {
      for role in local.db_roles : "db/${role}" => {
        host     = aws_db_instance.postgres.address
        port     = tostring(aws_db_instance.postgres.port)
        dbname   = "bankingdb"
        username = role
        password = random_password.db_role[role].result
      }
    },
    {
      "db/master" = {
        host     = aws_db_instance.postgres.address
        port     = tostring(aws_db_instance.postgres.port)
        dbname   = "bankingdb"
        username = aws_db_instance.postgres.username
        password = random_password.db_master.result
      }
      "valkey" = {
        host       = aws_elasticache_replication_group.valkey.primary_endpoint_address
        port       = "6379"
        auth_token = random_password.valkey_auth.result
      }
      # Public certificate of the identity platform's private CA, so in-cluster callers
      # can verify Keycloak's TLS. The CA key never leaves Terraform state.
      "keycloak/ca" = {
        ca_crt = tls_self_signed_cert.identity_ca.cert_pem
      }
      "keycloak/provisioner" = {
        client_secret = random_password.keycloak_provisioner.result
      }
    }
  )
}

resource "aws_secretsmanager_secret" "cluster" {
  for_each                = local.cluster_secrets
  name                    = "${local.secret_prefix}/${each.key}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "cluster" {
  for_each      = local.cluster_secrets
  secret_id     = aws_secretsmanager_secret.cluster[each.key].id
  secret_string = jsonencode(each.value)
}

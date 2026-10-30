# Identity platform: Keycloak on ECS Fargate, outside the EKS cluster (as in the target
# architecture). Its own security boundary:
#   - compute: a separate ECS cluster in private subnets with its own security group
#   - data: a dedicated RDS instance reachable only from the Keycloak tasks
#   - secrets: techbleat/identity/*, readable only by the Keycloak task execution role
#     (the EKS cluster's External Secrets role cannot read them)
#   - transport: HTTPS only, with a private CA created here; callers verify it
#   - operator access: SSM port forwarding (ECS Exec), audited in CloudTrail
# Browsers still reach the banking realm through the shared edge (NLB, WAF, TLS) at
# auth.<domain>; the admin console is never routed publicly.

locals {
  identity_prefix   = "techbleat/identity"
  identity_dns      = "identity.internal"
  keycloak_hostname = "keycloak.${local.identity_dns}"
  public_domain     = "techbleatglobalbank.duckdns.org"
  keycloak_image    = "quay.io/keycloak/keycloak:26.8.1@sha256:a78d6b79572168cb25886b80a8b5b8d4ed4390743e3eecb810538683e209dd6b"
}

# ---- Private CA and Keycloak server certificate -----------------------------------------

resource "tls_private_key" "identity_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "identity_ca" {
  private_key_pem       = tls_private_key.identity_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 8760
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject {
    common_name  = "Techbleat identity internal CA"
    organization = "Techbleat Global Bank"
  }
}

resource "tls_private_key" "keycloak" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "keycloak" {
  private_key_pem = tls_private_key.keycloak.private_key_pem
  # localhost: operators reach Keycloak through an SSM port forward.
  dns_names = [local.keycloak_hostname, "localhost"]
  subject {
    common_name  = local.keycloak_hostname
    organization = "Techbleat Global Bank"
  }
}

resource "tls_locally_signed_cert" "keycloak" {
  cert_request_pem      = tls_cert_request.keycloak.cert_request_pem
  ca_private_key_pem    = tls_private_key.identity_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.identity_ca.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

# ---- Secrets (identity prefix: not readable from EKS) -------------------------------------

resource "random_password" "identity_db" {
  length  = 32
  special = false
}

resource "random_password" "identity_admin" {
  length  = 32
  special = false
}

locals {
  identity_secrets = {
    "admin" = { username = "admin", password = random_password.identity_admin.result }
    "db"    = { password = random_password.identity_db.result }
    "tls" = {
      cert = tls_locally_signed_cert.keycloak.cert_pem
      key  = tls_private_key.keycloak.private_key_pem
    }
  }
}

resource "aws_secretsmanager_secret" "identity" {
  for_each                = local.identity_secrets
  name                    = "${local.identity_prefix}/${each.key}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "identity" {
  for_each      = local.identity_secrets
  secret_id     = aws_secretsmanager_secret.identity[each.key].id
  secret_string = jsonencode(each.value)
}

# ---- Network ------------------------------------------------------------------------------

resource "aws_security_group" "keycloak" {
  name        = "${var.name}-keycloak"
  description = "Keycloak tasks: HTTPS from EKS nodes (gateway and user-service) only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Keycloak HTTPS from EKS nodes"
    from_port       = 8443
    to_port         = 8443
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    description = "Database, container registry, AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_service_discovery_private_dns_namespace" "identity" {
  name        = local.identity_dns
  description = "Private DNS for the identity platform"
  vpc         = module.vpc.vpc_id
}

resource "aws_service_discovery_service" "keycloak" {
  name = "keycloak"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.identity.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# ---- Dedicated database --------------------------------------------------------------------

resource "aws_security_group" "identity_db" {
  name        = "${var.name}-identity-db"
  description = "Identity database: PostgreSQL from Keycloak tasks only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from Keycloak"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.keycloak.id]
  }
}

resource "aws_db_instance" "identity" {
  identifier     = "${var.name}-identity-postgres"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "keycloak"
  username = "keycloak"
  password = random_password.identity_db.result

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.identity_db.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false
  multi_az               = false

  auto_minor_version_upgrade = true
  backup_retention_period    = 1
  copy_tags_to_snapshot      = true
  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true
}

# ---- IAM ----------------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Pulls the image, writes logs and injects the identity secrets at task start.
resource "aws_iam_role" "keycloak_execution" {
  name               = "${var.name}-keycloak-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "keycloak_execution" {
  role       = aws_iam_role.keycloak_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "keycloak_execution_secrets" {
  statement {
    sid       = "ReadIdentitySecretsOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for secret in aws_secretsmanager_secret.identity : secret.arn]
  }
}

resource "aws_iam_role_policy" "keycloak_execution_secrets" {
  name   = "read-identity-secrets"
  role   = aws_iam_role.keycloak_execution.id
  policy = data.aws_iam_policy_document.keycloak_execution_secrets.json
}

# The running task itself only needs the SSM channel used for operator port forwarding.
resource "aws_iam_role" "keycloak_task" {
  name               = "${var.name}-keycloak-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "keycloak_task_exec" {
  statement {
    sid    = "EcsExecChannel"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "keycloak_task_exec" {
  name   = "ecs-exec-channel"
  role   = aws_iam_role.keycloak_task.id
  policy = data.aws_iam_policy_document.keycloak_task_exec.json
}

# ---- ECS ----------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "keycloak" {
  name              = "/ecs/${var.name}-identity/keycloak"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "identity" {
  name = "${var.name}-identity"
}

locals {
  # The TLS certificate arrives as environment variables (ECS secrets) and is written to
  # files before Keycloak starts. The management interface (health) stays plain HTTP on
  # 9000, which the security group does not expose.
  keycloak_start = <<-EOT
    set -euo pipefail
    mkdir -p /tmp/tls
    printf '%s' "$TLS_CERT" > /tmp/tls/tls.crt
    printf '%s' "$TLS_KEY" > /tmp/tls/tls.key
    unset TLS_CERT TLS_KEY
    exec /opt/keycloak/bin/kc.sh start
  EOT

  keycloak_healthcheck = "exec 3<>/dev/tcp/127.0.0.1/9000 && printf 'GET /health/ready HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q '\"UP\"' <&3"
}

resource "aws_ecs_task_definition" "keycloak" {
  family                   = "${var.name}-keycloak"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.keycloak_execution.arn
  task_role_arn            = aws_iam_role.keycloak_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name       = "keycloak"
      image      = local.keycloak_image
      essential  = true
      user       = "1000"
      entryPoint = ["/bin/bash", "-c"]
      command    = [local.keycloak_start]
      portMappings = [
        { containerPort = 8443, protocol = "tcp" }
      ]
      environment = [
        { name = "KC_DB", value = "postgres" },
        { name = "KC_DB_URL", value = "jdbc:postgresql://${aws_db_instance.identity.address}:5432/keycloak?sslmode=require" },
        { name = "KC_DB_USERNAME", value = "keycloak" },
        { name = "KC_HOSTNAME", value = "https://auth.${local.public_domain}" },
        { name = "KC_HOSTNAME_BACKCHANNEL_DYNAMIC", value = "true" },
        { name = "KC_HTTP_ENABLED", value = "false" },
        { name = "KC_HTTPS_PORT", value = "8443" },
        { name = "KC_HTTPS_CERTIFICATE_FILE", value = "/tmp/tls/tls.crt" },
        { name = "KC_HTTPS_CERTIFICATE_KEY_FILE", value = "/tmp/tls/tls.key" },
        { name = "KC_HTTP_MANAGEMENT_SCHEME", value = "http" },
        { name = "KC_HEALTH_ENABLED", value = "true" },
        # Forwarded headers are honoured only from inside the VPC (the gateway).
        { name = "KC_PROXY_HEADERS", value = "xforwarded" },
        { name = "KC_PROXY_TRUSTED_ADDRESSES", value = module.vpc.vpc_cidr_block },
        { name = "KC_CACHE", value = "local" },
        { name = "JAVA_OPTS_KC_HEAP", value = "-XX:MaxRAMPercentage=70" },
      ]
      secrets = [
        { name = "KC_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.identity["db"].arn}:password::" },
        { name = "KC_BOOTSTRAP_ADMIN_USERNAME", valueFrom = "${aws_secretsmanager_secret.identity["admin"].arn}:username::" },
        { name = "KC_BOOTSTRAP_ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.identity["admin"].arn}:password::" },
        { name = "TLS_CERT", valueFrom = "${aws_secretsmanager_secret.identity["tls"].arn}:cert::" },
        { name = "TLS_KEY", valueFrom = "${aws_secretsmanager_secret.identity["tls"].arn}:key::" },
      ]
      healthCheck = {
        command     = ["CMD", "bash", "-c", local.keycloak_healthcheck]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 180
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.keycloak.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "keycloak"
        }
      }
    }
  ])

  depends_on = [aws_secretsmanager_secret_version.identity]
}

resource "aws_ecs_service" "keycloak" {
  name                   = "keycloak"
  cluster                = aws_ecs_cluster.identity.id
  task_definition        = aws_ecs_task_definition.keycloak.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.keycloak.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.keycloak.arn
  }

  depends_on = [aws_iam_role_policy.keycloak_execution_secrets]
}

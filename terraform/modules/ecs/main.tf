# ECS module without ECR - ECR has been moved to another repository

# Local variables
locals {
  # Compute Kong Data Plane S3 bucket name
  kong_fallback_bucket_name = var.kong_fallback_s3_bucket_name != "" ? var.kong_fallback_s3_bucket_name : "${var.project_name}-${var.environment}-kong-config-fallback"

  # Compute Kong Data Plane environment variables
  kong_dp_base_env = [
    {
      name  = "KONG_ROLE"
      value = "data_plane"
    },
    {
      name  = "KONG_DATABASE"
      value = "off"
    },
    {
      name  = "KONG_CLUSTER_CONTROL_PLANE"
      value = "kong-cp.${aws_service_discovery_private_dns_namespace.service_discovery.name}:8005"
    },
    {
      name  = "KONG_CLUSTER_TELEMETRY_ENDPOINT"
      value = "kong-cp.${aws_service_discovery_private_dns_namespace.service_discovery.name}:8006"
    },
    {
      name  = "KONG_CLUSTER_MTLS"
      value = "shared"
    },
    {
      name  = "KONG_CLUSTER_DP_LABELS"
      value = "type:ecs-fargate,env:${var.environment}"
    },
    {
      name  = "KONG_STATUS_LISTEN"
      value = "0.0.0.0:8100"
    },
    {
      name  = "KONG_PROXY_ACCESS_LOG"
      value = "/dev/stdout"
    },
    {
      name  = "KONG_PROXY_ERROR_LOG"
      value = "/dev/stderr"
    }
  ]

  kong_dp_resilience_env = var.kong_cp_outage_resilience_enabled ? [
    {
      name  = "AWS_REGION"
      value = var.region
    },
    {
      name  = "KONG_CLUSTER_FALLBACK_CONFIG_EXPORT"
      value = "on"
    },
    {
      name  = "KONG_CLUSTER_FALLBACK_CONFIG_IMPORT"
      value = "on"
    },
    {
      name  = "KONG_CLUSTER_FALLBACK_CONFIG_STORAGE"
      value = "s3://${local.kong_fallback_bucket_name}/${var.kong_fallback_s3_prefix}"
    }
  ] : []

  kong_dp_environment = concat(local.kong_dp_base_env, local.kong_dp_resilience_env)
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-cluster"
  }
}

# ECS Task Execution Role
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.project_name}-${var.environment}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-execution-role"
  }
}

# Attach the AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}



# ECS Task Role
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.project_name}-${var.environment}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-task-role"
  }
}

# Create a policy for CloudWatch Logs
resource "aws_iam_policy" "task_logs_policy" {
  name        = "${var.project_name}-${var.environment}-task-logs-policy"
  description = "Allow ECS tasks to send logs to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}



# Attach CloudWatch logs policy to task role
resource "aws_iam_role_policy_attachment" "task_logs" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.task_logs_policy.arn
}



# Create a policy for ECS Exec
resource "aws_iam_policy" "ecs_exec_policy" {
  name        = "${var.project_name}-${var.environment}-ecs-exec-policy"
  description = "Allow ECS Exec for task debugging"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach ECS Exec policy to task role
resource "aws_iam_role_policy_attachment" "task_ecs_exec" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.ecs_exec_policy.arn
}

# IAM policy for Kong cluster certificates access
resource "aws_iam_policy" "kong_secrets_policy" {
  count       = var.kong_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-kong-secrets-policy"
  description = "Allow ECS tasks to read Kong cluster certificates"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.kong_cluster_cert[0].arn,
          aws_secretsmanager_secret.kong_cluster_key[0].arn
        ]
      }
    ]
  })
}

# Attach Kong secrets policy to execution role
resource "aws_iam_role_policy_attachment" "execution_kong_secrets" {
  count      = var.kong_enabled ? 1 : 0
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.kong_secrets_policy[0].arn
}

# Create a policy for database secrets access (for PostgreSQL)
resource "aws_iam_policy" "db_secrets_policy" {
  count       = var.kong_db_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-db-secrets-policy"
  description = "Allow ECS tasks to read database secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.kong_db_password[0].arn
        ]
      }
    ]
  })
}

# Attach database secrets policy to execution role
resource "aws_iam_role_policy_attachment" "execution_db_secrets" {
  count      = var.kong_db_enabled ? 1 : 0
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.db_secrets_policy[0].arn
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-${var.environment}-logs"
  }
}

# AWS Cloud Map Private DNS Namespace for service discovery
resource "aws_service_discovery_private_dns_namespace" "service_discovery" {
  name        = "${var.project_name}.${var.environment}.local"
  description = "Service discovery namespace for ${var.project_name} in ${var.environment}"
  vpc         = var.vpc_id

  tags = {
    Name = "${var.project_name}-${var.environment}-dns-namespace"
  }
}

# AWS Cloud Map Service for hello-service discovery
resource "aws_service_discovery_service" "hello_service" {
  name = var.project_name

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.service_discovery.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-hello-discovery-service"
  }
}

# AWS Cloud Map Service for Kong Gateway service discovery
resource "aws_service_discovery_service" "kong_gateway" {
  count = var.kong_enabled ? 1 : 0
  name  = "kong-gateway"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.service_discovery.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-discovery-service"
  }
}



# ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-${var.environment}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-${var.environment}-container"
      image     = var.container_image_url
      cpu       = var.task_cpu
      memory    = var.task_memory
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/actuator/health || exit 1"]
        interval    = 30
        retries     = 3
        timeout     = 5
        startPeriod = 60
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-${var.environment}-task"
  }
}

# CloudWatch Log Group for Kong Gateway
resource "aws_cloudwatch_log_group" "kong_app" {
  count             = var.kong_enabled ? 1 : 0
  name              = "/ecs/${var.project_name}-${var.environment}-kong"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-logs"
  }
}

# CloudWatch Log Group for PostgreSQL (only if using ECS, not RDS)
resource "aws_cloudwatch_log_group" "postgres" {
  count             = var.kong_db_enabled && !var.kong_db_use_rds ? 1 : 0
  name              = "/ecs/${var.project_name}-${var.environment}-postgres"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-${var.environment}-postgres-logs"
  }
}

# AWS Secrets Manager secret for Kong database password
resource "aws_secretsmanager_secret" "kong_db_password" {
  count                   = var.kong_db_enabled ? 1 : 0
  name                    = "${var.project_name}-${var.environment}-kong-db-password"
  description             = "Kong database password"
  recovery_window_in_days = 0 # Force immediate deletion

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-db-password"
  }
}

resource "aws_secretsmanager_secret_version" "kong_db_password" {
  count         = var.kong_db_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.kong_db_password[0].id
  secret_string = var.kong_db_password != "" ? var.kong_db_password : "kong_password_change_me"
}

# PostgreSQL ECS Task Definition (only if not using RDS)
resource "aws_ecs_task_definition" "postgres" {
  count                    = var.kong_db_enabled && !var.kong_db_use_rds ? 1 : 0
  family                   = "${var.project_name}-${var.environment}-postgres-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-${var.environment}-postgres-container"
      image     = "postgres:13-alpine"
      cpu       = 512
      memory    = 1024
      essential = true
      portMappings = [
        {
          containerPort = 5432
          hostPort      = 5432
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.postgres[0].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "postgres"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "pg_isready -U ${var.kong_db_user} -d ${var.kong_db_name}"]
        interval    = 30
        retries     = 3
        timeout     = 5
        startPeriod = 60
      }
      environment = [
        {
          name  = "POSTGRES_DB"
          value = var.kong_db_name
        },
        {
          name  = "POSTGRES_USER"
          value = var.kong_db_user
        }
      ]
      secrets = [
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = aws_secretsmanager_secret.kong_db_password[0].arn
        }
      ]
    }
  ])

  tags = {
    Name = "${var.project_name}-${var.environment}-postgres-task"
  }
}

# AWS Cloud Map Service for PostgreSQL service discovery (only if using ECS)
resource "aws_service_discovery_service" "postgres" {
  count = var.kong_db_enabled && !var.kong_db_use_rds ? 1 : 0
  name  = "postgres"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.service_discovery.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-postgres-discovery-service"
  }
}

# PostgreSQL ECS Service (only if not using RDS)
resource "aws_ecs_service" "postgres" {
  count                              = var.kong_db_enabled && !var.kong_db_use_rds ? 1 : 0
  name                               = "${var.project_name}-${var.environment}-postgres-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.postgres[0].arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  enable_execute_command             = true

  network_configuration {
    security_groups  = [var.database_sg_id != "" ? var.database_sg_id : var.application_sg_id]
    subnets          = var.private_subnets
    assign_public_ip = false
  }

  # Register service in Cloud Map for service discovery
  service_registries {
    registry_arn = aws_service_discovery_service.postgres[0].arn
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-postgres-service"
  }
}

# CloudWatch Log Group for Kong Control Plane
resource "aws_cloudwatch_log_group" "kong_cp" {
  count             = var.kong_control_plane_enabled ? 1 : 0
  name              = "/ecs/${var.project_name}-${var.environment}-kong-cp"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-cp-logs"
  }
}

# Kong Control Plane ECS Task Definition
resource "aws_ecs_task_definition" "kong_cp" {
  count                    = var.kong_control_plane_enabled ? 1 : 0
  family                   = "${var.project_name}-${var.environment}-kong-cp-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-${var.environment}-kong-cp-container"
      image     = "kong:3.9.1"
      cpu       = 1024
      memory    = 2048
      essential = true
      portMappings = [
        {
          containerPort = 8001
          hostPort      = 8001
          protocol      = "tcp"
        },
        {
          containerPort = 8002
          hostPort      = 8002
          protocol      = "tcp"
        },
        {
          containerPort = 8444
          hostPort      = 8444
          protocol      = "tcp"
        },
        {
          containerPort = 8005
          hostPort      = 8005
          protocol      = "tcp"
        },
        {
          containerPort = 8006
          hostPort      = 8006
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.kong_cp[0].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "kong-cp"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "kong health || exit 1"]
        interval    = 30
        retries     = 3
        timeout     = 5
        startPeriod = 120
      }
      environment = [
        {
          name  = "KONG_ROLE"
          value = "control_plane"
        },
        {
          name  = "KONG_DATABASE"
          value = "postgres"
        },
        {
          name  = "KONG_PG_HOST"
          value = var.kong_db_host != "" ? var.kong_db_host : "postgres.${aws_service_discovery_private_dns_namespace.service_discovery.name}"
        },
        {
          name  = "KONG_PG_PORT"
          value = tostring(var.kong_db_port)
        },
        {
          name  = "KONG_PG_USER"
          value = var.kong_db_user
        },
        {
          name  = "KONG_PG_DATABASE"
          value = var.kong_db_name
        },
        {
          name  = "KONG_ADMIN_LISTEN"
          value = "0.0.0.0:8001"
        },
        {
          name  = "KONG_ADMIN_GUI_LISTEN"
          value = "0.0.0.0:8002"
        },
        {
          name  = "KONG_ADMIN_GUI_URL"
          value = "http://${aws_lb.main.dns_name}:8002"
        },
        {
          name  = "KONG_ADMIN_GUI_API_URL"
          value = "http://${aws_lb.main.dns_name}:8001"
        },
        {
          name  = "KONG_CLUSTER_LISTEN"
          value = "0.0.0.0:8005"
        },
        {
          name  = "KONG_CLUSTER_TELEMETRY_LISTEN"
          value = "0.0.0.0:8006"
        },
        {
          name  = "KONG_PROXY_ACCESS_LOG"
          value = "/dev/stdout"
        },
        {
          name  = "KONG_ADMIN_ACCESS_LOG"
          value = "/dev/stdout"
        },
        {
          name  = "KONG_PROXY_ERROR_LOG"
          value = "/dev/stderr"
        },
        {
          name  = "KONG_ADMIN_ERROR_LOG"
          value = "/dev/stderr"
        },
        {
          name  = "KONG_CLUSTER_MTLS"
          value = "shared"
        }
      ]
      secrets = [
        {
          name      = "KONG_PG_PASSWORD"
          valueFrom = aws_secretsmanager_secret.kong_db_password[0].arn
        },
        {
          name      = "KONG_CLUSTER_CERT"
          valueFrom = aws_secretsmanager_secret.kong_cluster_cert[0].arn
        },
        {
          name      = "KONG_CLUSTER_CERT_KEY"
          valueFrom = aws_secretsmanager_secret.kong_cluster_key[0].arn
        }
      ]
      command = ["sh", "-c", "kong migrations bootstrap && kong migrations up && kong start"]
    }
  ])

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-cp-task"
  }
}

# AWS Cloud Map Service for Kong Control Plane service discovery
resource "aws_service_discovery_service" "kong_cp" {
  count = var.kong_control_plane_enabled ? 1 : 0
  name  = "kong-cp"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.service_discovery.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-cp-discovery-service"
  }
}

# Network Load Balancer for Kong Admin API
resource "aws_lb" "kong_admin_nlb" {
  count              = var.kong_control_plane_enabled ? 1 : 0
  name               = "${var.project_name}-${var.environment}-kong-admin-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnets

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-admin-nlb"
  }
}

# NLB Target Group for Kong Admin API (port 8001) - Internal access
resource "aws_lb_target_group" "kong_admin_nlb" {
  count       = var.kong_control_plane_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-kong-admin-nlb"
  port        = 8001
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    protocol            = "HTTP"
    port                = "8001"
    path                = "/status"
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-admin-nlb"
  }
}

# NLB Listener for Kong Admin API
resource "aws_lb_listener" "kong_admin_nlb" {
  count             = var.kong_control_plane_enabled ? 1 : 0
  load_balancer_arn = aws_lb.kong_admin_nlb[0].arn
  port              = "8001"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong_admin_nlb[0].arn
  }
}

# Kong Control Plane ECS Service
resource "aws_ecs_service" "kong_cp" {
  count                              = var.kong_control_plane_enabled ? 1 : 0
  name                               = "${var.project_name}-${var.environment}-kong-cp-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.kong_cp[0].arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  enable_execute_command             = true

  network_configuration {
    security_groups  = [var.application_sg_id]
    subnets          = var.private_subnets
    assign_public_ip = false
  }

  # Register Kong Admin API to internal NLB target group
  load_balancer {
    target_group_arn = aws_lb_target_group.kong_admin_nlb[0].arn
    container_name   = "${var.project_name}-${var.environment}-kong-cp-container"
    container_port   = 8001
  }

  # Register Kong Admin API to ALB target group (for demo access)
  load_balancer {
    target_group_arn = aws_lb_target_group.kong_admin[0].arn
    container_name   = "${var.project_name}-${var.environment}-kong-cp-container"
    container_port   = 8001
  }

  # Register Kong Admin GUI to ALB target group (for demo access)
  load_balancer {
    target_group_arn = aws_lb_target_group.kong_admin_gui[0].arn
    container_name   = "${var.project_name}-${var.environment}-kong-cp-container"
    container_port   = 8002
  }

  # Register service in Cloud Map for service discovery
  service_registries {
    registry_arn = aws_service_discovery_service.kong_cp[0].arn
  }

  depends_on = [
    aws_ecs_service.postgres,
    aws_lb_listener.kong_admin_nlb,
    aws_lb_listener.http,
    aws_lb_listener.kong_admin_gui
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-cp-service"
  }
}

# Generate self-signed certificates for Kong hybrid mode
resource "tls_private_key" "kong_cluster" {
  count     = var.kong_enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "kong_cluster" {
  count           = var.kong_enabled ? 1 : 0
  private_key_pem = tls_private_key.kong_cluster[0].private_key_pem

  subject {
    # IMPORTANT: Kong hybrid mode requires CN to be exactly "kong_clustering"
    common_name  = "kong_clustering"
    organization = var.project_name
  }

  validity_period_hours = 87600 # 10 years

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

# Store Kong cluster certificate in Secrets Manager
resource "aws_secretsmanager_secret" "kong_cluster_cert" {
  count                   = var.kong_enabled ? 1 : 0
  name                    = "${var.project_name}-${var.environment}-kong-cluster-cert"
  description             = "Kong cluster certificate for hybrid mode"
  recovery_window_in_days = 0 # Force immediate deletion

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-cluster-cert"
  }
}

resource "aws_secretsmanager_secret_version" "kong_cluster_cert" {
  count         = var.kong_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.kong_cluster_cert[0].id
  secret_string = tls_self_signed_cert.kong_cluster[0].cert_pem
}

# Store Kong cluster private key in Secrets Manager
resource "aws_secretsmanager_secret" "kong_cluster_key" {
  count                   = var.kong_enabled ? 1 : 0
  name                    = "${var.project_name}-${var.environment}-kong-cluster-key"
  description             = "Kong cluster private key for hybrid mode"
  recovery_window_in_days = 0 # Force immediate deletion

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-cluster-key"
  }
}

resource "aws_secretsmanager_secret_version" "kong_cluster_key" {
  count         = var.kong_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.kong_cluster_key[0].id
  secret_string = tls_private_key.kong_cluster[0].private_key_pem
}

# ============================================================================
# Kong Control Plane Outage Resilience - S3 Bucket for Config Fallback
# ============================================================================

# S3 bucket for storing Kong configuration during CP outage
resource "aws_s3_bucket" "kong_config_fallback" {
  count  = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? 1 : 0
  bucket = local.kong_fallback_bucket_name

  tags = {
    Name        = local.kong_fallback_bucket_name
    Description = "Kong Data Plane configuration fallback storage for CP outage resilience"
  }
}

# Enable versioning for config history
resource "aws_s3_bucket_versioning" "kong_config_fallback" {
  count  = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? 1 : 0
  bucket = aws_s3_bucket.kong_config_fallback[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "kong_config_fallback" {
  count  = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? 1 : 0
  bucket = aws_s3_bucket.kong_config_fallback[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "kong_config_fallback" {
  count  = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? 1 : 0
  bucket = aws_s3_bucket.kong_config_fallback[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule to delete old config versions (optional, keep 30 days of history)
resource "aws_s3_bucket_lifecycle_configuration" "kong_config_fallback" {
  count  = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? 1 : 0
  bucket = aws_s3_bucket.kong_config_fallback[0].id

  rule {
    id     = "delete-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "delete-election-files"
    status = "Enabled"

    expiration {
      days = 7
    }

    filter {
      prefix = "${var.kong_fallback_s3_prefix}/election/"
    }
  }
}

# IAM policy for Kong Data Plane - S3 Read and Write access
resource "aws_iam_policy" "kong_dp_s3_access" {
  count       = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-kong-dp-s3-access-policy"
  description = "Allow Kong Data Plane to read/write configuration from S3 for CP outage resilience"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.kong_config_fallback[0].arn,
          "${aws_s3_bucket.kong_config_fallback[0].arn}/*"
        ]
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-dp-s3-access-policy"
  }
}

# Attach S3 access policy to Kong Data Plane task role
resource "aws_iam_role_policy_attachment" "kong_dp_s3_access" {
  count      = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? 1 : 0
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.kong_dp_s3_access[0].arn
}

# Kong Gateway Data Plane ECS Task Definition
resource "aws_ecs_task_definition" "kong_gateway" {
  count                    = var.kong_enabled ? 1 : 0
  family                   = "${var.project_name}-${var.environment}-kong-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-${var.environment}-kong-container"
      image     = "kong:3.9.1"
      cpu       = var.task_cpu
      memory    = var.task_memory
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        },
        {
          containerPort = 8443
          hostPort      = 8443
          protocol      = "tcp"
        },
        {
          containerPort = 8100
          hostPort      = 8100
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.kong_app[0].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "kong"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "kong health || exit 1"]
        interval    = 30
        retries     = 3
        timeout     = 5
        startPeriod = 60
      }
      environment = local.kong_dp_environment
      secrets = [
        {
          name      = "KONG_CLUSTER_CERT"
          valueFrom = aws_secretsmanager_secret.kong_cluster_cert[0].arn
        },
        {
          name      = "KONG_CLUSTER_CERT_KEY"
          valueFrom = aws_secretsmanager_secret.kong_cluster_key[0].arn
        }
      ]
    }
  ])

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-task"
  }
}

# ============================================================================
# LOAD BALANCER ARCHITECTURE:
# 
# ALB (Internet-facing) → NLB (Internal) → Kong Gateway (ECS) → Hello Service (ECS)
#
# Target Groups:
# 1. ALB Target Group    → Points to NLB IPs (connects ALB to NLB)
# 2. NLB Target Group 1  → Points to Kong containers port 8000 (application traffic)  
# 3. NLB Target Group 2  → Points to Kong containers port 8100 (health checks)
# ============================================================================

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.public_sg_id]
  subnets            = var.public_subnets

  enable_deletion_protection = false
  idle_timeout               = 25

  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-${var.environment}-alb"
  }
}

# ALB Target Group - Routes traffic from ALB to NLB (when Kong enabled) or Hello-Service (when Kong disabled)
resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-${var.environment}-alb-tg"
  port        = var.kong_enabled ? 8000 : var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.kong_enabled ? "/status/ready" : "/actuator/health"
    port                = var.kong_enabled ? "8100" : "traffic-port"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-alb-tg"
  }
}

# Data source to get Kong NLB private IP addresses for connecting ALB to NLB
data "aws_network_interface" "kong_nlb_eni" {
  count = var.kong_enabled ? length(var.private_subnets) : 0

  filter {
    name   = "description"
    values = ["ELB ${aws_lb.kong_nlb[0].arn_suffix}"]
  }

  filter {
    name   = "subnet-id"
    values = [var.private_subnets[count.index]]
  }
}

# ALB to Kong NLB Connection - Attaches Kong NLB IPs to ALB target group (connects ALB → NLB_1 → Kong)
resource "aws_lb_target_group_attachment" "kong_nlb" {
  count            = var.kong_enabled ? length(var.private_subnets) : 0
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = data.aws_network_interface.kong_nlb_eni[count.index].private_ip
  port             = 8000

  depends_on = [aws_lb.kong_nlb, aws_lb_listener.kong_nlb_health]
}

# Data source to get Direct NLB private IP addresses for connecting ALB to NLB_2
data "aws_network_interface" "direct_nlb_eni" {
  count = var.direct_routing_enabled ? length(var.private_subnets) : 0

  filter {
    name   = "description"
    values = ["ELB ${aws_lb.direct_nlb[0].arn_suffix}"]
  }

  filter {
    name   = "subnet-id"
    values = [var.private_subnets[count.index]]
  }
}

# ALB to Direct NLB Connection - Attaches Direct NLB IPs to ALB target group (connects ALB → NLB_2 → Hello-Service)
resource "aws_lb_target_group_attachment" "direct_nlb" {
  count            = var.direct_routing_enabled ? length(var.private_subnets) : 0
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = data.aws_network_interface.direct_nlb_eni[count.index].private_ip
  port             = 8000

  depends_on = [aws_lb.direct_nlb, aws_lb_listener.direct_nlb]
}

# ALB Listener for HTTPS (when certificate is provided)
resource "aws_lb_listener" "https" {
  count             = var.enable_https ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ALB Target Group for Kong Admin API
resource "aws_lb_target_group" "kong_admin" {
  count       = var.kong_control_plane_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-kong-admin-tg"
  port        = 8001
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/status"
    port                = "8001"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-admin-tg"
  }
}

# ALB Target Group for Kong Admin GUI
resource "aws_lb_target_group" "kong_admin_gui" {
  count       = var.kong_control_plane_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-kong-gui-tg"
  port        = 8002
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = "8002"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200,404"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-gui-tg"
  }
}

# ALB Listener for HTTP (always present)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ALB Listener for Kong Admin API (port 8001)
resource "aws_lb_listener" "kong_admin_api" {
  count             = var.kong_control_plane_enabled ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 8001
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong_admin[0].arn
  }
}

# ALB Listener for Kong Admin GUI (port 8002)
resource "aws_lb_listener" "kong_admin_gui" {
  count             = var.kong_control_plane_enabled ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 8002
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong_admin_gui[0].arn
  }
}

# ECS Service
resource "aws_ecs_service" "app" {
  name                               = "${var.project_name}-${var.environment}-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = var.app_count
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  enable_execute_command             = true

  network_configuration {
    security_groups  = [var.application_sg_id]
    subnets          = var.private_subnets
    assign_public_ip = false
  }

  # Only attach to ALB if Kong is not enabled
  dynamic "load_balancer" {
    for_each = var.kong_enabled ? [] : [1]
    content {
      target_group_arn = aws_lb_target_group.app.arn
      container_name   = "${var.project_name}-${var.environment}-container"
      container_port   = var.container_port
    }
  }

  # Register Hello-Service to direct NLB target group (when direct routing is enabled)
  dynamic "load_balancer" {
    for_each = var.direct_routing_enabled ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.direct[0].arn
      container_name   = "${var.project_name}-${var.environment}-container"
      container_port   = var.container_port
    }
  }

  # Register service in Cloud Map for service discovery
  service_registries {
    registry_arn = aws_service_discovery_service.hello_service.arn
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener.https,
    aws_lb_listener.direct_nlb
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-service"
  }
}

# Network Load Balancer for Kong Gateway (NLB_1)
resource "aws_lb" "kong_nlb" {
  count              = var.kong_enabled ? 1 : 0
  name               = "${var.project_name}-${var.environment}-kong-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnets

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-nlb"
  }
}

# Network Load Balancer for Direct Hello-Service Access (NLB_2)
resource "aws_lb" "direct_nlb" {
  count              = var.direct_routing_enabled ? 1 : 0
  name               = "${var.project_name}-${var.environment}-direct-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnets

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-${var.environment}-direct-nlb"
  }
}

# NLB Target Group - Routes traffic from NLB to Kong Gateway containers (Port 8000 - Application Traffic)
resource "aws_lb_target_group" "kong" {
  count       = var.kong_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-kong-traffic"
  port        = 8000
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    protocol            = "HTTP"
    port                = "8100"
    path                = "/status/ready"
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-traffic"
  }
}

# NLB Target Group - Routes health checks from NLB to Kong Gateway containers (Port 8100 - Status API)
resource "aws_lb_target_group" "kong_health" {
  count       = var.kong_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-kong-health"
  port        = 8100
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    protocol            = "HTTP"
    port                = "8100"
    path                = "/status/ready"
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-health"
  }
}

# Direct NLB Target Group - Routes traffic directly to Hello-Service (Port 8080 - Application Traffic)
resource "aws_lb_target_group" "direct" {
  count       = var.direct_routing_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-direct-traffic"
  port        = 8080
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    protocol            = "HTTP"
    port                = "8080"
    path                = "/actuator/health"
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-direct-traffic"
  }
}

# NLB Listener - Accepts traffic on port 8000 and forwards to Kong Gateway containers (Application Traffic)
resource "aws_lb_listener" "kong_nlb" {
  count             = var.kong_enabled ? 1 : 0
  load_balancer_arn = aws_lb.kong_nlb[0].arn
  port              = "8000"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong[0].arn
  }
}

# NLB Listener - Accepts health checks on port 8100 and forwards to Kong Gateway status API
resource "aws_lb_listener" "kong_nlb_health" {
  count             = var.kong_enabled ? 1 : 0
  load_balancer_arn = aws_lb.kong_nlb[0].arn
  port              = "8100"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong_health[0].arn
  }
}

# Direct NLB Listener - Accepts traffic on port 8000 and forwards directly to Hello-Service (Application Traffic)
resource "aws_lb_listener" "direct_nlb" {
  count             = var.direct_routing_enabled ? 1 : 0
  load_balancer_arn = aws_lb.direct_nlb[0].arn
  port              = "8000"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.direct[0].arn
  }
}

# Kong Gateway ECS Service
resource "aws_ecs_service" "kong_gateway" {
  count                              = var.kong_enabled ? 1 : 0
  name                               = "${var.project_name}-${var.environment}-kong-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.kong_gateway[0].arn
  desired_count                      = var.kong_app_count
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"
  enable_execute_command             = true

  network_configuration {
    security_groups  = [var.application_sg_id]
    subnets          = var.private_subnets
    assign_public_ip = false
  }

  # Register Kong containers to NLB target group for application traffic (port 8000)
  load_balancer {
    target_group_arn = aws_lb_target_group.kong[0].arn
    container_name   = "${var.project_name}-${var.environment}-kong-container"
    container_port   = 8000
  }

  # Register Kong containers to NLB target group for health checks (port 8100)
  load_balancer {
    target_group_arn = aws_lb_target_group.kong_health[0].arn
    container_name   = "${var.project_name}-${var.environment}-kong-container"
    container_port   = 8100
  }

  # Register Kong Gateway service in Cloud Map for service discovery
  service_registries {
    registry_arn = aws_service_discovery_service.kong_gateway[0].arn
  }

  depends_on = [
    aws_lb_listener.kong_nlb,
    aws_lb_listener.kong_nlb_health,
    aws_ecs_service.kong_cp
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-kong-service"
  }
} 
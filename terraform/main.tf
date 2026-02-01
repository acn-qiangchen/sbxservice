terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Comment out the S3 backend for now to use local backend for POC
  /*
  backend "s3" {
    # These values should be replaced with actual values when setting up the environment
    # bucket = "sbxservice-terraform-state"
    # key    = "terraform/state"
    # region = "us-east-1"
    # dynamodb_table = "sbxservice-terraform-lock"
  }
  */
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project     = "sbxservice"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Construct container_images map from individual image variables
locals {
  container_images = merge(
    var.container_images,
    {
      for k, v in {
        hello = var.container_image_hello,
        kong  = var.container_image_kong,
      } : k => v if v != ""
    },
    var.container_image_url != "" ? { hello = var.container_image_url } : {}
  )

  # Construct domain names from AWS account ID
  domain_name     = "${var.aws_account_id}.realhandsonlabs.net"
  alb_domain_name = "alb.${var.aws_account_id}.realhandsonlabs.net"
}

# Data source for existing hosted zone
data "aws_route53_zone" "main" {
  name         = local.domain_name
  private_zone = false
}

# ACM Certificate with DNS validation
resource "aws_acm_certificate" "main" {
  domain_name       = "*.${local.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "wildcard-${local.domain_name}"
  }
}

# DNS validation records
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# Certificate validation
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# VPC and Network Configuration
module "vpc" {
  source = "./modules/vpc"

  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  project_name       = var.project_name

  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}



# Security Groups
module "security_groups" {
  source = "./modules/security_groups"

  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.vpc_cidr
}

# RDS PostgreSQL for Kong (optional - can use ECS PostgreSQL instead)
module "rds" {
  count  = var.kong_db_enabled && var.kong_db_use_rds ? 1 : 0
  source = "./modules/rds"

  project_name    = var.project_name
  environment     = var.environment
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  database_sg_id  = module.security_groups.database_sg_id

  db_name              = var.kong_db_name
  db_username          = var.kong_db_user
  db_password          = var.kong_db_password
  db_instance_class    = var.kong_db_instance_class
  db_allocated_storage = var.kong_db_allocated_storage
  multi_az             = var.kong_db_multi_az
  deletion_protection  = var.kong_db_deletion_protection
  skip_final_snapshot  = var.kong_db_skip_final_snapshot
}



# ECS Fargate for Spring Boot Application
module "ecs" {
  source = "./modules/ecs"

  project_name      = var.project_name
  environment       = var.environment
  region            = var.aws_region
  vpc_id            = module.vpc.vpc_id
  public_subnets    = module.vpc.public_subnets
  private_subnets   = module.vpc.private_subnets
  public_sg_id      = module.security_groups.public_sg_id
  application_sg_id = module.security_groups.application_sg_id
  database_sg_id    = module.security_groups.database_sg_id

  # Container configuration
  container_image_url = lookup(local.container_images, "hello", "")
  container_port      = 8080
  task_cpu            = 1024
  task_memory         = 2048
  app_count           = 1

  # ACM certificate for HTTPS - use the new certificate
  acm_certificate_arn = aws_acm_certificate_validation.main.certificate_arn
  enable_https        = true

  # Kong Gateway configuration
  kong_enabled   = var.kong_enabled
  kong_app_count = 1

  # Kong Database configuration
  kong_db_enabled            = var.kong_db_enabled
  kong_db_use_rds            = var.kong_db_use_rds
  kong_db_name               = var.kong_db_name
  kong_db_user               = var.kong_db_user
  kong_db_password           = var.kong_db_password
  kong_db_host               = var.kong_db_use_rds && var.kong_db_enabled ? module.rds[0].db_instance_address : ""
  kong_db_port               = var.kong_db_use_rds && var.kong_db_enabled ? module.rds[0].db_instance_port : 5432
  kong_control_plane_enabled = var.kong_control_plane_enabled

  # Direct routing configuration
  direct_routing_enabled = var.direct_routing_enabled
  kong_traffic_weight    = var.kong_traffic_weight
  direct_traffic_weight  = var.direct_traffic_weight

  # Kong CP Outage Resilience configuration
  kong_cp_outage_resilience_enabled = var.kong_cp_outage_resilience_enabled
  kong_fallback_s3_bucket_name      = var.kong_fallback_s3_bucket_name
  kong_fallback_s3_prefix           = var.kong_fallback_s3_prefix
}

# Route53 A record for ALB custom domain
resource "aws_route53_record" "alb" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.alb_domain_name
  type    = "A"

  alias {
    name                   = module.ecs.alb_dns_name
    zone_id                = module.ecs.alb_zone_id
    evaluate_target_health = true
  }
}

# API Gateway
module "api_gateway" {
  source = "./modules/api_gateway"

  project_name    = var.project_name
  environment     = var.environment
  public_subnets  = module.vpc.public_subnets
  public_sg_id    = module.security_groups.public_sg_id
  lb_listener_arn = module.ecs.lb_listener_arn
  alb_dns_name    = local.alb_domain_name
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/sbxservice/${var.environment}"
  retention_in_days = 30

  tags = {
    Name = "sbxservice-${var.environment}-logs"
  }
} 
output "cluster_id" {
  description = "ID of the ECS cluster"
  value       = aws_ecs_cluster.main.id
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "alb_arn" {
  description = "ARN of the load balancer"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the load balancer"
  value       = aws_lb.main.zone_id
}

output "lb_listener_arn" {
  description = "ARN of the load balancer listener"
  value       = aws_lb_listener.http.arn
}

output "task_execution_role_arn" {
  description = "ARN of the task execution role"
  value       = aws_iam_role.ecs_execution_role.arn
}

output "task_role_arn" {
  description = "ARN of the task role"
  value       = aws_iam_role.ecs_task_role.arn
}

output "log_group_name" {
  description = "Name of the CloudWatch log group"
  value       = aws_cloudwatch_log_group.app.name
}

# Kong Gateway outputs
output "kong_nlb_arn" {
  description = "ARN of the Kong Gateway Network Load Balancer"
  value       = var.kong_enabled ? aws_lb.kong_nlb[0].arn : null
}

output "kong_nlb_dns_name" {
  description = "DNS name of the Kong Gateway Network Load Balancer"
  value       = var.kong_enabled ? aws_lb.kong_nlb[0].dns_name : null
}

output "kong_nlb_zone_id" {
  description = "Zone ID of the Kong Gateway Network Load Balancer"
  value       = var.kong_enabled ? aws_lb.kong_nlb[0].zone_id : null
}

output "kong_service_name" {
  description = "Name of the Kong Gateway ECS service"
  value       = var.kong_enabled ? aws_ecs_service.kong_gateway[0].name : null
}

output "kong_task_definition_arn" {
  description = "ARN of the Kong Gateway task definition"
  value       = var.kong_enabled ? aws_ecs_task_definition.kong_gateway[0].arn : null
}

output "kong_log_group_name" {
  description = "Name of the Kong Gateway CloudWatch log group"
  value       = var.kong_enabled ? aws_cloudwatch_log_group.kong_app[0].name : null
}

# Kong Gateway NLB Target Group outputs  
output "kong_nlb_target_group_arn" {
  description = "ARN of the NLB target group for Kong Gateway application traffic (port 8000)"
  value       = var.kong_enabled ? aws_lb_target_group.kong[0].arn : null
}

output "kong_nlb_health_target_group_arn" {
  description = "ARN of the NLB target group for Kong Gateway health checks (port 8100)"
  value       = var.kong_enabled ? aws_lb_target_group.kong_health[0].arn : null
}

# Direct NLB outputs
output "direct_nlb_arn" {
  description = "ARN of the Direct Network Load Balancer"
  value       = var.direct_routing_enabled ? aws_lb.direct_nlb[0].arn : null
}

output "direct_nlb_dns_name" {
  description = "DNS name of the Direct Network Load Balancer"
  value       = var.direct_routing_enabled ? aws_lb.direct_nlb[0].dns_name : null
}

output "direct_nlb_target_group_arn" {
  description = "ARN of the Direct NLB target group for Hello-Service traffic (port 8080)"
  value       = var.direct_routing_enabled ? aws_lb_target_group.direct[0].arn : null
}

# Note: Kong Gateway secrets outputs removed - no longer using Konnect certificates

# Service Discovery outputs
output "service_discovery_namespace_id" {
  description = "ID of the service discovery namespace"
  value       = aws_service_discovery_private_dns_namespace.service_discovery.id
}

output "service_discovery_namespace_name" {
  description = "Name of the service discovery namespace"
  value       = aws_service_discovery_private_dns_namespace.service_discovery.name
}

output "hello_service_discovery_arn" {
  description = "ARN of the hello-service discovery service"
  value       = aws_service_discovery_service.hello_service.arn
}

output "kong_service_discovery_arn" {
  description = "ARN of the Kong Gateway service discovery service"
  value       = var.kong_enabled ? aws_service_discovery_service.kong_gateway[0].arn : null
}

# PostgreSQL Database outputs (only for ECS PostgreSQL, not RDS)
output "postgres_service_name" {
  description = "Name of the PostgreSQL ECS service"
  value       = var.kong_db_enabled && !var.kong_db_use_rds ? aws_ecs_service.postgres[0].name : null
}

output "postgres_service_discovery_arn" {
  description = "ARN of the PostgreSQL service discovery service"
  value       = var.kong_db_enabled && !var.kong_db_use_rds ? aws_service_discovery_service.postgres[0].arn : null
}

output "postgres_dns_name" {
  description = "DNS name for PostgreSQL service discovery"
  value       = var.kong_db_enabled && !var.kong_db_use_rds ? "postgres.${aws_service_discovery_private_dns_namespace.service_discovery.name}" : null
}

output "kong_db_password_secret_arn" {
  description = "ARN of the Kong database password secret"
  value       = var.kong_db_enabled ? aws_secretsmanager_secret.kong_db_password[0].arn : null
}

# Kong Control Plane outputs
output "kong_cp_service_name" {
  description = "Name of the Kong Control Plane ECS service"
  value       = var.kong_control_plane_enabled ? aws_ecs_service.kong_cp[0].name : null
}

output "kong_cp_service_discovery_arn" {
  description = "ARN of the Kong Control Plane service discovery service"
  value       = var.kong_control_plane_enabled ? aws_service_discovery_service.kong_cp[0].arn : null
}

output "kong_cp_dns_name" {
  description = "DNS name for Kong Control Plane service discovery"
  value       = var.kong_control_plane_enabled ? "kong-cp.${aws_service_discovery_private_dns_namespace.service_discovery.name}" : null
}

output "kong_cp_log_group_name" {
  description = "Name of the Kong Control Plane CloudWatch log group"
  value       = var.kong_control_plane_enabled ? aws_cloudwatch_log_group.kong_cp[0].name : null
}

output "kong_admin_nlb_dns_name" {
  description = "DNS name of the Kong Admin API Network Load Balancer"
  value       = var.kong_control_plane_enabled ? aws_lb.kong_admin_nlb[0].dns_name : null
}

output "kong_admin_api_endpoint" {
  description = "Kong Admin API endpoint URL"
  value       = var.kong_control_plane_enabled ? "http://${aws_lb.kong_admin_nlb[0].dns_name}:8001" : null
}

output "kong_admin_gui_endpoint" {
  description = "Kong Admin GUI endpoint URL (via ALB)"
  value       = var.kong_control_plane_enabled ? "http://${aws_lb.main.dns_name}:8002" : null
}

# Kong CP Outage Resilience outputs
output "kong_config_fallback_bucket_name" {
  description = "Name of the S3 bucket for Kong configuration fallback"
  value       = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? aws_s3_bucket.kong_config_fallback[0].id : null
}

output "kong_config_fallback_bucket_arn" {
  description = "ARN of the S3 bucket for Kong configuration fallback"
  value       = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? aws_s3_bucket.kong_config_fallback[0].arn : null
}

output "kong_config_fallback_s3_uri" {
  description = "S3 URI for Kong configuration fallback storage"
  value       = var.kong_enabled && var.kong_cp_outage_resilience_enabled ? "s3://${aws_s3_bucket.kong_config_fallback[0].id}/${var.kong_fallback_s3_prefix}" : null
} 
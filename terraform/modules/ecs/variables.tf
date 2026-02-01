variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., dev, test, prod)"
  type        = string
}

variable "region" {
  description = "The AWS region to deploy resources"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnets" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "private_subnets" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "public_sg_id" {
  description = "ID of the public security group"
  type        = string
}

variable "application_sg_id" {
  description = "ID of the application security group"
  type        = string
}

variable "database_sg_id" {
  description = "ID of the database security group"
  type        = string
  default     = ""
}

variable "container_image_url" {
  description = "URL of the container image in ECR"
  type        = string
  default     = ""
}

variable "container_images" {
  description = "Map of container images for different services"
  type        = map(string)
  default     = {}
}

variable "task_cpu" {
  description = "CPU units for the task (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory for the task in MB"
  type        = number
  default     = 512
}

variable "container_port" {
  description = "Port exposed by the container"
  type        = number
  default     = 8080
}

variable "app_count" {
  description = "Number of containers to run"
  type        = number
  default     = 1
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for HTTPS"
  type        = string
  default     = ""
}

variable "enable_https" {
  description = "Whether to enable HTTPS listener (should be true when certificate is provided)"
  type        = bool
  default     = false
}



# Kong Gateway variables
variable "kong_enabled" {
  description = "Whether to enable Kong Gateway service"
  type        = bool
  default     = true
}



variable "kong_app_count" {
  description = "Number of Kong Gateway containers to run"
  type        = number
  default     = 1
}

# Direct routing variables
variable "direct_routing_enabled" {
  description = "Whether to enable direct routing to Hello-Service (bypassing Kong Gateway)"
  type        = bool
  default     = false
}

variable "kong_traffic_weight" {
  description = "Percentage of traffic to send through Kong Gateway (0-100)"
  type        = number
  default     = 100
  validation {
    condition     = var.kong_traffic_weight >= 0 && var.kong_traffic_weight <= 100
    error_message = "Kong traffic weight must be between 0 and 100."
  }
}

variable "direct_traffic_weight" {
  description = "Percentage of traffic to send directly to Hello-Service (0-100)"
  type        = number
  default     = 0
  validation {
    condition     = var.direct_traffic_weight >= 0 && var.direct_traffic_weight <= 100
    error_message = "Direct traffic weight must be between 0 and 100."
  }
}

# Kong Database variables
variable "kong_db_enabled" {
  description = "Whether to enable PostgreSQL database for Kong"
  type        = bool
  default     = true
}

variable "kong_db_name" {
  description = "Name of the Kong database"
  type        = string
  default     = "kong"
}

variable "kong_db_user" {
  description = "Username for the Kong database"
  type        = string
  default     = "kong"
}

variable "kong_db_password" {
  description = "Password for the Kong database"
  type        = string
  default     = ""
  sensitive   = true
}

variable "kong_db_host" {
  description = "Hostname of the Kong database (RDS endpoint or service discovery name)"
  type        = string
  default     = ""
}

variable "kong_db_port" {
  description = "Port of the Kong database"
  type        = number
  default     = 5432
}

variable "kong_control_plane_enabled" {
  description = "Whether to enable Kong Control Plane"
  type        = bool
  default     = true
}

variable "kong_db_use_rds" {
  description = "Whether to use RDS for Kong database (true) or ECS container (false)"
  type        = bool
  default     = true
}

# Kong Control Plane Outage Resilience variables
variable "kong_cp_outage_resilience_enabled" {
  description = "Enable Kong Data Plane resilience with S3 fallback during CP outage"
  type        = bool
  default     = true
}

variable "kong_fallback_s3_bucket_name" {
  description = "S3 bucket name for Kong configuration fallback (auto-generated if empty)"
  type        = string
  default     = ""
}

variable "kong_fallback_s3_prefix" {
  description = "S3 prefix/path for Kong configuration fallback"
  type        = string
  default     = "kong-config"
} 
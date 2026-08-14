variable "aws_region" {
  description = "AWS region where resources will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS profile to use"
  type        = string
  default     = ""
}

variable "aws_account_id" {
  description = "AWS account ID for domain construction and ECR"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "sbxservice"
}

# Container image variables — no longer used for the app service (now hardcoded to kong/httpbin),
# but kept for potential overrides or future use.
variable "container_image_hello" {
  description = "Override image for the app service (default: kong/httpbin)"
  type        = string
  default     = ""
}

variable "container_image_kong" {
  description = "Override image for the Kong Gateway service (default: kong:3.9.1)"
  type        = string
  default     = ""
}

# Map of all container images (constructed from individual image variables)
variable "container_images" {
  description = "Map of container images for different services (derived from container_image_* variables)"
  type        = map(string)
  default     = {}
}

variable "container_image_url" {
  description = "Override URL for the main container image — DEPRECATED: set in main.tf directly"
  type        = string
  default     = ""
}

# Kong Gateway configuration
variable "kong_enabled" {
  description = "Whether to enable Kong Gateway service"
  type        = bool
  default     = true
}

variable "direct_routing_enabled" {
  description = "Whether to enable direct routing to Hello-Service (bypassing Kong Gateway)"
  type        = bool
  default     = false
}

variable "kong_traffic_weight" {
  description = "Percentage of traffic to send through Kong Gateway (0-100)"
  type        = number
  default     = 100
}

variable "direct_traffic_weight" {
  description = "Percentage of traffic to send directly to Hello-Service (0-100)"
  type        = number
  default     = 0
}

# Kong Database configuration
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
  default     = "KongPassword123!"
  sensitive   = true
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

variable "kong_db_instance_class" {
  description = "RDS instance class for Kong database"
  type        = string
  default     = "db.t3.micro"
}

variable "kong_db_allocated_storage" {
  description = "Allocated storage in GB for Kong RDS database"
  type        = number
  default     = 20
}

variable "kong_db_multi_az" {
  description = "Enable Multi-AZ deployment for Kong RDS database"
  type        = bool
  default     = false
}

variable "kong_db_deletion_protection" {
  description = "Enable deletion protection for Kong RDS database"
  type        = bool
  default     = false
}

variable "kong_db_skip_final_snapshot" {
  description = "Skip final snapshot when deleting Kong RDS database"
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}



# Database variables are commented out since we're not using a database in our POC
/*
variable "db_name" {
  description = "Name of the database"
  type        = string
  default     = "sbxservice"
}

variable "db_username" {
  description = "Username for the database"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "db_password" {
  description = "Password for the database"
  type        = string
  sensitive   = true
  # Do not set a default value for passwords - should be provided via secure means
}
*/ 
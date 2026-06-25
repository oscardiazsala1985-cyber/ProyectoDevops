variable "aws_region" {
  description = "AWS region where resources will be deployed."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "sre-process-service"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
  
  
  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "El valor de environment debe ser estrictamente 'dev', 'qa' o 'prod'."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets."
  type        = list(string)
  default     = ["10.40.0.0/24", "10.40.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets where Lambda and Redis run."
  type        = list(string)
  default     = ["10.40.10.0/24", "10.40.11.0/24"]
}

variable "lambda_runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "nodejs20.x"
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 15
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 256
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_ttl_seconds" {
  description = <<-EOT
    TTL en segundos para las claves de caché en Redis.
    Valor actual: 60s — balance deliberado entre frescura de datos y reducción de
    carga sobre RDS. En escenarios de alta lectura este valor puede incrementarse
    (ej. 300s) sin impacto en consistencia para datos de referencia.
  EOT
  type        = number
  default     = 60
}

variable "api_rate_limit" {
  description = "HTTP API stage throttling rate limit."
  type        = number
  default     = 20
}

variable "api_burst_limit" {
  description = "HTTP API stage throttling burst limit."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days."
  type        = number
  default     = 14
}


variable "common_tags" {
  description = "Etiquetas base para cumplimiento corporativo y facturacion."
  type        = map(string)
  default = {
    Project     = "sre-process-service"
    Environment = "dev"
    ManagedBy   = "Terraform"
    Owner       = "Oscar Diaz"
  }
}
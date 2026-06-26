terraform {
  required_version = ">= 1.6.0"

  # Remote State — S3 + DynamoDB State Locking
  # El estado de Terraform se almacena de forma remota en S3 y se usa
  # DynamoDB para implementar state locking, evitando modificaciones
  # concurrentes y garantizando consistencia en entornos de equipo.
  backend "s3" {
    bucket         = "sre-process-service-tfstate-440744252164"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sre-process-service-tf-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

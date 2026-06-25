# ==============================================================================
# rds.tf
# Amazon RDS — Base de datos relacional administrada en subnets privadas
# ==============================================================================

# ------------------------------------------------------------------------------
# Variables nuevas para RDS
# ------------------------------------------------------------------------------

variable "db_engine" {
  description = "Motor de base de datos RDS."
  type        = string
  default     = "postgres"
}

variable "db_engine_version" {
  description = "Versión del motor de base de datos."
  type        = string
  default     = "16.3"
}

variable "db_instance_class" {
  description = "Clase de instancia RDS."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Almacenamiento inicial en GB para la instancia RDS."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Límite máximo de autoscaling de almacenamiento RDS en GB."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Nombre de la base de datos inicial."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos."
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "db_password" {
  description = "Contraseña del usuario administrador. Usar secrets manager en prod."
  type        = string
  sensitive   = true
  # No tiene default — debe pasarse via terraform.tfvars o variable de entorno TF_VAR_db_password
}

variable "db_multi_az" {
  description = "Habilitar Multi-AZ para alta disponibilidad."
  type        = bool
  default     = false # Cambiar a true en producción
}

variable "db_backup_retention_days" {
  description = "Días de retención de backups automáticos."
  type        = number
  default     = 7
}

# ------------------------------------------------------------------------------
# Security Group — RDS
# Acepta tráfico solo desde EC2 App SG y Lambda SG en el puerto del motor
# ------------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "RDS SG: ingress only from EC2 app tier and Lambda on DB port."
  vpc_id      = aws_vpc.main.id

  tags = merge({ Name = "${local.name}-rds-sg" }, var.common_tags)
}

# Puerto dinámico según el motor (5432 Postgres / 3306 MySQL)
locals {
  db_port = var.db_engine == "mysql" || var.db_engine == "mariadb" ? 3306 : 5432
}

resource "aws_security_group_rule" "rds_ingress_ec2" {
  type                     = "ingress"
  description              = "DB access from EC2 app tier"
  from_port                = local.db_port
  to_port                  = local.db_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.ec2_app.id
}

resource "aws_security_group_rule" "rds_ingress_lambda" {
  type                     = "ingress"
  description              = "DB access from Lambda"
  from_port                = local.db_port
  to_port                  = local.db_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.lambda.id
}

# Permitir egreso a EC2 desde las instancias RDS (respuestas)
resource "aws_security_group_rule" "ec2_egress_rds" {
  type                     = "egress"
  description              = "EC2 to RDS DB port"
  from_port                = local.db_port
  to_port                  = local.db_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ec2_app.id
  source_security_group_id = aws_security_group.rds.id
}

resource "aws_security_group_rule" "lambda_egress_rds" {
  type                     = "egress"
  description              = "Lambda to RDS DB port"
  from_port                = local.db_port
  to_port                  = local.db_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.rds.id
}

# ------------------------------------------------------------------------------
# DB Subnet Group — subnets PRIVADAS (multi-AZ ready)
# ------------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name        = "${local.name}-db-subnets"
  description = "RDS subnet group using private subnets across 2 AZs."
  subnet_ids  = aws_subnet.private[*].id

  tags = merge({ Name = "${local.name}-db-subnets" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# RDS Instance
# ------------------------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier     = "${local.name}-db"
  engine         = var.db_engine
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage # Autoscaling de storage
  storage_type          = "gp3"
  storage_encrypted     = true # Cifrado en reposo siempre habilitado

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = local.db_port

  # Red — en subnets privadas, sin acceso público
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Alta disponibilidad
  multi_az = var.db_multi_az

  # Backups y mantenimiento
  backup_retention_period  = var.db_backup_retention_days
  backup_window            = "02:00-03:00"
  maintenance_window       = "Mon:03:30-Mon:04:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  # Protección y monitoreo
  deletion_protection                   = false # Cambiar a true en producción
  skip_final_snapshot                   = true  # Cambiar a false en producción
  final_snapshot_identifier             = "${local.name}-db-final-snapshot"
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60 # Enhanced Monitoring cada 60 segundos
  monitoring_role_arn                   = aws_iam_role.rds_enhanced_monitoring.arn

  # Logs a CloudWatch — aplica solo a postgres; para mysql usar audit,error,general,slowquery
  enabled_cloudwatch_logs_exports = var.db_engine == "postgres" ? ["postgresql", "upgrade"] : ["audit", "error", "general", "slowquery"]

  # Aplicar cambios inmediatamente en dev; en prod usar ventana de mantenimiento
  apply_immediately = true

  tags = merge({ Name = "${local.name}-db" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# IAM Role — RDS Enhanced Monitoring
# Principio de mínimo privilegio: solo permite publicar métricas de monitoreo
# ------------------------------------------------------------------------------

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${local.name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge({ Name = "${local.name}-rds-monitoring-role" }, var.common_tags)
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

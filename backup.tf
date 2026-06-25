# ==============================================================================
# backup.tf
# AWS Backup — Políticas centralizadas de respaldo y recuperación
# Cubre punto 8 del reto: Políticas de Respaldo y Recuperación
# Backup automatizado de RDS y EC2 con retención configurable
# ==============================================================================

# ------------------------------------------------------------------------------
# Variable para controlar retención de backups
# ------------------------------------------------------------------------------

variable "backup_retention_days" {
  description = "Días de retención para los backups en el vault de AWS Backup."
  type        = number
  default     = 14
}

variable "backup_cold_storage_days" {
  description = "Días antes de mover backups a cold storage (más barato, acceso más lento)."
  type        = number
  default     = 30
}

# ------------------------------------------------------------------------------
# AWS Backup Vault
# Un vault es el contenedor seguro donde se guardan los backups
# Modo dummies: es como una caja fuerte en AWS donde van todas las copias
# ------------------------------------------------------------------------------

resource "aws_backup_vault" "main" {
  name = "${local.name}-backup-vault"

  tags = merge({ Name = "${local.name}-backup-vault" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# IAM Role — AWS Backup necesita permisos para hacer snapshots de RDS y EC2
# ------------------------------------------------------------------------------

resource "aws_iam_role" "backup" {
  name = "${local.name}-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge({ Name = "${local.name}-backup-role" }, var.common_tags)
}

resource "aws_iam_role_policy_attachment" "backup_policy" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore_policy" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ------------------------------------------------------------------------------
# AWS Backup Plan — define CUÁNDO y CON QUÉ FRECUENCIA hacer backups
# Modo dummies: es como programar una alarma que dice "haz una copia cada día a las 2 AM"
# ------------------------------------------------------------------------------

resource "aws_backup_plan" "main" {
  name = "${local.name}-backup-plan"

  # Regla 1: Backup diario — retención 14 días (sin cold storage)
  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 2 * * ? *)" # Diario a las 02:00 UTC

    start_window      = 60
    completion_window = 120

    lifecycle {
      delete_after = 14 # Borrar después de 14 días
    }

    recovery_point_tags = merge(
      { BackupType = "daily" },
      var.common_tags
    )
  }

  # Regla 2: Backup semanal — retención 120 días con cold storage a los 30 días
  rule {
    rule_name         = "weekly-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 ? * SUN *)" # Domingos a las 03:00 UTC

    start_window      = 60
    completion_window = 180

    lifecycle {
      cold_storage_after = 30  # Cold storage después de 30 días (más barato)
      delete_after       = 120 # Eliminar después de 120 días (30+90 mínimo requerido)
    }

    recovery_point_tags = merge(
      { BackupType = "weekly" },
      var.common_tags
    )
  }

  tags = merge({ Name = "${local.name}-backup-plan" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# AWS Backup Selection — QUÉ recursos se respaldan
# Usa tags para seleccionar recursos automáticamente
# Cualquier recurso con el tag ManagedBy=Terraform será respaldado
# ------------------------------------------------------------------------------

resource "aws_backup_selection" "main" {
  name         = "${local.name}-backup-selection"
  plan_id      = aws_backup_plan.main.id
  iam_role_arn = aws_iam_role.backup.arn

  # Selección por ARN explícito: RDS instance
  resources = [
    aws_db_instance.main.arn,
  ]

  # Selección por tag: EC2 instances con tag ManagedBy=Terraform
  condition {
    string_equals {
      key   = "aws:ResourceTag/ManagedBy"
      value = "Terraform"
    }
  }
}

# ------------------------------------------------------------------------------
# CloudWatch Alarm — alerta si un backup falla
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "backup_failed" {
  alarm_name          = "${local.name}-backup-job-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "NumberOfBackupJobsFailed"
  namespace           = "AWS/Backup"
  period              = 86400 # 24 horas
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Un job de backup falló. Verificar AWS Backup console."
  treat_missing_data  = "notBreaching"

  tags = merge({ Name = "${local.name}-backup-failed-alarm" }, var.common_tags)
}

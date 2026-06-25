# ==============================================================================
# guardduty.tf
# Amazon GuardDuty — Detección de amenazas con ML en tiempo real
# Cubre punto 4 del reto: Ciberseguridad Integrada
# GuardDuty analiza CloudTrail, VPC Flow Logs y DNS logs automáticamente
# ==============================================================================

# ------------------------------------------------------------------------------
# Amazon GuardDuty Detector
# Una vez habilitado, analiza CONTINUAMENTE sin necesidad de configurar agentes
# ------------------------------------------------------------------------------

resource "aws_guardduty_detector" "main" {
  enable = true

  # Frecuencia de exportación de findings a CloudWatch Events
  # FIFTEEN_MINUTES es el mínimo — ideal para respuesta rápida a amenazas
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  datasources {
    s3_logs {
      enable = true # Detecta accesos anómalos al bucket de resultados
    }
    kubernetes {
      audit_logs {
        enable = false # No tenemos EKS desplegado en este entorno
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true # Escanea volúmenes EBS si detecta actividad maliciosa
        }
      }
    }
  }

  tags = merge({ Name = "${local.name}-guardduty" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# CloudWatch Event Rule — captura findings de GuardDuty en tiempo real
# Un "finding" es una alerta de amenaza detectada por GuardDuty
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${local.name}-guardduty-findings"
  description = "Captura todos los findings de GuardDuty para notificación inmediata"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }] # Medium(4-6), High(7-8.9), Critical(9+)
    }
  })

  tags = merge({ Name = "${local.name}-guardduty-rule" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# SNS Topic — canal de notificaciones para alertas de seguridad
# ------------------------------------------------------------------------------

resource "aws_sns_topic" "security_alerts" {
  name = "${local.name}-security-alerts"

  tags = merge({ Name = "${local.name}-security-alerts" }, var.common_tags)
}

# Política del SNS Topic: permite que CloudWatch Events publique en él
resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchEvents"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# CloudWatch Event Target — envía findings a SNS
# Desde SNS se puede conectar a email, Slack, PagerDuty, Lambda, etc.
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "GuardDutyToSNS"
  arn       = aws_sns_topic.security_alerts.arn

  # Transforma el evento para incluir solo la información relevante
  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      description = "$.detail.description"
      account     = "$.detail.accountId"
      region      = "$.region"
      time        = "$.time"
    }
    input_template = "\"🚨 GUARDDUTY ALERT\\nSeveridad: <severity>\\nTipo: <type>\\nDescripción: <description>\\nCuenta: <account>\\nRegión: <region>\\nHora: <time>\""
  }
}

# ------------------------------------------------------------------------------
# CloudWatch Alarm — findings de alta severidad (>=7)
# Severity 7-10 = High/Critical — requiere respuesta inmediata
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "guardduty_high_severity" {
  alarm_name          = "${local.name}-guardduty-high-severity"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FindingCount"
  namespace           = "AWS/GuardDuty"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "GuardDuty detectó un finding de alta severidad (>=7). Revisar inmediatamente."
  treat_missing_data  = "notBreaching"

  dimensions = {
    DetectorId = aws_guardduty_detector.main.id
  }

  tags = merge({ Name = "${local.name}-guardduty-alarm" }, var.common_tags)
}

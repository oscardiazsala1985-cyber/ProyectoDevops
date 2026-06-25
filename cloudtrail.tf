# ==============================================================================
# cloudtrail.tf
# AWS CloudTrail — Auditoría completa de llamadas API en la cuenta
# Cubre el punto 5 del reto: auditoría de permisos con mínimo privilegio
# Trail multi-región con logs en S3 cifrados y validación de integridad
# ==============================================================================

# ------------------------------------------------------------------------------
# S3 Bucket dedicado para logs de CloudTrail
# Separado del bucket de resultados para aislamiento de responsabilidades
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket        = "${local.name}-cloudtrail-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = merge({ Name = "${local.name}-cloudtrail-logs" }, var.common_tags)
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Retención: los logs de auditoría se conservan 90 días en versión actual
# y las versiones antiguas se purgan a los 30 días
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    id     = "cloudtrail-retention"
    status = "Enabled"

    filter { prefix = "" }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ------------------------------------------------------------------------------
# Bucket Policy — CloudTrail REQUIERE permisos explícitos para escribir en S3
# Sin esta policy, el trail falla al intentar entregar los logs
# ------------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  # depends_on evita race condition entre la policy y el bloqueo de acceso público
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudTrail verifica que puede escribir en el bucket antes de activarse
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.name}-trail"
          }
        }
      },
      {
        # Permiso de escritura de logs — solo desde CloudTrail de esta cuenta
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.name}-trail"
          }
        }
      },
      {
        # Denegar cualquier acceso HTTP (solo HTTPS)
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.cloudtrail_logs.arn,
          "${aws_s3_bucket.cloudtrail_logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# CloudWatch Log Group — para búsqueda de eventos en tiempo real desde la consola
# Complementa el almacenamiento en S3 (largo plazo) con visibilidad inmediata
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${local.name}"
  retention_in_days = var.log_retention_days

  tags = merge({ Name = "${local.name}-cloudtrail-logs" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# IAM Role — CloudTrail necesita permisos para escribir en CloudWatch Logs
# Mínimo privilegio: solo CreateLogStream y PutLogEvents en su log group
# ------------------------------------------------------------------------------

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "${local.name}-cloudtrail-cw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge({ Name = "${local.name}-cloudtrail-cw-role" }, var.common_tags)
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "${local.name}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudTrailCreateLogStream"
        Effect = "Allow"
        Action = ["logs:CreateLogStream"]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      },
      {
        Sid    = "CloudTrailPutLogEvents"
        Effect = "Allow"
        Action = ["logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# AWS CloudTrail — Trail multi-región
#
# Configuración de seguridad:
#   - is_multi_region_trail = true   → captura eventos en TODAS las regiones
#   - enable_log_file_validation     → detecta si alguien tamperó los logs
#   - include_global_service_events  → captura IAM, STS, CloudFront (globales)
#   - log_file_validation            → genera digest firmado por cada archivo
# ------------------------------------------------------------------------------

resource "aws_cloudtrail" "main" {
  name                          = "${local.name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.bucket
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  # Enviar también a CloudWatch Logs para búsqueda en tiempo real
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  # Eventos de gestión (quién creó/modificó/eliminó recursos) — sin costo extra
  event_selector {
    read_write_type           = "All"     # Captura lecturas Y escrituras
    include_management_events = true

    # Eventos de datos en S3: captura accesos al bucket de resultados
    # Tiene costo adicional (~$0.10 por 100k eventos) — scope al bucket propio
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.results.arn}/"]
    }
  }

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_logs,
    aws_iam_role_policy.cloudtrail_cloudwatch
  ]

  tags = merge({ Name = "${local.name}-trail" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# CloudWatch Alarm — Actividad IAM sospechosa
# Detecta si alguien intenta hacer cambios en políticas IAM
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "iam_changes" {
  name           = "${local.name}-iam-changes-filter"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  # Patrón que detecta eventos de modificación IAM
  pattern = "{ ($.eventSource = iam.amazonaws.com) && (($.eventName = DeleteGroupPolicy) || ($.eventName = DeleteRolePolicy) || ($.eventName = DeleteUserPolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutUserPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy)) }"

  metric_transformation {
    name      = "IAMPolicyChanges"
    namespace = "${local.name}/SecurityEvents"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_changes" {
  alarm_name          = "${local.name}-iam-policy-changes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "IAMPolicyChanges"
  namespace           = "${local.name}/SecurityEvents"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detectado cambio en políticas IAM — revisar CloudTrail."
  treat_missing_data  = "notBreaching"

  tags = merge({ Name = "${local.name}-iam-changes-alarm" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# CloudWatch Alarm — Llamadas a API no autorizadas (AccessDenied)
# Detecta intentos de acceso con permisos insuficientes — posible intrusión
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "unauthorized_api" {
  name           = "${local.name}-unauthorized-api-filter"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  pattern = "{ ($.errorCode = \"*UnauthorizedAccess*\") || ($.errorCode = \"AccessDenied\") }"

  metric_transformation {
    name      = "UnauthorizedAPICalls"
    namespace = "${local.name}/SecurityEvents"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_api" {
  alarm_name          = "${local.name}-unauthorized-api-calls"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnauthorizedAPICalls"
  namespace           = "${local.name}/SecurityEvents"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Múltiples llamadas API no autorizadas detectadas — posible intento de acceso."
  treat_missing_data  = "notBreaching"

  tags = merge({ Name = "${local.name}-unauthorized-api-alarm" }, var.common_tags)
}

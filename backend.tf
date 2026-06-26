# ==============================================================================
# backend.tf — Remote State con S3 y DynamoDB State Locking
#
# DECISIÓN DE ARQUITECTURA
# ─────────────────────────────────────────────────────────────────────────────
# El estado de Terraform se almacena de forma remota en Amazon S3 y se utiliza
# DynamoDB para implementar state locking, evitando modificaciones concurrentes
# y asegurando la consistencia del estado en entornos de equipo y pipelines CI/CD.
#
# ¿Por qué es necesario en producción?
#
#   Sin remote state, terraform.tfstate vive en el disco local del ingeniero.
#   Eso genera tres riesgos críticos en entornos reales:
#
#   1. CONCURRENCIA — si dos ingenieros o dos runners de CI/CD ejecutan
#      terraform apply al mismo tiempo, ambos leen el mismo estado desactualizado,
#      calculan planes distintos y el segundo apply sobreescribe al primero.
#      El resultado es infraestructura inconsistente y estado corrupto.
#
#   2. PÉRDIDA — si el archivo local se elimina o la máquina falla, Terraform
#      pierde el registro de todos los recursos que administra. La recuperación
#      requiere importar manualmente cada recurso con terraform import.
#
#   3. COLABORACIÓN — ningún otro miembro del equipo ni el pipeline de CI/CD
#      puede gestionar la infraestructura sin acceso al archivo local.
#
# Solución implementada:
#
#   S3 como backend:
#     - Estado almacenado de forma durable con 11 nueves de disponibilidad
#     - Versionado habilitado — permite recuperar versiones anteriores del estado
#     - Cifrado AES-256 en reposo — el tfstate puede contener información sensible
#     - Solo HTTPS — bucket policy niega conexiones HTTP
#
#   DynamoDB para State Locking:
#     - Antes de cualquier operación que modifique el estado (apply, destroy),
#       Terraform escribe un item de bloqueo en DynamoDB con: quién bloqueó,
#       cuándo y qué operación está ejecutando.
#     - Si otro proceso intenta ejecutar simultáneamente, detecta el lock
#       y falla con un mensaje claro indicando quién tiene el lock activo.
#     - Al terminar la operación, Terraform libera el lock automáticamente.
#     - Si el proceso se interrumpe sin liberar el lock:
#       terraform force-unlock <LOCK_ID>
#
# Resultado: múltiples ingenieros y pipelines de CI/CD pueden trabajar
# sobre la misma infraestructura de forma segura y coordinada.
# ==============================================================================

# ------------------------------------------------------------------------------
# S3 Bucket — almacena el terraform.tfstate de forma remota y segura
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = "sre-process-service-tfstate-${data.aws_caller_identity.current.account_id}"

  # force_destroy = false en producción — nunca borrar el estado accidentalmente
  force_destroy = false

  tags = merge(
    { Name = "sre-process-service-tfstate" },
    var.common_tags
  )
}

# Bloquear TODO acceso público — el estado puede contener datos sensibles
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versionado obligatorio — permite recuperar versiones anteriores del estado
# si una operación deja el estado en un punto inconsistente
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Cifrado del estado en reposo — el tfstate puede contener endpoints,
# nombres de recursos y otra información sensible de la infraestructura
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Política S3 — solo HTTPS, nunca HTTP plano
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  depends_on = [aws_s3_bucket_public_access_block.terraform_state]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# DynamoDB Table — State Locking
#
# Terraform escribe un item en esta tabla antes de cualquier operación
# que modifique el estado (plan con -lock, apply, destroy).
# El item contiene: LockID, Who (quién bloqueó), When (cuándo), Info (operación).
# Al terminar la operación, borra el item — liberando el lock.
# Si Terraform se interrumpe sin liberar el lock, se puede liberar manualmente
# con: terraform force-unlock <LOCK_ID>
# ------------------------------------------------------------------------------

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "sre-process-service-tf-locks"
  billing_mode = "PAY_PER_REQUEST" # Sin capacidad provisionada — solo paga por uso
  hash_key     = "LockID"          # Atributo requerido por Terraform para el locking

  attribute {
    name = "LockID"
    type = "S" # String
  }

  # Point-in-time recovery — permite restaurar la tabla a cualquier momento
  # de los últimos 35 días en caso de corrupción accidental
  point_in_time_recovery {
    enabled = true
  }

  # Cifrado en reposo con clave administrada por AWS
  server_side_encryption {
    enabled = true
  }

  tags = merge(
    { Name = "sre-process-service-tf-locks" },
    var.common_tags
  )
}

# ------------------------------------------------------------------------------
# Outputs — información necesaria para configurar el backend block
# ------------------------------------------------------------------------------

output "tfstate_bucket_name" {
  description = "Nombre del bucket S3 donde se almacena el estado remoto de Terraform."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "tfstate_dynamodb_table" {
  description = "Nombre de la tabla DynamoDB para el state locking de Terraform."
  value       = aws_dynamodb_table.terraform_locks.name
}

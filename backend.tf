# ==============================================================================
# backend.tf
# Infraestructura para el Remote State de Terraform
#
# ¿Por qué esto existe? (explicación real)
# Por defecto Terraform guarda el estado en un archivo local terraform.tfstate.
# Eso funciona para un solo desarrollador, pero en un equipo o en producción
# tiene tres problemas críticos:
#
#   1. CONCURRENCIA: si dos personas corren terraform apply al mismo tiempo,
#      los dos leen el mismo estado, hacen cambios distintos y uno sobreescribe
#      al otro — el estado queda corrupto y la infraestructura inconsistente.
#
#   2. PÉRDIDA: si se borra el archivo local o se daña la máquina, Terraform
#      pierde el registro de qué recursos creó. Ya no puede actualizarlos ni
#      destruirlos — hay que importar todo manualmente.
#
#   3. COLABORACIÓN: el archivo local no es visible para el equipo ni para
#      el pipeline de CI/CD — nadie más puede gestionar la infraestructura.
#
# La solución es Remote State:
#   - S3 guarda el archivo de estado de forma durable y centralizada
#   - DynamoDB implementa State Locking: antes de cualquier operación,
#     Terraform escribe un registro de bloqueo en DynamoDB. Si otro proceso
#     intenta correr al mismo tiempo, ve el lock y espera o falla con error
#     claro — nunca hay dos applies simultáneos.
#
# Analogía: es como Google Docs vs un archivo Word en el escritorio.
# Google Docs permite que varios editen, tiene historial, y si se rompe
# el computador el documento sigue ahí. El Word local no tiene nada de eso.
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

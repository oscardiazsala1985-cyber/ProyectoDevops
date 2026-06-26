# ==============================================================================
# monitoring.tf
# Grafana en EC2 — Herramienta de monitoreo visual con dashboards
# Cubre punto 10 del reto: Monitoreo y Optimización de Rendimiento
#
# # Imagina que todos los datos de CloudWatch son como números en una hoja de Excel.
# Grafana los convierte en gráficos bonitos y dashboards visuales en tiempo real.
# Puedes ver CPU, memoria, errores, latencia — todo en una sola pantalla web.
#
# Arquitectura:
#   Internet → ALB (puerto 3000) → EC2 Grafana (subnet privada) → CloudWatch API
#   El acceso es seguro: Grafana está en subnet privada, solo accesible via ALB.
# ==============================================================================

# ------------------------------------------------------------------------------
# Variables de Grafana
# ------------------------------------------------------------------------------

variable "grafana_instance_type" {
  description = "Tipo de instancia EC2 para el servidor Grafana."
  type        = string
  default     = "t3.small" # t3.small es suficiente para Grafana en dev/pruebas
}

variable "grafana_admin_password" {
  description = "Contraseña del administrador de Grafana. Pasar via TF_VAR_grafana_admin_password."
  type        = string
  sensitive   = true
  default     = "GrafanaAdmin2026!"
  # En producción: export TF_VAR_grafana_admin_password="password-seguro"
}

# ------------------------------------------------------------------------------
# Security Group — Grafana EC2
# Egress: necesita salir a Internet para llamar a la API de CloudWatch
# ------------------------------------------------------------------------------

resource "aws_security_group" "grafana" {
  name        = "${local.name}-grafana-sg"
  description = "Grafana SG: ingress solo desde ALB en 3000, egress HTTPS para CloudWatch API."
  vpc_id      = aws_vpc.main.id

  tags = merge({ Name = "${local.name}-grafana-sg" }, var.common_tags)
}

resource "aws_security_group_rule" "grafana_ingress_alb" {
  type                     = "ingress"
  description              = "Grafana UI desde ALB en puerto 3000"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.grafana.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "grafana_egress_https" {
  type              = "egress"
  description       = "HTTPS para CloudWatch API y updates de paquetes via NAT"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.grafana.id
}

resource "aws_security_group_rule" "grafana_egress_http" {
  type              = "egress"
  description       = "HTTP para descarga de paquetes"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.grafana.id
}

# Regla en el ALB SG: permite reenviar tráfico al puerto 3000 de Grafana
resource "aws_security_group_rule" "alb_egress_grafana" {
  type                     = "egress"
  description              = "ALB a Grafana en puerto 3000"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.grafana.id
}

# ------------------------------------------------------------------------------
# IAM Role para Grafana EC2
# Solo lectura — nunca puede modificar ni eliminar métricas
# ------------------------------------------------------------------------------

resource "aws_iam_role" "grafana" {
  name = "${local.name}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge({ Name = "${local.name}-grafana-role" }, var.common_tags)
}

# CloudWatch: solo lectura de métricas y logs — mínimo privilegio
resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "${local.name}-grafana-cloudwatch-policy"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchReadOnly"
        Effect = "Allow"
        Action = [
          # Métricas
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetInsightRuleReport",
          # Logs
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogGroupFields",
          # Información de la cuenta para dashboards
          "ec2:DescribeTags",
          "ec2:DescribeInstances",
          "ec2:DescribeRegions"
        ]
        Resource = "*"
      }
    ]
  })
}

# SSM para acceso seguro a la instancia sin SSH
resource "aws_iam_role_policy_attachment" "grafana_ssm" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "grafana" {
  name = "${local.name}-grafana-profile"
  role = aws_iam_role.grafana.name

  tags = merge({ Name = "${local.name}-grafana-profile" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# CloudWatch Log Group para logs de Grafana
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/aws/ec2/${local.name}-grafana"
  retention_in_days = var.log_retention_days

  tags = merge({ Name = "${local.name}-grafana-logs" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# EC2 Instance — Servidor Grafana
# El user_data es un script que se ejecuta automáticamente al arrancar la instancia
# e instala y configura Grafana sin intervención manual.
# ------------------------------------------------------------------------------

resource "aws_instance" "grafana" {
  ami                    = var.ec2_ami_id           # Amazon Linux 2023
  instance_type          = var.grafana_instance_type
  subnet_id              = aws_subnet.private[0].id  # Subnet privada — sin IP pública
  vpc_security_group_ids = [aws_security_group.grafana.id]
  iam_instance_profile   = aws_iam_instance_profile.grafana.name

  # IMDSv2 obligatorio — previene ataques SSRF al metadata service
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Monitoreo detallado de CloudWatch habilitado
  monitoring = true

  # Script de instalación automática de Grafana
    # que instala Grafana, lo configura con CloudWatch y lo arranca como servicio
  user_data = base64encode(templatefile("${path.module}/templates/grafana_setup.sh.tpl", {
    grafana_admin_password = var.grafana_admin_password
    aws_region             = var.aws_region
    project_name           = local.name
    cloudwatch_log_group   = aws_cloudwatch_log_group.grafana.name
    alb_dns_name           = aws_lb.app.dns_name
  }))

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true

    tags = merge({ Name = "${local.name}-grafana-vol" }, var.common_tags)
  }

  depends_on = [
    aws_iam_instance_profile.grafana,
    aws_cloudwatch_log_group.grafana
  ]

  tags = merge({ Name = "${local.name}-grafana" }, var.common_tags)

  lifecycle {
    ignore_changes = [user_data] # No recrear si cambia el script después del deploy inicial
  }
}

# ------------------------------------------------------------------------------
# ALB Target Group para Grafana — puerto 3000
# El health check verifica que Grafana esté respondiendo correctamente
# ------------------------------------------------------------------------------

resource "aws_lb_target_group" "grafana" {
  name        = "${var.environment}-grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/api/health"   # Endpoint de health nativo de Grafana
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge({ Name = "${local.name}-grafana-tg" }, var.common_tags)
}

# Registrar la instancia Grafana en el Target Group
resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = aws_instance.grafana.id
  port             = 3000
}

# ------------------------------------------------------------------------------
# ALB Listener Rule — enruta /grafana/* al Target Group de Grafana
# Si la URL contiene /grafana, el ALB envía la petición al servidor Grafana
# Esto evita tener que crear un ALB adicional (ahorro de costos)
# ------------------------------------------------------------------------------

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10  # Prioridad alta — se evalúa antes que la regla por defecto

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    path_pattern {
      values = ["/grafana", "/grafana/*"]
    }
  }

  tags = merge({ Name = "${local.name}-grafana-rule" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# CloudWatch Dashboard — Panel visual de toda la arquitectura
# CPU de las EC2, errores de Lambda, conexiones a RDS, hits del caché Redis
# Este dashboard se crea automáticamente con Terraform
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# SRE Process Service — Dashboard\n**Proyecto:** ${local.name} | **Región:** ${var.aws_region} | **Ambiente:** ${var.environment}"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "Lambda — Invocaciones"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [["AWS/Lambda", "Invocations", "FunctionName", "${local.name}-processor", { "stat" = "Sum", "period" = 60 }]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "Lambda — Errores"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [["AWS/Lambda", "Errors", "FunctionName", "${local.name}-processor", { "stat" = "Sum", "color" = "#d62728" }]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "Lambda — Duración (ms)"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [["AWS/Lambda", "Duration", "FunctionName", "${local.name}-processor", { "stat" = "Average" }]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 8
        height = 6
        properties = {
          title   = "EC2 ASG — CPU %"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", "${local.name}-asg", { "stat" = "Average", "color" = "#ff7f0e" }]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 8
        width  = 8
        height = 6
        properties = {
          title   = "ALB — Peticiones y Errores 5xx"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "${aws_lb.app.arn_suffix}", { "stat" = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", "${aws_lb.app.arn_suffix}", { "stat" = "Sum", "color" = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 8
        width  = 8
        height = 6
        properties = {
          title   = "ALB — Latencia p99 (ms)"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${aws_lb.app.arn_suffix}", { "stat" = "p50", "label" = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${aws_lb.app.arn_suffix}", { "stat" = "p99", "label" = "p99", "color" = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 8
        height = 6
        properties = {
          title   = "RDS — CPU y Conexiones"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${local.name}-db", { "stat" = "Average" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${local.name}-db", { "stat" = "Average" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 14
        width  = 8
        height = 6
        properties = {
          title   = "RDS — Storage libre"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", "${local.name}-db", { "stat" = "Average" }]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 14
        width  = 8
        height = 6
        properties = {
          title   = "Redis — Cache HITs vs MISSes"
          view    = "timeSeries"
          region  = var.aws_region
          metrics = [
            ["AWS/ElastiCache", "CacheHits", "CacheClusterId", "${local.name}-redis", { "stat" = "Sum", "color" = "#2ca02c", "label" = "HITs" }],
            ["AWS/ElastiCache", "CacheMisses", "CacheClusterId", "${local.name}-redis", { "stat" = "Sum", "color" = "#d62728", "label" = "MISSes" }]
          ]
        }
      }
    ]
  })
}

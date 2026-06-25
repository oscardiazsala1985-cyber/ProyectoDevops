# ==============================================================================
# ec2_compute.tf
# Application Load Balancer (ALB) + Auto Scaling Group (ASG) con EC2
# Alta disponibilidad en subnets públicas (ALB) y privadas (EC2)
# ==============================================================================

# ------------------------------------------------------------------------------
# Variables nuevas para el módulo de cómputo EC2
# ------------------------------------------------------------------------------

variable "ec2_instance_type" {
  description = "Tipo de instancia EC2 para el ASG."
  type        = string
  default     = "t3.micro"
}

variable "ec2_ami_id" {
  description = "AMI ID para las instancias EC2 (Amazon Linux 2023 en us-east-1)."
  type        = string
  default     = "ami-0c02fb55956c7d316" # Amazon Linux 2023 us-east-1
}

variable "asg_min_size" {
  description = "Número mínimo de instancias en el ASG."
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Número máximo de instancias en el ASG."
  type        = number
  default     = 4
}

variable "asg_desired_capacity" {
  description = "Capacidad deseada del ASG."
  type        = number
  default     = 2
}

# ------------------------------------------------------------------------------
# Security Group — Application Load Balancer
# Acepta tráfico HTTP/HTTPS desde Internet
# ------------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB SG: HTTP/HTTPS ingress from Internet, egress to EC2 app tier."
  vpc_id      = aws_vpc.main.id

  tags = merge({ Name = "${local.name}-alb-sg" }, var.common_tags)
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  description       = "HTTP from Internet"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  description       = "HTTPS from Internet"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_ec2" {
  type                     = "egress"
  description              = "Forward traffic to EC2 app tier on port 8080"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.ec2_app.id
}

# ------------------------------------------------------------------------------
# Security Group — EC2 App Tier
# Acepta tráfico solo desde el ALB; egress a Redis y HTTPS para AWS APIs
# ------------------------------------------------------------------------------

resource "aws_security_group" "ec2_app" {
  name        = "${local.name}-ec2-app-sg"
  description = "EC2 app tier: ingress from ALB, egress to Redis and HTTPS."
  vpc_id      = aws_vpc.main.id

  tags = merge({ Name = "${local.name}-ec2-app-sg" }, var.common_tags)
}

resource "aws_security_group_rule" "ec2_ingress_alb" {
  type                     = "ingress"
  description              = "App traffic from ALB only"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ec2_app.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "ec2_egress_https" {
  type              = "egress"
  description       = "HTTPS egress for AWS APIs and NAT"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2_app.id
}

resource "aws_security_group_rule" "ec2_egress_redis" {
  type                     = "egress"
  description              = "EC2 to Redis on 6379"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ec2_app.id
  source_security_group_id = aws_security_group.redis.id
}

# Permitir que el Redis SG acepte conexiones desde EC2 App SG
resource "aws_security_group_rule" "redis_ingress_ec2" {
  type                     = "ingress"
  description              = "Redis from EC2 app tier"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.ec2_app.id
}

# ------------------------------------------------------------------------------
# Application Load Balancer (ALB) — subnets PÚBLICAS
# ------------------------------------------------------------------------------

resource "aws_lb" "app" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = merge({ Name = "${local.name}-alb" }, var.common_tags)
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge({ Name = "${local.name}-tg" }, var.common_tags)
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = merge({ Name = "${local.name}-http-listener" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# IAM Instance Profile para EC2 — permite SSM, CloudWatch, X-Ray
# (los roles y políticas de observabilidad están en observability.tf)
# ------------------------------------------------------------------------------

resource "aws_iam_instance_profile" "ec2_app" {
  name = "${local.name}-ec2-app-profile"
  role = aws_iam_role.ec2_app.name

  tags = merge({ Name = "${local.name}-ec2-app-profile" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# Launch Template para el ASG
# ------------------------------------------------------------------------------

resource "aws_launch_template" "app" {
  name_prefix   = "${local.name}-app-lt-"
  image_id      = var.ec2_ami_id
  instance_type = var.ec2_instance_type

  vpc_security_group_ids = [aws_security_group.ec2_app.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2_app.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Requiere IMDSv2 por seguridad
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true # Monitoreo detallado de CloudWatch
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    # Instalar agente de CloudWatch y AWS CLI
    yum install -y amazon-cloudwatch-agent aws-xray-daemon
    # Arrancar el daemon de X-Ray
    systemctl enable aws-xray-daemon
    systemctl start aws-xray-daemon
    # Variables de entorno de la aplicación
    echo "REDIS_HOST=${aws_elasticache_cluster.redis.cache_nodes[0].address}" >> /etc/environment
    echo "REDIS_PORT=6379" >> /etc/environment
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = "${local.name}-app-ec2" }, var.common_tags)
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge({ Name = "${local.name}-app-ec2-vol" }, var.common_tags)
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge({ Name = "${local.name}-app-lt" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# Auto Scaling Group (ASG) — subnets PRIVADAS
# ------------------------------------------------------------------------------

resource "aws_autoscaling_group" "app" {
  name                = "${local.name}-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = aws_subnet.private[*].id

  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-app-ec2"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_lb_target_group.app,
    aws_iam_instance_profile.ec2_app
  ]
}

# ------------------------------------------------------------------------------
# Auto Scaling Policy — CPU-based Target Tracking
# ------------------------------------------------------------------------------

resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.name}-cpu-target-policy"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

# ==============================================================================
# observability.tf
# CloudWatch Logs + AWS X-Ray — bajo principio de mínimo privilegio
# Cubre: Lambda (existente) y EC2 App Tier (nuevo)
# ==============================================================================

# ------------------------------------------------------------------------------
# IAM Role — EC2 App Tier
# Asume el rol en las instancias del ASG via Instance Profile
# Permisos: SSM (acceso sin SSH), CloudWatch Agent, X-Ray, S3 (lectura bucket)
# ------------------------------------------------------------------------------

resource "aws_iam_role" "ec2_app" {
  name = "${local.name}-ec2-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge({ Name = "${local.name}-ec2-app-role" }, var.common_tags)
}

# SSM Session Manager — acceso seguro sin abrir puerto 22
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent en EC2 — envío de métricas y logs del sistema operativo
resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_agent" {
  role       = aws_iam_role.ec2_app.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Política inline — X-Ray desde EC2 (mínimo privilegio: solo PutTraceSegments/PutTelemetryRecords)
resource "aws_iam_role_policy" "ec2_xray" {
  name = "${local.name}-ec2-xray-policy"
  role = aws_iam_role.ec2_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
          "xray:GetSamplingStatisticSummaries"
        ]
        Resource = "*"
      }
    ]
  })
}

# Política inline — CloudWatch Logs desde EC2 (scope limitado al grupo de logs de la app)
resource "aws_iam_role_policy" "ec2_cloudwatch_logs" {
  name = "${local.name}-ec2-cw-logs-policy"
  role = aws_iam_role.ec2_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsEC2"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/${local.name}*",
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/${local.name}*:*"
        ]
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# CloudWatch Log Groups — EC2 App Tier
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ec2_app" {
  name              = "/aws/ec2/${local.name}-app"
  retention_in_days = var.log_retention_days

  tags = merge({ Name = "${local.name}-ec2-app-logs" }, var.common_tags)
}

resource "aws_cloudwatch_log_group" "ec2_system" {
  name              = "/aws/ec2/${local.name}-system"
  retention_in_days = var.log_retention_days

  tags = merge({ Name = "${local.name}-ec2-system-logs" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# Política inline — X-Ray para Lambda (añadida al rol existente aws_iam_role.lambda_exec)
# Mínimo privilegio: solo trazas y sampling, sin acceso a datos de otras trazas
# ------------------------------------------------------------------------------

resource "aws_iam_role_policy" "lambda_xray" {
  name = "${local.name}-lambda-xray-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayTracingLambda"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
          "xray:GetSamplingStatisticSummaries"
        ]
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# Política inline — CloudWatch Logs adicional para Lambda
# (AWSLambdaBasicExecutionRole ya otorga logs:CreateLogGroup/Stream/PutLogEvents
#  a nivel global; esta policy acota permisos a sus grupos específicos)
# ------------------------------------------------------------------------------

resource "aws_iam_role_policy" "lambda_cloudwatch_logs" {
  name = "${local.name}-lambda-cw-logs-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsLambda"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.name}*",
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.name}*:*"
        ]
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# CloudWatch Alarm — ALB 5xx errors (observabilidad end-to-end)
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB 5xx error rate exceeded threshold."
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }

  tags = merge({ Name = "${local.name}-alb-5xx-alarm" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# CloudWatch Alarm — ASG CPU alto
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  alarm_name          = "${local.name}-asg-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ASG average CPU above 80% for 3 minutes."
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  tags = merge({ Name = "${local.name}-asg-cpu-alarm" }, var.common_tags)
}

# ------------------------------------------------------------------------------
# CloudWatch Alarm — Lambda errores
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda function error count exceeded threshold."
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.processor.function_name
  }

  tags = merge({ Name = "${local.name}-lambda-errors-alarm" }, var.common_tags)
}

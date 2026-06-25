output "api_process_url" {
  description = "Public HTTP API endpoint for POST /process."
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/process"
}

output "results_bucket_name" {
  description = "Private S3 bucket where Lambda stores processed results."
  value       = aws_s3_bucket.results.bucket
}

output "redis_endpoint" {
  description = "Private Redis endpoint."
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "alb_dns_name" {
  description = "DNS público del Application Load Balancer."
  value       = aws_lb.app.dns_name
}

output "alb_arn" {
  description = "ARN del Application Load Balancer."
  value       = aws_lb.app.arn
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group."
  value       = aws_autoscaling_group.app.name
}

output "rds_endpoint" {
  description = "Endpoint privado de la instancia RDS."
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "Puerto de conexión de la instancia RDS."
  value       = aws_db_instance.main.port
}

output "ec2_app_role_arn" {
  description = "ARN del IAM role asignado a las instancias EC2 del ASG."
  value       = aws_iam_role.ec2_app.arn
}

output "ec2_log_group" {
  description = "Nombre del log group de CloudWatch para la app EC2."
  value       = aws_cloudwatch_log_group.ec2_app.name
}

output "cloudtrail_name" {
  description = "Nombre del trail de AWS CloudTrail activo."
  value       = aws_cloudtrail.main.name
}

output "cloudtrail_s3_bucket" {
  description = "Bucket S3 donde se almacenan los logs de auditoría de CloudTrail."
  value       = aws_s3_bucket.cloudtrail_logs.bucket
}

output "cloudtrail_log_group" {
  description = "Log Group de CloudWatch para búsqueda en tiempo real de eventos CloudTrail."
  value       = aws_cloudwatch_log_group.cloudtrail.name
}

output "guardduty_detector_id" {
  description = "ID del detector de Amazon GuardDuty."
  value       = aws_guardduty_detector.main.id
}

output "security_alerts_sns_arn" {
  description = "ARN del SNS Topic para alertas de seguridad (GuardDuty + CloudTrail)."
  value       = aws_sns_topic.security_alerts.arn
}

output "backup_vault_name" {
  description = "Nombre del vault de AWS Backup donde se almacenan los backups."
  value       = aws_backup_vault.main.name
}

output "backup_plan_id" {
  description = "ID del plan de backup (diario + semanal)."
  value       = aws_backup_plan.main.id
}

output "grafana_url" {
  description = "URL pública de Grafana via ALB. Usuario: admin"
  value       = "http://${aws_lb.app.dns_name}/grafana"
}

output "grafana_instance_id" {
  description = "ID de la instancia EC2 donde corre Grafana."
  value       = aws_instance.grafana.id
}

output "cloudwatch_dashboard_url" {
  description = "URL del dashboard de CloudWatch con métricas de toda la arquitectura."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${local.name}-overview"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.terraform/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-processor"
  retention_in_days = var.log_retention_days
  
  
  tags = merge({ Name = "${local.name}-lambda-logs" }, var.common_tags)
}

resource "aws_lambda_function" "processor" {
  function_name    = "${local.name}-processor"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active" # Habilita X-Ray end-to-end tracing en cada invocación
  }

  environment {
    variables = {
      BUCKET_NAME       = aws_s3_bucket.results.bucket
      REDIS_HOST        = aws_elasticache_cluster.redis.cache_nodes[0].address
      REDIS_PORT        = "6379"
      REDIS_TTL_SECONDS = tostring(var.redis_ttl_seconds)
      DB_HOST           = aws_db_instance.main.address
      DB_PORT           = tostring(aws_db_instance.main.port)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy.lambda_s3,
    aws_elasticache_cluster.redis,
    aws_db_instance.main
  ]

  
  tags = merge({ Name = "${local.name}-processor" }, var.common_tags)
}
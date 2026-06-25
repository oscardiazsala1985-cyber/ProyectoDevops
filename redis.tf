resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name}-redis-subnets"
  subnet_ids = aws_subnet.private[*].id
  
  
  tags = merge({ Name = "${local.name}-redis-subnets" }, var.common_tags)
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = substr(replace("${local.name}-redis", "_", "-"), 0, 40)
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  
  
  num_cache_nodes      = 1 
  
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]

  
  snapshot_retention_limit = 1
  snapshot_window          = "03:00-04:00"
  maintenance_window       = "sun:04:00-sun:05:00"

  apply_immediately = true
  
  
  tags = merge({ Name = "${local.name}-redis" }, var.common_tags)
}
locals {
  name = "${var.project_name}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  
  tags = merge({ Name = "${local.name}-vpc" }, var.common_tags)
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.main.id
  tags   = merge({ Name = "${local.name}-igw" }, var.common_tags)
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    { 
      Name = "${local.name}-public-${count.index + 1}"
      Tier = "public"
    }, 
    var.common_tags
  )
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    { 
      Name = "${local.name}-private-${count.index + 1}"
      Tier = "private"
    }, 
    var.common_tags
  )
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge({ Name = "${local.name}-nat-eip" }, var.common_tags)

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge({ Name = "${local.name}-nat" }, var.common_tags)

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge({ Name = "${local.name}-public-rt" }, var.common_tags)
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id
  tags   = merge({ Name = "${local.name}-private-rt-${count.index + 1}" }, var.common_tags)
}

resource "aws_route" "private_nat" {
  count                  = 2
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge({ Name = "${local.name}-s3-gateway-endpoint" }, var.common_tags)
}

# ==========================================
#  Desacoplamiento de Security Groups
# ==========================================

resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda-sg"
  description = "Lambda SG. Egress to Redis on 6379 and HTTPS for AWS APIs."
  vpc_id      = aws_vpc.main.id
  tags        = merge({ Name = "${local.name}-lambda-sg" }, var.common_tags)
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis-sg"
  description = "Redis accepts connections only from Lambda SG on 6379."
  vpc_id      = aws_vpc.main.id
  tags        = merge({ Name = "${local.name}-redis-sg" }, var.common_tags)
}

# Reglas de Lambda SG
resource "aws_security_group_rule" "lambda_egress_redis" {
  type                     = "egress"
  description              = "Redis access only from Lambda to Redis SG"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda.id
  source_security_group_id = aws_security_group.redis.id
}

resource "aws_security_group_rule" "lambda_egress_https" {
  type              = "egress"
  description       = "HTTPS egress for AWS APIs through NAT when endpoint is not available"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.lambda.id
}

# Reglas de Redis SG
resource "aws_security_group_rule" "redis_ingress_lambda" {
  type                     = "ingress"
  description              = "Redis from Lambda only"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.lambda.id
}
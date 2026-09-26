resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.project_name}-redis-subnet"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name        = "${var.project_name}-redis-subnet"
    Project     = "SolidaryTech"
    Environment = var.environment
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
  }
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.project_name}-redis-"
  vpc_id      = var.vpc_id
  description = "Security group for ElastiCache Redis"

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = compact([var.eks_node_sg_id, var.eks_cluster_sg_id])
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-redis-sg"
    Project     = "SolidaryTech"
    Environment = var.environment
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
  }
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project_name}-redis"
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = var.node_type
  num_cache_nodes      = 1
  port                 = 6379
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]

  snapshot_retention_limit = 1

  tags = {
    Name        = "${var.project_name}-redis"
    Project     = "SolidaryTech"
    Environment = var.environment
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
  }
}

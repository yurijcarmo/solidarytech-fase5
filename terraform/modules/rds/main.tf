# --- DB Subnet Group ---

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# --- Security Group ---

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

resource "aws_security_group_rule" "rds_ingress" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = var.eks_node_sg_id
  security_group_id        = aws_security_group.rds.id
}

resource "aws_security_group_rule" "rds_ingress_cluster_sg" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = var.eks_cluster_sg_id
  security_group_id        = aws_security_group.rds.id
}

resource "aws_security_group_rule" "rds_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
}

# --- Parameter Group ---

resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-pg15-params"
  family = "postgres15"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  tags = {
    Name = "${var.project_name}-pg15-params"
  }
}

# --- RDS Instance (Standalone - Production) ---

resource "aws_db_instance" "main" {
  count = var.is_read_replica ? 0 : 1

  identifier = "${var.project_name}-postgres"

  engine                = "postgres"
  engine_version        = "15"
  instance_class        = var.db_instance_class
  allocated_storage     = 20
  max_allocated_storage = 50
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  multi_az            = false
  publicly_accessible = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-final-snapshot"
  deletion_protection       = true

  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = {
    Name    = "${var.project_name}-postgres"
    Service = "database"
  }
}

# --- RDS Instance (Read Replica - DR) ---

resource "aws_db_instance" "replica" {
  count = var.is_read_replica ? 1 : 0

  identifier          = "${var.project_name}-postgres"
  replicate_source_db = var.source_db_arn
  instance_class      = var.db_instance_class

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  storage_encrypted   = true
  publicly_accessible = false
  multi_az            = false

  skip_final_snapshot = true
  deletion_protection = false

  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = {
    Name    = "${var.project_name}-postgres-replica"
    Service = "database"
    Role    = "read-replica"
  }
}

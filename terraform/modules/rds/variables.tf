variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for DB subnet group"
  type        = list(string)
}

variable "eks_node_sg_id" {
  description = "EKS node security group ID (allowed to access RDS)"
  type        = string
}

variable "eks_cluster_sg_id" {
  description = "EKS-managed cluster security group ID (pods use this SG)"
  type        = string
}

variable "db_name" {
  description = "Database name"
  type        = string
}

variable "db_username" {
  description = "Database master username"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "is_read_replica" {
  description = "Whether this instance is a cross-region read replica"
  type        = bool
  default     = false
}

variable "source_db_arn" {
  description = "ARN of the source DB for cross-region read replica"
  type        = string
  default     = ""
}

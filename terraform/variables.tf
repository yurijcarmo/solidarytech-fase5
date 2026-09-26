variable "aws_region" {
  description = "AWS region for primary deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (production, staging, dr)"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "solidarytech"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.29"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "solidarytech"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "solidarytech_admin"
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL master password"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "eks_cluster_role_name" {
  description = "IAM role name for EKS cluster (pre-existing in AWS Academy)"
  type        = string
  default     = "LabRole"
}

variable "eks_node_role_name" {
  description = "IAM role name for EKS node group (pre-existing in AWS Academy)"
  type        = string
  default     = "LabRole"
}

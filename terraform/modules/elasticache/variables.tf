variable "project_name" {
  description = "Project name for resource naming"
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
  description = "Private subnet IDs for Redis subnet group"
  type        = list(string)
}

variable "eks_node_sg_id" {
  description = "EKS node security group ID"
  type        = string
}

variable "eks_cluster_sg_id" {
  description = "EKS cluster security group ID (pods use this SG)"
  type        = string
  default     = ""
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

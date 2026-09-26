variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "solidarytech"
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

variable "eks_cluster_role_name" {
  description = "IAM role name for EKS cluster (pre-existing in AWS Academy)"
  type        = string
}

variable "eks_node_role_name" {
  description = "IAM role name for EKS node group (pre-existing in AWS Academy)"
  type        = string
}

variable "tf_state_bucket" {
  description = "S3 bucket name for Terraform state"
  type        = string
  default     = ""
}

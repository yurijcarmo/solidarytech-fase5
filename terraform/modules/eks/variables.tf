variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for node group"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs"
  type        = list(string)
}

variable "node_instance_type" {
  description = "EC2 instance type for nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count"
  type        = number
  default     = 4
}

variable "cluster_log_types" {
  description = "EKS cluster log types to enable (may be blocked by Academy SCP)"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to access EKS API server publicly"
  type        = list(string)
  default     = ["0.0.0.0/0"]
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

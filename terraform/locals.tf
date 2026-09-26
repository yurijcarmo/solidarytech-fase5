locals {
  cluster_name = "${var.project_name}-eks-${var.environment}"

  common_tags = {
    Project     = "SolidaryTech"
    Environment = var.environment
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
  }

  name_prefix = "${var.project_name}-${var.environment}"
}

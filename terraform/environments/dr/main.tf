terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "solidarytech-terraform-state"
    key     = "environments/dr/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "dr"
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
      DRRegion    = "true"
    }
  }
}

# Em producao real, usar terraform_remote_state para referenciar
# o RDS primario e criar um Read Replica cross-region.
# No AWS Academy, esta funcionalidade e bloqueada por IAM.

# --- DR VPC in us-west-2 ---

module "vpc" {
  source = "../../modules/vpc"

  project_name = var.project_name
  environment  = "dr"
  aws_region   = var.aws_region
  vpc_cidr     = "10.1.0.0/16"
  cluster_name = "${var.project_name}-eks-dr"
}

# --- DR EKS Cluster (Warm Standby - 1 node always running) ---

module "eks" {
  source = "../../modules/eks"

  project_name          = var.project_name
  environment           = "dr"
  cluster_name          = "${var.project_name}-eks-dr"
  kubernetes_version    = "1.36"
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  public_subnet_ids     = module.vpc.public_subnet_ids
  node_instance_type    = "t3.medium"
  node_desired_size     = 1
  node_min_size         = 1
  node_max_size         = 3
  eks_cluster_role_name = var.eks_cluster_role_name
  eks_node_role_name    = var.eks_node_role_name
}

# --- DR RDS (Cross-Region Read Replica from production) ---
# A replica sincroniza automaticamente com o RDS primario.
# No failover, basta promover para standalone com:
#   aws rds promote-read-replica --db-instance-identifier solidarytech-dr-postgres

# AWS Academy nao permite rds:CreateDBInstanceReadReplica cross-region.
# Em producao real, usar is_read_replica = true com source_db_arn.
# No Academy, criamos um RDS standalone que simula o DR.
module "rds" {
  source = "../../modules/rds"

  project_name       = "${var.project_name}-dr"
  environment        = "dr"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  eks_cluster_sg_id  = module.eks.eks_cluster_security_group_id
  db_name            = "solidarytech"
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = "db.t3.micro"
  is_read_replica    = false
}

# --- DR SQS (independente, ativada no failover) ---

module "sqs" {
  source = "../../modules/sqs"

  project_name = "${var.project_name}-dr"
  environment  = "dr"
}

# ECR removido: DR usa imagens do ECR de us-east-1
# EKS nodes com LabEksNodeRole tem permissao para pull cross-region

# --- Outputs ---

output "dr_eks_cluster_endpoint" {
  description = "DR EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "dr_eks_cluster_name" {
  description = "DR EKS cluster name"
  value       = module.eks.cluster_name
}

output "dr_rds_endpoint" {
  description = "DR RDS endpoint (read replica)"
  value       = module.rds.endpoint
}

output "dr_sqs_queue_url" {
  description = "DR SQS donations queue URL"
  value       = module.sqs.donations_queue_url
}

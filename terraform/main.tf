terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend configurado dinamicamente pelo scripts/deploy.sh
  # Para uso manual: terraform init -backend-config="bucket=solidarytech-terraform-state-ACCOUNT_ID" -backend-config="key=production/terraform.tfstate" -backend-config="region=us-east-1"
  # Nota: DynamoDB lock table removido por incompatibilidade com AWS Academy Learner Lab
  backend "s3" {
    bucket  = "solidarytech-terraform-state"
    key     = "production/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = var.environment
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
    }
  }
}

module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_cidr     = var.vpc_cidr
  cluster_name = local.cluster_name
}

module "eks" {
  source = "./modules/eks"

  project_name          = var.project_name
  environment           = var.environment
  cluster_name          = local.cluster_name
  kubernetes_version    = var.kubernetes_version
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  public_subnet_ids     = module.vpc.public_subnet_ids
  node_instance_type    = var.node_instance_type
  node_desired_size     = var.node_desired_size
  node_min_size         = var.node_min_size
  node_max_size         = var.node_max_size
  eks_cluster_role_name = var.eks_cluster_role_name
  eks_node_role_name    = var.eks_node_role_name
}

module "rds" {
  source = "./modules/rds"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = var.db_instance_class
}

module "sqs" {
  source = "./modules/sqs"

  project_name = var.project_name
  environment  = var.environment
}

module "s3" {
  source = "./modules/s3"

  project_name = var.project_name
  environment  = var.environment
}

module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  services     = ["ngo-service", "donation-service", "volunteer-service"]
}

module "dynamodb" {
  source = "./modules/dynamodb"

  project_name = var.project_name
  environment  = var.environment
}

module "elasticache" {
  source = "./modules/elasticache"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  node_type          = var.redis_node_type
}

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
    key     = "environments/production/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "production"
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project_name = var.project_name
  environment  = "production"
  aws_region   = var.aws_region
  vpc_cidr     = "10.0.0.0/16"
  cluster_name = "${var.project_name}-eks-production"
}

module "eks" {
  source = "../../modules/eks"

  project_name          = var.project_name
  environment           = "production"
  cluster_name          = "${var.project_name}-eks-production"
  kubernetes_version    = "1.36"
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  public_subnet_ids     = module.vpc.public_subnet_ids
  node_instance_type    = "t3.medium"
  node_desired_size     = 2
  node_min_size         = 1
  node_max_size         = 5
  eks_cluster_role_name = var.eks_cluster_role_name
  eks_node_role_name    = var.eks_node_role_name
}

module "rds" {
  source = "../../modules/rds"

  project_name       = var.project_name
  environment        = "production"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  eks_cluster_sg_id  = module.eks.eks_cluster_security_group_id
  db_name            = "solidarytech"
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = "db.t3.micro"
}

module "sqs" {
  source = "../../modules/sqs"

  project_name = var.project_name
  environment  = "production"
}

module "elasticache" {
  source = "../../modules/elasticache"

  project_name       = var.project_name
  environment        = "production"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  eks_cluster_sg_id  = module.eks.eks_cluster_security_group_id
  node_type          = "cache.t3.micro"
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  project_name = var.project_name
  environment  = "production"
}

# S3 backup bucket removido: AWS Academy SCP bloqueia s3:GetBucketObjectLockConfiguration
# ECR removido: repositorios ja criados pelo deploy.sh (evita RepositoryAlreadyExistsException)

# --- Outputs ---

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "rds_arn" {
  value = module.rds.arn
}

output "sqs_donations_queue_url" {
  value = module.sqs.donations_queue_url
}

output "redis_url" {
  value = module.elasticache.redis_url
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

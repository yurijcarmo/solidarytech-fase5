# --- IAM Roles (pre-existing in AWS Academy Learner Lab) ---
# Os nomes dos roles no Academy Lab possuem prefixos dinamicos,
# por isso usamos variaveis para permitir configuracao flexivel.

data "aws_iam_role" "lab_eks_cluster" {
  name = var.eks_cluster_role_name
}

data "aws_iam_role" "lab_node" {
  name = var.eks_node_role_name
}

# --- EKS Cluster Security Group ---

resource "aws_security_group" "cluster" {
  name_prefix = "${var.project_name}-eks-cluster-"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-eks-cluster-sg"
  }
}

resource "aws_security_group_rule" "cluster_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
}

# --- EKS Cluster ---

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = data.aws_iam_role.lab_eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.eks_public_access_cidrs
  }

  enabled_cluster_log_types = var.cluster_log_types

  tags = {
    Name = var.cluster_name
  }
}

# --- Node Group Security Group ---

resource "aws_security_group" "node" {
  name_prefix = "${var.project_name}-eks-node-"
  description = "EKS node security group"
  vpc_id      = var.vpc_id

  tags = {
    Name                                        = "${var.project_name}-eks-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

resource "aws_security_group_rule" "node_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_from_cluster" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "cluster_from_node" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster.id
}

# --- Load Balancer Security Group (HTTPS only) ---

resource "aws_security_group" "lb" {
  name_prefix = "${var.project_name}-eks-lb-"
  description = "Security group for EKS Load Balancer - HTTPS only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-eks-lb-sg"
  }
}

resource "aws_security_group_rule" "lb_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow HTTPS from anywhere"
  security_group_id = aws_security_group.lb.id
}

resource "aws_security_group_rule" "lb_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow HTTP (redirect to HTTPS)"
  security_group_id = aws_security_group.lb.id
}

resource "aws_security_group_rule" "lb_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.lb.id
}

resource "aws_security_group_rule" "node_from_lb" {
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lb.id
  description              = "Allow traffic from LB to NodePort range"
  security_group_id        = aws_security_group.node.id
}

# --- Managed Node Group ---

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-node-group"
  node_role_arn   = data.aws_iam_role.lab_node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role        = "worker"
    environment = var.environment
  }

  tags = {
    Name                                            = "${var.project_name}-eks-node"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }
}

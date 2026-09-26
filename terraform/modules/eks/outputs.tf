output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_certificate_authority" {
  description = "EKS cluster CA certificate (base64)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "EKS node security group ID"
  value       = aws_security_group.node.id
}

output "eks_cluster_security_group_id" {
  description = "EKS-managed cluster security group (auto-created by EKS, used by pods)"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "lb_security_group_id" {
  description = "Load Balancer security group ID (HTTPS-only)"
  value       = aws_security_group.lb.id
}

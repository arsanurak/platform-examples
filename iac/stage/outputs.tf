output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Private endpoint of the Kubernetes API."
  value       = aws_eks_cluster.this.endpoint
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets nodes and databases run in."
  value       = aws_subnet.private[*].id
}

output "execution_role_arn" {
  description = "ARN CI would pass to aws-actions/configure-aws-credentials."
  value       = aws_iam_role.execution.arn
}

output "web_acl_arn" {
  description = "ARN the internet-facing Ingresses name in their wafv2-acl-arn annotation."
  value       = aws_wafv2_web_acl.this.arn
}

output "name_servers" {
  description = "Name servers to delegate the environment's zone to."
  value       = aws_route53_zone.this.name_servers
}

output "database_endpoints" {
  description = "Postgres endpoint of each domain's database."
  value       = { for domain, db in aws_db_instance.domain : domain => db.endpoint }
}

output "bucket_names" {
  description = "Name of each domain's bucket."
  value       = { for domain, bucket in aws_s3_bucket.domain : domain => bucket.bucket }
}

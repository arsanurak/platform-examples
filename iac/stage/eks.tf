# The EKS control plane. Written with plain aws_eks_* resources rather than a
# community module, so every setting is visible here.

resource "aws_eks_cluster" "this" {
  name     = var.environment
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # Access is granted with EKS access entries (below), not the aws-auth
  # ConfigMap, and the identity that creates the cluster gets nothing extra.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.this.arn
    }
  }

  # The role's policy must exist before the cluster is created and outlive it
  # when the cluster is destroyed.
  # The log group must exist first so EKS does not create an unencrypted one.
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# EKS writes control-plane logs to a log group with a fixed name. Creating it
# here first means it is encrypted and has a retention period; otherwise EKS
# creates it unencrypted and keeps logs forever.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.environment}/cluster"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.this.arn
}

# The role the EKS control plane assumes to manage AWS resources for the
# cluster.
resource "aws_iam_role" "cluster" {
  name                 = "${var.environment}-eks-cluster"
  path                 = "/workload/"
  permissions_boundary = aws_iam_policy.boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

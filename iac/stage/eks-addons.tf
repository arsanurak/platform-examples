# EKS-managed add-ons. Each runs at the default version EKS picks for the
# cluster's Kubernetes version, so a control-plane upgrade moves them too.

locals {
  core_addons = toset(["vpc-cni", "coredns", "kube-proxy", "eks-pod-identity-agent"])
}

data "aws_eks_addon_version" "this" {
  for_each = setunion(local.core_addons, ["external-secrets", "aws-ebs-csi-driver"])

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
}

resource "aws_eks_addon" "core" {
  for_each = local.core_addons

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.key
  addon_version = data.aws_eks_addon_version.this[each.key].version

  # CoreDNS needs nodes to schedule on.
  depends_on = [aws_eks_node_group.this]
}

# External Secrets, the EKS community add-on. It reads stage/<domain>/<service>
# from Secrets Manager for the ExternalSecrets under gitops/, through the
# ClusterSecretStore in gitops/platform.
resource "aws_eks_addon" "external_secrets" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "external-secrets"
  addon_version = data.aws_eks_addon_version.this["external-secrets"].version

  pod_identity_association {
    role_arn        = aws_iam_role.external_secrets.arn
    service_account = "external-secrets"
  }

  depends_on = [aws_eks_addon.core]
}

resource "aws_iam_role" "external_secrets" {
  name                 = "${var.environment}-external-secrets"
  path                 = "/workload/"
  permissions_boundary = aws_iam_policy.boundary.arn
  assume_role_policy   = file("${path.module}/iam/external-secrets/trust.json")
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-stage-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = file("${path.module}/iam/external-secrets/policy.json")
}

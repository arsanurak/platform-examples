# The AWS Load Balancer Controller turns the Ingresses under gitops/ into
# ALBs. It finds the certificate in ACM by each Ingress's host, so no
# certificate ARN is written in git, and attaches the WAF ACL named in the
# Ingress annotation.

locals {
  lbc_chart_version = "3.5.0"
}

resource "aws_iam_role" "lbc_controller" {
  name                 = "${var.environment}-lbc-controller"
  path                 = "/workload/"
  permissions_boundary = aws_iam_policy.boundary.arn
  assume_role_policy   = file("${path.module}/iam/lbc-controller/trust.json")
}

resource "aws_iam_role_policy" "lbc_controller" {
  name   = "manage-own-load-balancers"
  role   = aws_iam_role.lbc_controller.id
  policy = file("${path.module}/iam/lbc-controller/policy.json")
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc_controller.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.lbc_chart_version

  values = [yamlencode({
    clusterName    = aws_eks_cluster.this.name
    region         = var.region
    vpcId          = aws_vpc.this.id
    serviceAccount = { name = aws_eks_pod_identity_association.lbc.service_account }
    enableWafv2    = true
    enableWaf      = false
    enableShield   = false
  })]

  depends_on = [aws_eks_node_group.this, aws_eks_addon.core]
}

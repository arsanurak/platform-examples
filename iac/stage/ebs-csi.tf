# The EBS CSI driver, so pods can claim encrypted gp3 volumes. It creates and
# deletes only volumes it tagged itself (see iam/ebs-csi-driver/).

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi_driver.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [aws_eks_addon.core]
}

resource "aws_iam_role" "ebs_csi_driver" {
  name                 = "${var.environment}-ebs-csi-driver"
  path                 = "/workload/"
  permissions_boundary = aws_iam_policy.boundary.arn
  assume_role_policy   = file("${path.module}/iam/ebs-csi-driver/trust.json")
}

resource "aws_iam_role_policy" "ebs_csi_driver" {
  name   = "manage-own-volumes"
  role   = aws_iam_role.ebs_csi_driver.id
  policy = file("${path.module}/iam/ebs-csi-driver/policy.json")
}

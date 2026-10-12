# Karpenter launches the nodes workloads run on. Its NodePool and
# EC2NodeClass live in gitops/platform; this file gives it an identity, a
# role for its nodes, an interruption queue and the chart.

locals {
  karpenter_chart_version = "1.12.0"
}

resource "aws_iam_role" "karpenter_controller" {
  name                 = "${var.environment}-karpenter-controller"
  path                 = "/workload/"
  permissions_boundary = aws_iam_policy.boundary.arn
  assume_role_policy   = file("${path.module}/iam/karpenter-controller/trust.json")
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "manage-own-nodes"
  role   = aws_iam_role.karpenter_controller.id
  policy = file("${path.module}/iam/karpenter-controller/policy.json")
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
}

# The role Karpenter's nodes run as. The EC2NodeClass names it, and
# Karpenter wraps it in an instance profile it manages itself.
resource "aws_iam_role" "karpenter_node" {
  name                 = "${var.environment}-karpenter-node"
  path                 = "/workload/"
  permissions_boundary = aws_iam_policy.boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# Karpenter's nodes use the cluster security group; the EC2NodeClass finds it
# by this tag, as it finds the private subnets.
resource "aws_ec2_tag" "cluster_security_group_discovery" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.environment
}

# Spot interruptions, rebalance hints, state changes and scheduled
# maintenance arrive on this queue, so Karpenter can drain a node before EC2
# takes it away.
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.environment}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EventBridgeSendsInterruptions"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

locals {
  karpenter_events = {
    "spot-interruption"     = { source = ["aws.ec2"], detail-type = ["EC2 Spot Instance Interruption Warning"] }
    "rebalance"             = { source = ["aws.ec2"], detail-type = ["EC2 Instance Rebalance Recommendation"] }
    "instance-state-change" = { source = ["aws.ec2"], detail-type = ["EC2 Instance State-change Notification"] }
    "scheduled-change"      = { source = ["aws.health"], detail-type = ["AWS Health Event"] }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each = local.karpenter_events

  name          = "${var.environment}-karpenter-${each.key}"
  event_pattern = jsonencode(each.value)
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each = local.karpenter_events

  rule = aws_cloudwatch_event_rule.karpenter[each.key].name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = local.karpenter_chart_version

  values = [yamlencode({
    settings = {
      clusterName       = aws_eks_cluster.this.name
      interruptionQueue = aws_sqs_queue.karpenter_interruption.name
    }
    serviceAccount = { name = aws_eks_pod_identity_association.karpenter.service_account }
  })]

  # Karpenter runs on the system nodes and needs its identity before it starts.
  depends_on = [aws_eks_node_group.this, aws_eks_addon.core]
}

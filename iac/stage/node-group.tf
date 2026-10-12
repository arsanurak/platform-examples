# A small managed node group in the private subnets for system pods: CoreDNS,
# the controllers and Argo CD. Karpenter launches the nodes for workloads.
# The launch template hardens every node: IMDSv2 only, a hop limit that keeps
# pods away from the node's credentials, and an encrypted root volume.

resource "aws_launch_template" "nodes" {
  name_prefix = "${var.environment}-nodes-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.environment}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = var.node_instance_types

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  scaling_config {
    min_size     = var.node_count.min
    desired_size = var.node_count.desired
    max_size     = var.node_count.max
  }

  update_config {
    max_unavailable = 1
  }

  # Node policies must be attached before nodes try to join, and detached
  # only after they are gone.
  depends_on = [aws_iam_role_policy_attachment.node]
}

# The role system nodes run as. It holds only what a node needs to join the
# cluster and pull images; pods get their own permissions through EKS Pod
# Identity instead of borrowing the node's.
resource "aws_iam_role" "node" {
  name                 = "${var.environment}-eks-node"
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

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

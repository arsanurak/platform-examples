# Plan-level tests for the cluster, its network and its nodes. The providers
# are mocked, so these run with no credentials and never reach a real account.

mock_provider "aws" {
  override_during = plan

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "helm" {}

run "api_endpoint_is_private_only" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == false
    error_message = "The Kubernetes API must not be reachable from the internet."
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access == true
    error_message = "The Kubernetes API must be reachable from inside the VPC."
  }
}

run "secrets_are_encrypted_with_a_rotating_key" {
  command = plan

  assert {
    condition     = contains(aws_eks_cluster.this.encryption_config[0].resources, "secrets")
    error_message = "Kubernetes secrets must be envelope-encrypted with KMS."
  }

  assert {
    condition     = aws_eks_cluster.this.encryption_config[0].provider[0].key_arn == aws_kms_key.this.arn
    error_message = "Secrets must be encrypted with this root's own KMS key."
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true
    error_message = "The KMS key must rotate."
  }
}

run "every_control_plane_log_is_kept_encrypted_for_a_year" {
  command = plan

  assert {
    condition = toset(aws_eks_cluster.this.enabled_cluster_log_types) == toset([
      "api", "audit", "authenticator", "controllerManager", "scheduler",
    ])
    error_message = "All five control-plane log types must be enabled."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.name == "/aws/eks/stage/cluster"
    error_message = "The log group must use the name EKS writes to, or EKS creates its own unencrypted one."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.kms_key_id == aws_kms_key.this.arn
    error_message = "Control-plane logs must be encrypted with this root's KMS key."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days >= 365
    error_message = "Control-plane logs must be kept for at least a year."
  }
}

run "nodes_run_only_in_private_subnets" {
  command = plan

  # Give each subnet a known ID so the plan can say where nodes land.
  override_resource {
    target          = aws_subnet.private[0]
    values          = { id = "subnet-private-a" }
    override_during = plan
  }
  override_resource {
    target          = aws_subnet.private[1]
    values          = { id = "subnet-private-b" }
    override_during = plan
  }
  override_resource {
    target          = aws_subnet.private[2]
    values          = { id = "subnet-private-c" }
    override_during = plan
  }
  override_resource {
    target          = aws_subnet.public[0]
    values          = { id = "subnet-public-a" }
    override_during = plan
  }
  override_resource {
    target          = aws_subnet.public[1]
    values          = { id = "subnet-public-b" }
    override_during = plan
  }
  override_resource {
    target          = aws_subnet.public[2]
    values          = { id = "subnet-public-c" }
    override_during = plan
  }

  assert {
    condition     = aws_eks_node_group.this.subnet_ids == toset(["subnet-private-a", "subnet-private-b", "subnet-private-c"])
    error_message = "Nodes must be placed in the private subnets."
  }

  assert {
    condition     = length(setintersection(aws_eks_node_group.this.subnet_ids, ["subnet-public-a", "subnet-public-b", "subnet-public-c"])) == 0
    error_message = "No node may be placed in a public subnet."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.tags["karpenter.sh/discovery"] == "stage"])
    error_message = "Karpenter finds the subnets for its nodes by the discovery tag."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must not hand out public IPs by default."
  }
}

run "nodes_require_imdsv2_and_encrypted_disks" {
  command = plan

  assert {
    condition     = aws_launch_template.nodes.metadata_options[0].http_tokens == "required"
    error_message = "Nodes must only accept IMDSv2 requests."
  }

  assert {
    condition     = aws_launch_template.nodes.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "Pods must not reach the node's instance metadata through an extra network hop."
  }

  assert {
    condition     = aws_launch_template.nodes.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "Node root volumes must be encrypted."
  }
}

run "only_the_named_admin_role_gets_cluster_admin" {
  command = plan

  variables {
    admin_role_arn = "arn:aws:iam::000000000000:role/example-admin"
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "Cluster access must be managed through EKS access entries, not the aws-auth ConfigMap."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "Whoever creates the cluster must not silently become its admin."
  }

  assert {
    condition     = aws_eks_access_entry.admin.principal_arn == "arn:aws:iam::000000000000:role/example-admin"
    error_message = "The admin access entry must be for the named admin role."
  }

  assert {
    condition     = aws_eks_access_policy_association.admin.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "The admin role must get the cluster admin access policy."
  }
}

run "private_subnets_reach_out_only_through_nat" {
  command = plan

  # Give the network pieces known IDs so the plan can say what routes where.
  override_resource {
    target          = aws_subnet.public[0]
    values          = { id = "subnet-public-a" }
    override_during = plan
  }
  override_resource {
    target          = aws_subnet.public[1]
    values          = { id = "subnet-public-b" }
    override_during = plan
  }
  override_resource {
    target          = aws_subnet.public[2]
    values          = { id = "subnet-public-c" }
    override_during = plan
  }
  override_resource {
    target          = aws_internet_gateway.this
    values          = { id = "igw-example" }
    override_during = plan
  }
  override_resource {
    target          = aws_nat_gateway.this
    values          = { id = "nat-example" }
    override_during = plan
  }
  override_resource {
    target          = aws_route_table.private
    values          = { id = "rtb-private" }
    override_during = plan
  }
  override_resource {
    target          = aws_route_table.public
    values          = { id = "rtb-public" }
    override_during = plan
  }

  assert {
    condition     = aws_route.private_default.destination_cidr_block == "0.0.0.0/0" && aws_route.private_default.nat_gateway_id == aws_nat_gateway.this.id
    error_message = "Private subnets must reach the internet through the NAT gateway."
  }

  assert {
    condition     = aws_route.private_default.gateway_id == null
    error_message = "Private subnets must not route straight to the internet gateway."
  }

  assert {
    condition     = length(aws_route_table_association.private) == length(aws_subnet.private) && alltrue([for a in aws_route_table_association.private : a.route_table_id == aws_route_table.private.id])
    error_message = "Every private subnet must use the private route table."
  }

  assert {
    condition     = contains([for s in aws_subnet.public : s.id], aws_nat_gateway.this.subnet_id)
    error_message = "The NAT gateway must sit in a public subnet."
  }

  assert {
    condition     = aws_route.public_default.gateway_id == aws_internet_gateway.this.id
    error_message = "Public subnets must route to the internet gateway."
  }
}

run "vpc_traffic_is_logged_and_the_default_security_group_is_closed" {
  command = plan

  override_resource {
    target          = aws_vpc.this
    values          = { id = "vpc-example" }
    override_during = plan
  }
  override_resource {
    target          = aws_cloudwatch_log_group.flow_logs
    values          = { arn = "arn:aws:logs:eu-west-1:000000000000:log-group:/aws/vpc/stage/flow-logs" }
    override_during = plan
  }

  assert {
    condition     = aws_flow_log.vpc.traffic_type == "ALL" && aws_flow_log.vpc.log_destination == aws_cloudwatch_log_group.flow_logs.arn
    error_message = "All VPC traffic must be logged to the flow log group."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs.kms_key_id == aws_kms_key.this.arn && aws_cloudwatch_log_group.flow_logs.retention_in_days >= 365
    error_message = "Flow logs must be encrypted with this root's KMS key and kept for at least a year."
  }

  assert {
    # Declaring the default security group with no rules strips every rule
    # from it. checkov (CKV2_AWS_12) checks that no rule creeps back in.
    condition     = aws_default_security_group.this.vpc_id == aws_vpc.this.id
    error_message = "This VPC's default security group must be managed here, with no rules."
  }
}

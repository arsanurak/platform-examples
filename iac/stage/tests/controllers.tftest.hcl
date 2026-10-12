# Plan-level tests for the add-ons and controllers that run in the cluster:
# eks-addons.tf, ebs-csi.tf, karpenter.tf and lbc.tf.

mock_provider "aws" {
  override_during = plan
}

mock_provider "helm" {}

override_resource {
  override_during = plan
  target          = aws_eks_cluster.this
  values          = { name = "stage" }
}

override_resource {
  override_during = plan
  target          = aws_iam_role.karpenter_controller
  values          = { arn = "arn:aws:iam::000000000000:role/workload/stage-karpenter-controller" }
}

override_resource {
  override_during = plan
  target          = aws_iam_role.lbc_controller
  values          = { arn = "arn:aws:iam::000000000000:role/workload/stage-lbc-controller" }
}

override_resource {
  override_during = plan
  target          = aws_iam_role.ebs_csi_driver
  values          = { arn = "arn:aws:iam::000000000000:role/workload/stage-ebs-csi-driver" }
}

override_resource {
  override_during = plan
  target          = aws_iam_role.external_secrets
  values          = { arn = "arn:aws:iam::000000000000:role/workload/stage-external-secrets" }
}

override_resource {
  override_during = plan
  target          = aws_iam_role.karpenter_node
  values          = { arn = "arn:aws:iam::000000000000:role/workload/stage-karpenter-node" }
}

override_resource {
  override_during = plan
  target          = aws_sqs_queue.karpenter_interruption
  values          = { arn = "arn:aws:sqs:eu-west-1:000000000000:stage-karpenter" }
}

override_resource {
  override_during = plan
  target          = aws_vpc.this
  values          = { id = "vpc-example" }
}

run "the_cluster_gets_its_core_add_ons" {
  command = plan

  assert {
    condition = toset(concat(keys(aws_eks_addon.core), [aws_eks_addon.external_secrets.addon_name, aws_eks_addon.ebs_csi_driver.addon_name])) == toset([
      "vpc-cni", "coredns", "kube-proxy", "eks-pod-identity-agent", "external-secrets", "aws-ebs-csi-driver",
    ])
    error_message = "The cluster needs networking, DNS, the Pod Identity agent, External Secrets and the EBS CSI driver."
  }
}

run "controllers_get_their_roles_through_pod_identity" {
  command = plan

  assert {
    condition     = one(aws_eks_addon.external_secrets.pod_identity_association).role_arn == aws_iam_role.external_secrets.arn
    error_message = "External Secrets must assume its own role through Pod Identity."
  }

  assert {
    condition     = one(aws_eks_addon.ebs_csi_driver.pod_identity_association).role_arn == aws_iam_role.ebs_csi_driver.arn
    error_message = "The EBS CSI driver must assume its own role through Pod Identity."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.karpenter.role_arn == aws_iam_role.karpenter_controller.arn &&
      aws_eks_pod_identity_association.karpenter.service_account == "karpenter"
    )
    error_message = "Karpenter's service account must assume the Karpenter controller role."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.lbc.role_arn == aws_iam_role.lbc_controller.arn &&
      aws_eks_pod_identity_association.lbc.service_account == "aws-load-balancer-controller"
    )
    error_message = "The load balancer controller's service account must assume its own role."
  }

  assert {
    condition = alltrue([
      for role in [aws_iam_role.karpenter_controller, aws_iam_role.lbc_controller, aws_iam_role.ebs_csi_driver, aws_iam_role.external_secrets] :
      jsondecode(role.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    ])
    error_message = "Controller roles must trust EKS Pod Identity, not the node or an OIDC web identity."
  }
}

run "karpenter_nodes_can_join_the_cluster" {
  command = plan

  assert {
    condition     = aws_iam_role.karpenter_node.name == "stage-karpenter-node"
    error_message = "The EC2NodeClass in gitops/platform names the node role stage-karpenter-node."
  }

  assert {
    condition     = aws_eks_access_entry.karpenter_node.type == "EC2_LINUX" && aws_eks_access_entry.karpenter_node.principal_arn == aws_iam_role.karpenter_node.arn
    error_message = "Karpenter's nodes join through an EC2_LINUX access entry for their role."
  }

  assert {
    condition     = aws_ec2_tag.cluster_security_group_discovery.key == "karpenter.sh/discovery" && aws_ec2_tag.cluster_security_group_discovery.value == "stage"
    error_message = "Karpenter finds the cluster security group by the discovery tag."
  }
}

run "karpenter_hears_about_interruptions" {
  command = plan

  assert {
    condition     = aws_sqs_queue.karpenter_interruption.name == "stage-karpenter"
    error_message = "The controller policy reads the queue named stage-karpenter."
  }

  assert {
    condition     = aws_sqs_queue.karpenter_interruption.sqs_managed_sse_enabled == true
    error_message = "The interruption queue must be encrypted."
  }

  assert {
    condition = toset(keys(aws_cloudwatch_event_rule.karpenter)) == toset([
      "spot-interruption", "rebalance", "instance-state-change", "scheduled-change",
    ])
    error_message = "Karpenter needs spot, rebalance, state-change and scheduled-change events."
  }

  assert {
    condition     = alltrue([for t in aws_cloudwatch_event_target.karpenter : t.arn == aws_sqs_queue.karpenter_interruption.arn])
    error_message = "Every interruption event must go to the queue."
  }

  assert {
    condition     = yamldecode(helm_release.karpenter.values[0]).settings.interruptionQueue == "stage-karpenter"
    error_message = "Karpenter must be told which queue to read."
  }
}

run "controller_charts_are_pinned" {
  command = plan

  assert {
    condition     = helm_release.karpenter.repository == "oci://public.ecr.aws/karpenter" && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", helm_release.karpenter.version))
    error_message = "Karpenter must come from its OCI registry at an exact version."
  }

  assert {
    condition     = helm_release.lbc.repository == "https://aws.github.io/eks-charts" && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", helm_release.lbc.version))
    error_message = "The load balancer controller must come from eks-charts at an exact version."
  }
}

run "the_load_balancer_controller_attaches_waf_but_not_shield" {
  command = plan

  assert {
    condition = (
      yamldecode(helm_release.lbc.values[0]).enableWafv2 == true &&
      yamldecode(helm_release.lbc.values[0]).enableShield == false &&
      yamldecode(helm_release.lbc.values[0]).clusterName == "stage"
    )
    error_message = "Ingresses carry a WAF ACL annotation; Shield Advanced is not used, so its API is not called."
  }
}

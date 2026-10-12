# This root is example configuration: written to be read and checked, never
# applied. The AWS provider only accepts the placeholder account
# 000000000000, which does not exist, so a plan with real credentials fails
# before it can read or change anything.

provider "aws" {
  region              = var.region
  allowed_account_ids = ["000000000000"]

  default_tags {
    tags = {
      project     = "platform-examples"
      environment = var.environment
      managed-by  = "terraform"
    }
  }
}

# Helm installs the cluster's controllers and Argo CD. It reaches the API
# server with a short-lived token from `aws eks get-token`, so no
# kubeconfig or cluster credential is ever stored.
provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
    }
  }
}

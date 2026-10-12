variable "environment" {
  description = "Name of the environment. Also the EKS cluster name and the prefix of most resource names."
  type        = string
  default     = "stage"

  validation {
    # The policy JSON under iam/ names the cluster and its resources literally.
    condition     = var.environment == "stage"
    error_message = "The policy JSON under iam/ is written for stage. Copy the root and its iam/ folder for another environment."
  }
}

variable "region" {
  description = "AWS region everything runs in."
  type        = string
  default     = "eu-west-1"
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across. One subnet of each kind per zone."
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. Subnets are carved from it."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_types" {
  description = "EC2 instance types for the system node group. Karpenter chooses the instances for workloads."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_count" {
  description = "Minimum, desired and maximum number of system nodes."
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = {
    min     = 2
    desired = 2
    max     = 3
  }
}

variable "admin_role_arn" {
  description = "IAM role that gets cluster admin through an EKS access entry. A placeholder."
  type        = string
  default     = "arn:aws:iam::000000000000:role/platform-admin"

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.admin_role_arn))
    error_message = "admin_role_arn must be an IAM role ARN."
  }
}

variable "dns_zone" {
  description = "Public DNS zone for the environment. Services get <domain>-<service>.<zone>."
  type        = string
  default     = "stage.example.com"
}

variable "domains" {
  description = "Business domains. Each gets its own database and bucket, and a namespace in gitops/."
  type        = set(string)
  default     = ["orders", "billing"]
}

variable "scp_target_id" {
  description = "Organization root, OU or account the payment lockout applies to. A placeholder."
  type        = string
  default     = "ou-0000-00000000"
}

variable "gitops_repo_url" {
  description = "Git repository Argo CD syncs from."
  type        = string
  default     = "https://github.com/arsanurak/platform-examples.git"
}

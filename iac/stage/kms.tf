# One customer-managed key for the environment. It envelope-encrypts
# Kubernetes secrets and encrypts the log groups, databases and buckets.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  account_arn = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"
}

resource "aws_kms_key" "this" {
  description             = "Encrypts secrets, logs, databases and buckets in ${var.environment}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Everyone else gets the key through IAM: RDS, S3 and EBS use it on a
        # caller's behalf, scoped by kms:ViaService in that caller's policy.
        Sid       = "AccountAdministersKeyThroughIam"
        Effect    = "Allow"
        Principal = { AWS = local.account_arn }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogsEncryptsLogGroups"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${local.account_id}:log-group:*"
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.environment}"
  target_key_id = aws_kms_key.this.key_id
}

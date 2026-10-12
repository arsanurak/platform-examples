# Plan-level tests for each domain's data stores: rds.tf and s3.tf.

mock_provider "aws" {
  override_during = plan

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "helm" {}

run "every_domain_gets_one_database_and_one_bucket" {
  command = plan

  assert {
    condition     = toset(keys(aws_db_instance.domain)) == toset(["orders", "billing"]) && toset(keys(aws_s3_bucket.domain)) == toset(["orders", "billing"])
    error_message = "Each business domain owns exactly one database and one bucket."
  }
}

run "databases_are_private_encrypted_and_protected" {
  command = plan

  assert {
    condition = alltrue([
      for db in aws_db_instance.domain :
      db.engine == "postgres" && db.publicly_accessible == false && db.storage_encrypted == true && db.kms_key_id == aws_kms_key.this.arn
    ])
    error_message = "Every database is Postgres, unreachable from the internet and encrypted with the environment's key."
  }

  assert {
    condition     = alltrue([for db in aws_db_instance.domain : db.multi_az == true && db.deletion_protection == true])
    error_message = "Every database must survive losing a zone and must not be deletable by accident."
  }

  assert {
    condition     = alltrue([for db in aws_db_instance.domain : db.manage_master_user_password == true && db.password == null])
    error_message = "RDS keeps the master password in Secrets Manager; it is never in Terraform."
  }

  assert {
    condition     = alltrue([for db in aws_db_instance.domain : db.backup_retention_period >= 7])
    error_message = "Every database keeps at least a week of backups."
  }
}

run "databases_only_accept_the_cluster" {
  command = plan

  override_resource {
    override_during = plan
    target          = aws_eks_cluster.this
    values = {
      vpc_config = { cluster_security_group_id = "sg-cluster" }
    }
  }

  assert {
    condition = alltrue([
      for rule in aws_vpc_security_group_ingress_rule.database :
      rule.referenced_security_group_id == "sg-cluster" && rule.from_port == 5432 && rule.to_port == 5432 && rule.cidr_ipv4 == null
    ])
    error_message = "Databases accept Postgres connections from the cluster's security group only."
  }
}

run "buckets_are_versioned_encrypted_and_closed" {
  command = plan

  assert {
    condition     = alltrue([for v in aws_s3_bucket_versioning.domain : v.versioning_configuration[0].status == "Enabled"])
    error_message = "Every bucket must keep old versions."
  }

  assert {
    condition = alltrue([
      for c in aws_s3_bucket_server_side_encryption_configuration.domain :
      one(c.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" &&
      one(c.rule).apply_server_side_encryption_by_default[0].kms_master_key_id == aws_kms_key.this.arn
    ])
    error_message = "Every bucket must be encrypted with the environment's key."
  }

  assert {
    condition = alltrue([
      for b in aws_s3_bucket_public_access_block.domain :
      b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets
    ])
    error_message = "No bucket may be made public."
  }
}

run "buckets_refuse_plain_http" {
  command = plan

  override_resource {
    override_during = plan
    target          = aws_s3_bucket.domain
    values          = { arn = "arn:aws:s3:::example-bucket" }
  }

  assert {
    condition = alltrue([
      for p in aws_s3_bucket_policy.domain :
      anytrue([
        for s in jsondecode(p.policy).Statement :
        s.Effect == "Deny" && s.Condition.Bool["aws:SecureTransport"] == "false"
      ])
    ])
    error_message = "Every bucket must deny requests that do not use TLS."
  }
}

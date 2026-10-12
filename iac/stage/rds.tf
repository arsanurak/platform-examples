# One Postgres database per business domain, so domains never share a schema.
# Each is private, encrypted with the environment's key, spread over two
# zones and protected from deletion. RDS generates the master password and
# keeps it in Secrets Manager; it never passes through Terraform.

resource "aws_db_subnet_group" "domain" {
  for_each = var.domains

  name       = "${var.environment}-${each.key}"
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_security_group" "database" {
  #checkov:skip=CKV2_AWS_5:Attached to aws_db_instance.domain through vpc_security_group_ids; checkov does not follow the for_each reference.

  for_each = var.domains

  name        = "${var.environment}-${each.key}-database"
  description = "Postgres for the ${each.key} domain, reachable from the cluster only"
  vpc_id      = aws_vpc.this.id
}

# Pods reach the database from nodes in the cluster security group: the
# system nodes and every node Karpenter launches.
resource "aws_vpc_security_group_ingress_rule" "database" {
  for_each = var.domains

  security_group_id            = aws_security_group.database[each.key].id
  description                  = "Postgres from the cluster"
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_parameter_group" "postgres" {
  name   = "${var.environment}-postgres17"
  family = "postgres17"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

resource "aws_db_instance" "domain" {
  #checkov:skip=CKV_AWS_118:Enhanced monitoring needs one more role passed to RDS; Performance Insights and the exported logs cover this example.

  for_each = var.domains

  identifier     = "${var.environment}-${each.key}"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.medium"
  db_name        = each.key

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  username                            = "${each.key}_admin"
  manage_master_user_password         = true
  master_user_secret_kms_key_id       = aws_kms_key.this.arn
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.domain[each.key].name
  vpc_security_group_ids = [aws_security_group.database[each.key].id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false
  multi_az               = true

  backup_retention_period    = 7
  copy_tags_to_snapshot      = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.environment}-${each.key}-final"
  auto_minor_version_upgrade = true

  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.this.arn
  performance_insights_retention_period = 7
}

# One bucket per business domain for its files. Every bucket is versioned,
# encrypted with the environment's key, closed to the public and refuses
# requests without TLS.

# trivy flags the same missing access log as checkov's CKV_AWS_18: see the reason inside.
#trivy:ignore:AWS-0089
resource "aws_s3_bucket" "domain" {
  #checkov:skip=CKV_AWS_18:Access logs need a separate log bucket, left out to keep the example small.
  #checkov:skip=CKV_AWS_144:Cross-region replication is a disaster-recovery choice this one-region example does not make.
  #checkov:skip=CKV2_AWS_62:Nothing consumes bucket events in this example.

  for_each = var.domains

  bucket = "example-${var.environment}-${each.key}-000000000000"
}

resource "aws_s3_bucket_ownership_controls" "domain" {
  for_each = var.domains

  bucket = aws_s3_bucket.domain[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "domain" {
  for_each = var.domains

  bucket                  = aws_s3_bucket.domain[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "domain" {
  for_each = var.domains

  bucket = aws_s3_bucket.domain[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "domain" {
  for_each = var.domains

  bucket = aws_s3_bucket.domain[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

# Old versions and abandoned uploads would otherwise be kept and paid for
# forever.
resource "aws_s3_bucket_lifecycle_configuration" "domain" {
  for_each = var.domains

  bucket = aws_s3_bucket.domain[each.key].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.domain]
}

resource "aws_s3_bucket_policy" "domain" {
  for_each = var.domains

  bucket = aws_s3_bucket.domain[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyPlainHttp"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.domain[each.key].arn,
        "${aws_s3_bucket.domain[each.key].arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  # Apply the policy after the public access block, so there is never a
  # moment the bucket could take a public policy.
  depends_on = [aws_s3_bucket_public_access_block.domain]
}

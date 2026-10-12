# The regional web ACL every internet-facing Ingress names in its
# alb.ingress.kubernetes.io/wafv2-acl-arn annotation. The rule data is in
# waf/: AWS managed rule groups and a per-IP rate limit. Changing what the
# ACL blocks means editing those files, not this one.

locals {
  waf_managed_rule_groups = jsondecode(file("${path.module}/waf/managed-rule-groups.json"))
  waf_rate_limit          = jsondecode(file("${path.module}/waf/rate-limit.json"))
}

resource "aws_wafv2_web_acl" "this" {
  name  = var.environment
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = local.waf_rate_limit.name
    priority = local.waf_rate_limit.priority

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = local.waf_rate_limit.limit
        evaluation_window_sec = local.waf_rate_limit.evaluation_window_sec
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = local.waf_rate_limit.name
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.waf_managed_rule_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name

          dynamic "rule_action_override" {
            for_each = rule.value.excluded_rules

            content {
              name = rule_action_override.value

              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.environment
    sampled_requests_enabled   = true
  }
}

# WAF only writes to log groups whose name starts with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.environment}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.this.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Keep credentials out of the logs.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

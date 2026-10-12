# Plan-level tests for what sits in front of the services: dns.tf, acm.tf
# and waf.tf.

mock_provider "aws" {
  override_during = plan

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:000000000000:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "helm" {}

run "the_environment_has_its_own_public_zone" {
  command = plan

  assert {
    condition     = aws_route53_zone.this.name == "stage.example.com"
    error_message = "Services live under stage.example.com."
  }
}

run "one_wildcard_certificate_covers_every_service" {
  command = plan

  assert {
    condition     = aws_acm_certificate.wildcard.domain_name == "*.stage.example.com"
    error_message = "Hosts are <domain>-<service>.stage.example.com, so one wildcard covers them all."
  }

  assert {
    condition     = aws_acm_certificate.wildcard.validation_method == "DNS"
    error_message = "The certificate must be validated through DNS records in the zone, so it renews itself."
  }
}

run "the_web_acl_is_regional_and_blocks_floods" {
  command = plan

  assert {
    condition     = aws_wafv2_web_acl.this.name == "stage" && aws_wafv2_web_acl.this.scope == "REGIONAL"
    error_message = "The Ingress annotation names a regional web ACL called stage, for ALBs."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this.default_action[0].allow) == 1
    error_message = "Traffic no rule matches is allowed; the rules block."
  }

  assert {
    condition = toset([for r in aws_wafv2_web_acl.this.rule : r.name]) == toset(concat(
      [for g in jsondecode(file("waf/managed-rule-groups.json")) : g.name],
      [jsondecode(file("waf/rate-limit.json")).name],
    ))
    error_message = "The web ACL's rules must be exactly the ones listed in waf/."
  }

  assert {
    condition     = contains([for r in aws_wafv2_web_acl.this.rule : r.name], "AWSManagedRulesKnownBadInputsRuleSet")
    error_message = "The known-bad-inputs rule group (Log4j and similar) must be on."
  }

  assert {
    condition     = length(distinct([for r in aws_wafv2_web_acl.this.rule : r.priority])) == length(aws_wafv2_web_acl.this.rule)
    error_message = "Every rule needs its own priority."
  }
}

run "waf_logs_go_to_an_encrypted_log_group" {
  command = plan

  override_resource {
    override_during = plan
    target          = aws_cloudwatch_log_group.waf
    values          = { arn = "arn:aws:logs:eu-west-1:000000000000:log-group:aws-waf-logs-stage" }
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf.name == "aws-waf-logs-stage"
    error_message = "WAF only logs to log groups whose name starts with aws-waf-logs-."
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf.kms_key_id == aws_kms_key.this.arn
    error_message = "WAF logs must be encrypted with the environment's key."
  }

  assert {
    condition     = contains(aws_wafv2_web_acl_logging_configuration.this.log_destination_configs, aws_cloudwatch_log_group.waf.arn)
    error_message = "The web ACL must log to its log group."
  }
}

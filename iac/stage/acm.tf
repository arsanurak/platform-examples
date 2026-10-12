# One wildcard certificate for every service host. The load balancer
# controller finds it in ACM by the Ingress host, so no ARN is in git.

resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.dns_zone}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# A wildcard certificate has exactly one name to validate, so one record.
resource "aws_route53_record" "certificate_validation" {
  zone_id         = aws_route53_zone.this.zone_id
  name            = one(aws_acm_certificate.wildcard.domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.wildcard.domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.wildcard.domain_validation_options).resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [aws_route53_record.certificate_validation.fqdn]
}

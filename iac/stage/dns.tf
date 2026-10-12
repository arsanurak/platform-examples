# The environment's public zone. Service hosts are
# <domain>-<service>.stage.example.com; the load balancer controller's ALBs
# answer for them. Each record for an ALB would be added by hand or by
# external-dns; this example stops at the zone.

#checkov:skip=CKV2_AWS_38:DNSSEC signing needs a KMS key in us-east-1 and a DS record at the parent zone, which example.com does not delegate.
#checkov:skip=CKV2_AWS_39:Query logging for a public zone must go to a log group in us-east-1; this example keeps to one region.
resource "aws_route53_zone" "this" {
  name    = var.dns_zone
  comment = "Public zone for ${var.environment}"
}

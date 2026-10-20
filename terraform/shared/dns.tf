# Route 53에서 도메인을 살 때 자동으로 생긴 영역을 읽기만 한다 (새로 만들면 네임서버가 엇갈린다)
data "aws_route53_zone" "main" { name = "orbi-t.com" }

resource "aws_acm_certificate" "wildcard" {
  provider                  = aws.use1
  domain_name               = "orbi-t.com"
  subject_alternative_names = ["*.orbi-t.com"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "acm" {
  for_each        = { for o in aws_acm_certificate.wildcard.domain_validation_options : o.domain_name => o }
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  provider                = aws.use1
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.acm : r.fqdn]
}

output "zone_id" { value = data.aws_route53_zone.main.zone_id }
output "cert_arn_use1" { value = aws_acm_certificate_validation.wildcard.certificate_arn }

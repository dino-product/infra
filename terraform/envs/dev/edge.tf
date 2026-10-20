data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "http_from_cloudfront" {
  security_group_id = module.node.sg_id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "CloudFront origin-facing only"
}

resource "aws_route53_record" "origin" {
  zone_id = local.shared.zone_id
  name    = "origin-dev.orbi-t.com"
  type    = "A"
  ttl     = 300
  records = [module.node.public_ip]
}

resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "origin_verify" {
  name  = "/orbit/dev/ORIGIN_VERIFY"
  type  = "SecureString"
  value = random_password.origin_verify.result
}

data "aws_cloudfront_cache_policy" "disabled" { name = "Managed-CachingDisabled" }
data "aws_cloudfront_origin_request_policy" "all" { name = "Managed-AllViewer" }

resource "aws_cloudfront_distribution" "api" {
  enabled     = true
  comment     = "orbit dev api"
  aliases     = ["dev-api.orbi-t.com"]
  price_class = "PriceClass_200" # 한국 엣지 포함

  origin {
    origin_id   = "node"
    domain_name = aws_route53_record.origin.fqdn
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 30
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id         = "node"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all.id
    compress                 = true
  }

  viewer_certificate {
    acm_certificate_arn      = local.shared.cert_arn_use1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

}

resource "aws_route53_record" "api" {
  zone_id = local.shared.zone_id
  name    = "dev-api.orbi-t.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.api.domain_name
    zone_id                = aws_cloudfront_distribution.api.hosted_zone_id
    evaluate_target_health = false
  }
}
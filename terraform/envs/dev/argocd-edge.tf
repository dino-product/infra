# Grafana 공개 주소 grafana.dev.orbi-t.com (12단계). edge.tf의 api 배포와 같은 보호 방식
# 원본(origin-dev) · 비밀 헤더 X-Origin-Verify는 api와 공유한다 → 노드엔 CloudFront로만 들어오고, Traefik이 Host + 헤더로 가른다
# Traefik 라우트는 platform/grafana-ingressroute.yaml
# 인증서는 shared의 *.dev.orbi-t.com (*.orbi-t.com은 두 단계 이름을 못 덮는다)

resource "aws_cloudfront_distribution" "grafana" {
  enabled     = true
  comment     = "orbit dev grafana"
  aliases     = ["grafana.dev.orbi-t.com"]
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

  # 캐시 없이 전부 넘긴다 (로그인 쿠키 · 대시보드 저장 POST/PUT/DELETE 포함)
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
    acm_certificate_arn      = local.shared.cert_dev_arn_use1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_route53_record" "grafana" {
  zone_id = local.shared.zone_id
  name    = "grafana.dev.orbi-t.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.grafana.domain_name
    zone_id                = aws_cloudfront_distribution.grafana.hosted_zone_id
    evaluate_target_health = false
  }
}

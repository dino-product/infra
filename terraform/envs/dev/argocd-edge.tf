# Argo CD 공개 주소 argocd.dev.orbi-t.com. edge.tf의 api 배포와 같은 보호 방식
# 원본(origin-dev) · 비밀 헤더 X-Origin-Verify는 api와 공유한다 → 노드엔 CloudFront로만 들어오고, Traefik이 Host + 헤더로 가른다
# Traefik 라우트는 platform/edge-dev.yaml (scripts/apply-edge.sh)
# 처음엔 Grafana(grafana.dev)용으로 만들었다가 Grafana Cloud로 옮기면서 주소만 바꿨다 → moved로 배포를 그대로 쓴다
# 인증서는 shared의 *.dev.orbi-t.com (*.orbi-t.com은 두 단계 이름을 못 덮는다)

moved {
  from = aws_cloudfront_distribution.grafana
  to   = aws_cloudfront_distribution.argocd
}

resource "aws_cloudfront_distribution" "argocd" {
  enabled     = true
  comment     = "orbit dev argocd"
  aliases     = ["argocd.dev.orbi-t.com"]
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

  # 캐시 없이 전부 넘긴다 (로그인 쿠키 · 동기화 POST/PUT/DELETE 포함)
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

resource "aws_route53_record" "argocd" {
  zone_id = local.shared.zone_id
  name    = "argocd.dev.orbi-t.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.argocd.domain_name
    zone_id                = aws_cloudfront_distribution.argocd.hosted_zone_id
    evaluate_target_health = false
  }
}

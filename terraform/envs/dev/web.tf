# 사무실 웹(dino-product/web, Vite SPA) dev 공개 주소 dev.orbi-t.com
# 정적 파일이라 클러스터에 넣지 않고 S3 + CloudFront로 낸다 (노드 메모리 여유가 20% 안팎, CloudFront 1TB · S3 수 MB는 사실상 무료)
# 배포: web 레포 main push → GitHub Actions(gh-web-dev 역할, OIDC) → aws s3 sync → index.html 무효화
# API는 dev-api.orbi-t.com으로 교차 출처 호출 → 서버 파라미터 /orbit/dev/CORS_ALLOWED_ORIGIN_PATTERNS 에 https://dev.orbi-t.com 이 있어야 한다

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "web" {
  bucket        = "orbit-web-dev-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # dev: 빌드 산출물뿐이라 destroy 가능
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront만 읽는다 (OAC). 버킷 자체는 비공개
resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "orbit-web-dev"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "web_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_bucket.json
}

# 캐시는 객체의 Cache-Control을 따른다 (workflow가 assets/* 는 1년 immutable, index.html 은 no-cache 로 올린다)
data "aws_cloudfront_cache_policy" "optimized" { name = "Managed-CachingOptimized" }

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  comment             = "orbit dev web"
  aliases             = ["dev.orbi-t.com"]
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # 한국 엣지 포함
  http_version        = "http2and3"

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  # SPA: /timetable 같은 경로는 S3에 객체가 없어 403(ListBucket 권한 없음) 또는 404 → index.html 을 200으로 주고 라우터가 처리
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  viewer_certificate {
    acm_certificate_arn      = local.shared.cert_arn_use1 # *.orbi-t.com 이 dev.orbi-t.com 을 덮는다
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_route53_record" "web" {
  zone_id = local.shared.zone_id
  name    = "dev.orbi-t.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.web.domain_name
    zone_id                = aws_cloudfront_distribution.web.hosted_zone_id
    evaluate_target_health = false
  }
}

# web 레포 main 브랜치의 GitHub Actions만 (OIDC). 불변 subject: gh api repos/dino-product/web/actions/oidc/customization/sub
# job 에 environment: dev 가 있으면 subject 가 ref 대신 environment 로 온다 → 둘 다 허용
data "aws_iam_policy_document" "gh_web_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.shared.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:dino-product@324172954/web@1429959394:ref:refs/heads/main",
        "repo:dino-product@324172954/web@1429959394:environment:dev",
      ]
    }
  }
}

resource "aws_iam_role" "gh_web_dev" {
  name                 = "gh-web-dev"
  assume_role_policy   = data.aws_iam_policy_document.gh_web_trust.json
  max_session_duration = 3600
}

# 이 버킷에 올리기 · 지우기 와 이 배포의 무효화(만들기 · 완료 대기)만
resource "aws_iam_role_policy" "gh_web_deploy" {
  name = "web-deploy"
  role = aws_iam_role.gh_web_dev.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.web.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.web.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = aws_cloudfront_distribution.web.arn
      },
    ]
  })
}

output "web_bucket" {
  value = aws_s3_bucket.web.bucket
}

output "web_distribution_id" {
  value = aws_cloudfront_distribution.web.id
}

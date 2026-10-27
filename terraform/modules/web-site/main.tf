# 정적 웹(dino-product/web, Vite SPA) 한 환경분: 비공개 S3 + OAC CloudFront + 도메인 + 배포용 GitHub OIDC 역할
# 배포: web 레포 GitHub Actions → aws s3 sync → index.html 무효화. 클러스터를 거치지 않는다
# 캐시는 객체의 Cache-Control 을 따른다 (workflow 가 assets/* 는 1년 immutable, index.html 은 no-cache 로 올린다)

variable "env" { type = string }

variable "domain" {
  type        = string
  description = "주 주소 (예: dev.orbi-t.com, orbi-t.com)"
}

variable "redirect_domains" {
  type        = list(string)
  default     = []
  description = "주 주소로 301 리다이렉트할 별칭 (예: www.orbi-t.com). 인증서가 덮어야 한다"
}

variable "cert_arn_use1" { type = string }
variable "zone_id" { type = string }
variable "github_oidc_arn" { type = string }

variable "github_subjects" {
  type        = list(string)
  description = "역할을 받을 수 있는 OIDC subject. job 에 environment 가 있으면 ref 대신 environment subject 가 온다 → 둘 다 넣는다"
}

variable "api_origin" {
  type        = string
  description = "브라우저가 부르는 API 출처 (CSP connect-src). 예: https://dev-api.orbi-t.com"
}

variable "media_bucket" {
  type        = string
  description = "서명 URL 로 직접 올리고 읽는 사진 버킷 이름 (CSP img-src · connect-src)"
}

variable "extra_script_src" {
  type        = list(string)
  default     = []
  description = "CSP script-src 에 더할 출처 (카카오 SDK 등). 기본은 'self' 만"
}

variable "force_destroy" {
  type        = bool
  default     = false
  description = "dev 만 true. 빌드 산출물뿐이라 destroy 가능"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name = "orbit-web-${var.env}-${data.aws_caller_identity.current.account_id}"
  media_url   = "https://${var.media_bucket}.s3.${data.aws_region.current.region}.amazonaws.com"
  aliases     = concat([var.domain], var.redirect_domains)
  csp = join("; ", [
    "default-src 'self'",
    "script-src ${join(" ", concat(["'self'"], var.extra_script_src))}",
    "style-src 'self' 'unsafe-inline'", # React style 속성 (인라인 스타일 93곳)
    "img-src 'self' data: blob: ${local.media_url}",
    "font-src 'self' data:",
    "connect-src 'self' ${var.api_origin} ${local.media_url}",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
    "upgrade-insecure-requests",
  ])
}

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# CloudFront 만 읽는다 (OAC). 버킷 자체는 비공개. HTTPS 가 아닌 접근은 거부
data "aws_iam_policy_document" "bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
  statement {
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "orbit-web-${var.env}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimized" { name = "Managed-CachingOptimized" }

# 보안 응답 헤더. CSP 는 위 local.csp (API · 사진 버킷 출처만 허용)
resource "aws_cloudfront_response_headers_policy" "this" {
  name = "orbit-web-${var.env}"
  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    content_security_policy {
      content_security_policy = local.csp
      override                = true
    }
  }
  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=()"
      override = true
    }
  }
}

# 별칭(www 등) → 주 주소 301. 별칭이 없으면 함수도 없다
resource "aws_cloudfront_function" "redirect" {
  count   = length(var.redirect_domains) > 0 ? 1 : 0
  name    = "orbit-web-${var.env}-redirect"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var req = event.request;
      if (req.headers.host && req.headers.host.value !== '${var.domain}') {
        var qs = Object.keys(req.querystring).length
          ? '?' + Object.keys(req.querystring).map(function (k) { return k + '=' + req.querystring[k].value; }).join('&')
          : '';
        return { statusCode: 301, statusDescription: 'Moved Permanently',
          headers: { location: { value: 'https://${var.domain}' + req.uri + qs } } };
      }
      return req;
    }
  JS
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "orbit ${var.env} web"
  aliases             = local.aliases
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # 한국 엣지 포함
  http_version        = "http2and3"

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id           = "s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.this.id
    compress                   = true

    dynamic "function_association" {
      for_each = aws_cloudfront_function.redirect
      content {
        event_type   = "viewer-request"
        function_arn = function_association.value.arn
      }
    }
  }

  # SPA: /timetable 같은 경로는 S3 에 객체가 없어 403(ListBucket 권한 없음) 또는 404 → index.html 을 200 으로 주고 라우터가 처리
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
    acm_certificate_arn      = var.cert_arn_use1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_route53_record" "this" {
  for_each = toset(local.aliases)
  zone_id  = var.zone_id
  name     = each.value
  type     = "A"
  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

# 배포 역할: 지정한 subject 의 GitHub Actions 만 (OIDC). 권한은 이 버킷과 이 배포의 무효화뿐
data "aws_iam_policy_document" "gh_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_subjects
    }
  }
}

resource "aws_iam_role" "gh" {
  name                 = "gh-web-${var.env}"
  assume_role_policy   = data.aws_iam_policy_document.gh_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "gh_deploy" {
  name = "web-deploy"
  role = aws_iam_role.gh.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.this.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.this.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"] # Get 은 완료 대기(waiter)
        Resource = aws_cloudfront_distribution.this.arn
      },
    ]
  })
}

output "bucket" { value = aws_s3_bucket.this.bucket }
output "distribution_id" { value = aws_cloudfront_distribution.this.id }
output "role_arn" { value = aws_iam_role.gh.arn }

# 사무실 웹 dev: https://dev.orbi-t.com ← web 레포 develop. 리소스는 modules/web-site
# API 는 dev-api 로 교차 출처 호출 → 서버 파라미터 /orbit/dev/CORS_ALLOWED_ORIGIN_PATTERNS 에 https://dev.orbi-t.com 이 있어야 한다
module "web" {
  source          = "../../modules/web-site"
  env             = "dev"
  domain          = "dev.orbi-t.com"
  cert_arn_use1   = local.shared.cert_arn_use1 # *.orbi-t.com
  zone_id         = local.shared.zone_id
  github_oidc_arn = local.shared.github_oidc_arn
  # 불변 subject: gh api repos/dino-product/web/actions/oidc/customization/sub
  github_subjects = [
    "repo:dino-product@324172954/web@1429959394:ref:refs/heads/develop",
    "repo:dino-product@324172954/web@1429959394:environment:dev",
  ]
  api_origin    = "https://dev-api.orbi-t.com"
  media_bucket  = module.media.bucket
  force_destroy = true
}

# 처음엔 이 파일에 직접 있던 리소스 → 모듈로 옮김 (재생성 없이)
moved {
  from = aws_s3_bucket.web
  to   = module.web.aws_s3_bucket.this
}
moved {
  from = aws_s3_bucket_public_access_block.web
  to   = module.web.aws_s3_bucket_public_access_block.this
}
moved {
  from = aws_s3_bucket_policy.web
  to   = module.web.aws_s3_bucket_policy.this
}
moved {
  from = aws_cloudfront_origin_access_control.web
  to   = module.web.aws_cloudfront_origin_access_control.this
}
moved {
  from = aws_cloudfront_distribution.web
  to   = module.web.aws_cloudfront_distribution.this
}
moved {
  from = aws_route53_record.web
  to   = module.web.aws_route53_record.this["dev.orbi-t.com"]
}
moved {
  from = aws_iam_role.gh_web_dev
  to   = module.web.aws_iam_role.gh
}
moved {
  from = aws_iam_role_policy.gh_web_deploy
  to   = module.web.aws_iam_role_policy.gh_deploy
}

output "web_bucket" { value = module.web.bucket }
output "web_distribution_id" { value = module.web.distribution_id }

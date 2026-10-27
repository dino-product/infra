# 사무실 웹 prod: https://orbi-t.com (www 는 301) ← web 레포 main. 리소스는 modules/web-site
# prod API(api.orbi-t.com) 가 뜨기 전까지 web 레포 변수 DEPLOY_PROD 는 꺼 둔다 → 버킷이 비어 있어 주소를 열면 빈 화면
# 서버 파라미터 /orbit/prod/CORS_ALLOWED_ORIGIN_PATTERNS 에 https://orbi-t.com 을 넣어야 한다 (14단계)
module "web" {
  source           = "../../modules/web-site"
  env              = "prod"
  domain           = "orbi-t.com"
  redirect_domains = ["www.orbi-t.com"]
  cert_arn_use1    = local.shared.cert_arn_use1 # orbi-t.com + *.orbi-t.com
  zone_id          = local.shared.zone_id
  github_oidc_arn  = local.shared.github_oidc_arn
  github_subjects = [
    "repo:dino-product@324172954/web@1429959394:ref:refs/heads/main",
    "repo:dino-product@324172954/web@1429959394:environment:prod",
  ]
  api_origin   = "https://api.orbi-t.com"
  media_bucket = "orbit-media-prod-${data.aws_caller_identity.current.account_id}" # 14단계 module "media" 가 만들 이름
}

data "aws_caller_identity" "current" {}

output "web_bucket" { value = module.web.bucket }
output "web_distribution_id" { value = module.web.distribution_id }

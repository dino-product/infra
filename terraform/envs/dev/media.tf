# 사진 저장 버킷 orbit-media-dev-<ACCOUNT_ID> (HM-353)
# 권한은 노드 역할에 붙는다. 파라미터 /orbit/dev/MEDIA_* 3개도 여기서 만든다 (terraform 소유)
module "media" {
  source         = "../../modules/media-bucket"
  env            = "dev"
  node_role_name = module.node.role_name
  web_origins    = ["https://dev.orbi-t.com"] # 사무실 웹(web.tf)이 서명 URL로 직접 올린다
}

output "media_bucket" {
  value = module.media.bucket
}

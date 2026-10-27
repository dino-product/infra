# 사진 저장 버킷 orbit-media-dev-<ACCOUNT_ID> (HM-353)
# 권한은 노드 역할에 붙는다. 파라미터 /orbit/dev/MEDIA_* 3개도 여기서 만든다 (terraform 소유)
module "media" {
  source         = "../../modules/media-bucket"
  env            = "dev"
  node_role_name = module.node.role_name
  # web_origins: 사무실 웹 dev 주소가 정해지면 추가 (예: ["https://dev.orbi-t.com"]). 비면 CORS 없음
}

output "media_bucket" {
  value = module.media.bucket
}

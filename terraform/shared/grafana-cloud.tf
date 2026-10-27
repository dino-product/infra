# Grafana Cloud (조직 dino · 스택 dino, 도쿄). 가입 · 스택 생성 · 관리 토큰 발급은 콘솔에서 했다
# 관리 토큰(정책 terraform: accesspolicies rwd · stacks r · stack-service-accounts w)은 /orbit/shared에 둔다
# → 팀원 권한(/orbit/dev/*만)으로는 읽지 못한다
data "aws_ssm_parameter" "grafana_cloud_tf_token" {
  name = "/orbit/shared/GRAFANA_CLOUD_TF_TOKEN"
}

provider "grafana" {
  alias                     = "cloud"
  cloud_access_policy_token = data.aws_ssm_parameter.grafana_cloud_tf_token.value
}

# 스택은 콘솔에서 만든 것을 읽기만 한다 (관리 토큰에 stacks 쓰기 · 삭제 권한이 없다)
data "grafana_cloud_stack" "main" {
  provider = grafana.cloud
  slug     = "dino"
}

# dev 클러스터 Alloy 전송 전용: 이 스택에 지표 · 로그 쓰기만 (읽기 · 삭제 X)
resource "grafana_cloud_access_policy" "alloy_dev" {
  provider     = grafana.cloud
  region       = data.grafana_cloud_stack.main.region_slug
  name         = "alloy-dev"
  display_name = "alloy-dev"
  scopes       = ["metrics:write", "logs:write"]

  realm {
    type       = "stack"
    identifier = data.grafana_cloud_stack.main.id
  }
}

# 만료 없음: 쓰기 전용이라 새어도 데이터를 읽거나 지울 수 없다. 교체는 -replace로 다시 만든다
resource "grafana_cloud_access_policy_token" "alloy_dev" {
  provider         = grafana.cloud
  region           = data.grafana_cloud_stack.main.region_slug
  access_policy_id = grafana_cloud_access_policy.alloy_dev.policy_id
  name             = "alloy-dev"
}

# ESO가 /orbit/dev/*를 읽어 Alloy용 Secret으로 만든다 (ExternalSecret은 platform/)
# 주소 · 사용자 ID는 비밀이 아니지만 Alloy가 한 Secret에서 읽도록 같은 경로에 둔다
locals {
  grafana_cloud_dev_params = {
    GRAFANA_CLOUD_PROM_URL  = data.grafana_cloud_stack.main.prometheus_remote_write_endpoint
    GRAFANA_CLOUD_PROM_USER = tostring(data.grafana_cloud_stack.main.prometheus_user_id)
    GRAFANA_CLOUD_LOKI_URL  = "${data.grafana_cloud_stack.main.logs_url}/loki/api/v1/push"
    GRAFANA_CLOUD_LOKI_USER = tostring(data.grafana_cloud_stack.main.logs_user_id)
  }
}

resource "aws_ssm_parameter" "grafana_cloud_dev" {
  for_each = local.grafana_cloud_dev_params
  name     = "/orbit/dev/${each.key}"
  type     = "String"
  value    = each.value
}

resource "aws_ssm_parameter" "grafana_cloud_dev_token" {
  name  = "/orbit/dev/GRAFANA_CLOUD_TOKEN"
  type  = "SecureString"
  value = grafana_cloud_access_policy_token.alloy_dev.token
}

output "grafana_cloud_stack_url" { value = data.grafana_cloud_stack.main.url }

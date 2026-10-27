# Grafana Cloud 스택 안 리소스: 알림 연락처 · 기본 정책 · 규칙 (클러스터 안 Grafana 프로비저닝 파일에서 옮겼다)
# 스택 Grafana API는 서비스 계정 토큰으로 부른다. 토큰은 state에만 있다
resource "grafana_cloud_stack_service_account" "terraform" {
  provider   = grafana.cloud
  stack_slug = data.grafana_cloud_stack.main.slug
  name       = "terraform"
  role       = "Admin"
}

resource "grafana_cloud_stack_service_account_token" "terraform" {
  provider           = grafana.cloud
  stack_slug         = data.grafana_cloud_stack.main.slug
  name               = "terraform"
  service_account_id = grafana_cloud_stack_service_account.terraform.id
}

provider "grafana" {
  alias = "stack"
  url   = data.grafana_cloud_stack.main.url
  auth  = grafana_cloud_stack_service_account_token.terraform.key
}

data "aws_ssm_parameter" "slack_webhook_dev" {
  name = "/orbit/dev/SLACK_WEBHOOK_URL"
}

resource "grafana_contact_point" "slack_dev" {
  provider = grafana.stack
  name     = "slack-dev"
  slack {
    url = data.aws_ssm_parameter.slack_webhook_dev.value
  }
}

# 스택에 정책 트리는 하나뿐이다 → 이 리소스가 기본 정책을 통째로 덮는다
resource "grafana_notification_policy" "main" {
  provider        = grafana.stack
  contact_point   = grafana_contact_point.slack_dev.name
  group_by        = ["grafana_folder", "alertname"]
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "4h"
}

resource "grafana_folder" "orbit" {
  provider = grafana.stack
  uid      = "orbit"
  title    = "orbit"
}

# 쿼리(A)를 즉시 평가하고 임계값(C)으로 판정. 데이터가 없으면 Normal(OK)
# 예외: 다운 규칙은 데이터가 없어도 알린다. 노드가 죽으면 Alloy도 같이 죽어 지표가 끊기기 때문
#   → dev 노드를 일부러 끌 때는 Grafana Cloud에서 사일런스를 건다
# 스택은 prod와 같이 쓸 것이라 쿼리마다 cluster를 건다 (Alloy external_labels)
locals {
  no_data_alerting = ["orbit-server 다운"]

  dev_rules = {
    "orbit-server 다운" = {
      expr     = "up{cluster=\"orbit-dev\",job=\"orbit-server\"}", op = "lt", threshold = 1, for = "2m"
      severity = "critical", summary = "orbit-server가 2분 넘게 응답하지 않거나 지표가 끊겼습니다 (노드 · Alloy 다운 포함)"
    }
    "5xx 비율 > 5%" = {
      expr     = "sum(rate(http_server_requests_seconds_count{cluster=\"orbit-dev\",job=\"orbit-server\",status=~\"5..\"}[5m])) / sum(rate(http_server_requests_seconds_count{cluster=\"orbit-dev\",job=\"orbit-server\"}[5m]))"
      op       = "gt", threshold = 0.05, for = "5m"
      severity = "critical", summary = "최근 5분 5xx 응답 비율이 5%를 넘었습니다"
    }
    "p95 > 1초" = {
      expr     = "histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{cluster=\"orbit-dev\",job=\"orbit-server\"}[5m])))"
      op       = "gt", threshold = 1, for = "10m"
      severity = "warning", summary = "API 응답 시간 p95가 10분 넘게 1초를 넘었습니다"
    }
    "노드 여유 메모리 < 10%" = {
      expr     = "node_memory_MemAvailable_bytes{cluster=\"orbit-dev\"} / node_memory_MemTotal_bytes{cluster=\"orbit-dev\"}"
      op       = "lt", threshold = 0.1, for = "10m"
      severity = "critical", summary = "dev 노드 MemAvailable이 10% 아래입니다 (OOM 위험)"
    }
    "디스크 사용률 > 80%" = {
      expr     = "1 - node_filesystem_avail_bytes{cluster=\"orbit-dev\",mountpoint=\"/\"} / node_filesystem_size_bytes{cluster=\"orbit-dev\",mountpoint=\"/\"}"
      op       = "gt", threshold = 0.8, for = "10m"
      severity = "warning", summary = "dev 노드 루트 디스크 사용률이 80%를 넘었습니다"
    }
    # 앱마다 하나씩 알린다 (name 라벨). 이름은 맨 뒤로 정렬되게 (앞 규칙 자리가 밀리지 않게). 자동 동기화가 계속 실패하면 OutOfSync로 남는다
    "배포 상태 이상 (Argo CD)" = {
      expr     = "max by (name) (argocd_app_info{cluster=\"orbit-dev\",health_status!~\"Healthy|Progressing\"} or argocd_app_info{cluster=\"orbit-dev\",sync_status!=\"Synced\"})"
      op       = "gt", threshold = 0, for = "15m"
      severity = "warning", summary = "Argo CD 앱 {{ $labels.name }}이 15분 넘게 Synced · Healthy가 아닙니다"
    }
  }
}

resource "grafana_rule_group" "orbit_dev" {
  provider         = grafana.stack
  name             = "orbit-dev"
  folder_uid       = grafana_folder.orbit.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.dev_rules
    content {
      name           = rule.key
      condition      = "C"
      for            = rule.value.for
      no_data_state  = contains(local.no_data_alerting, rule.key) ? "Alerting" : "OK"
      exec_err_state = "Error"
      labels         = { env = "dev", severity = rule.value.severity }
      annotations    = { summary = rule.value.summary }

      data {
        ref_id         = "A"
        datasource_uid = "grafanacloud-prom"
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({ refId = "A", instant = true, expr = rule.value.expr })
      }
      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "A"
          conditions = [{ evaluator = { type = rule.value.op, params = [rule.value.threshold] } }]
        })
      }
    }
  }
}

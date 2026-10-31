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
  # OOM 규칙은 "지속"이 아니라 "발생" → 평가 즉시 알린다 (for 0)

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
    # 과부하 징후 3종 — 이름은 기존 규칙 뒤로 정렬되게 "포화 징후:" 접두 (2026-10-27 부하 측정에서 OOMKilled 17회가 났는데 "다운" 알림만 울렸다)
    # 컨테이너 한도 OOM도 커널 oom_kill 카운터에 잡힌다 (node-exporter vmstat)
    "포화 징후: OOM 발생" = {
      expr     = "increase(node_vmstat_oom_kill{cluster=\"orbit-dev\"}[10m])"
      op       = "gt", threshold = 0, for = "0s"
      severity = "critical", summary = "dev 노드에서 최근 10분 사이 OOM kill이 {{ $value }}회 났습니다 (어느 컨테이너인지는 kubectl get pods · last state)"
    }
    # 풀 10개가 다 잡힌 채 기다리는 요청 수. 과부하 측정 때 최대 197 → 5가 2분이면 이미 포화 초입
    "포화 징후: DB 커넥션 대기" = {
      expr     = "max(hikaricp_connections_pending{cluster=\"orbit-dev\",job=\"orbit-server\"})"
      op       = "gt", threshold = 5, for = "2m"
      severity = "warning", summary = "orbit-server가 DB 커넥션을 기다리는 요청이 2분 넘게 5개를 넘습니다 (풀 포화 → 스레드 · 메모리 누적)"
    }
    # 앱 CPU 한도(1500m)가 있어도 노드 전체가 90%를 넘으면 etcd · kubelet이 느려진다
    "포화 징후: 노드 CPU > 90%" = {
      expr     = "1 - avg(rate(node_cpu_seconds_total{cluster=\"orbit-dev\",mode=\"idle\"}[5m]))"
      op       = "gt", threshold = 0.9, for = "10m"
      severity = "warning", summary = "dev 노드 CPU 사용률이 10분 넘게 90%를 넘었습니다 (t4g 버스트 초과 요금 · 제어부 지연)"
    }
    # 실시간 갱신(SSE) 경보 3종: Notion "실시간 화면 갱신(SSE) 설계" 운영 고려사항. 파드마다 따로 알린다
    # 연결 상한은 인스턴스 1,000 (2026-10-31 측정: 약 1,495 연결에서 cgroup OOM → 2,000에서 낮춤, server 반영 전까지는 2,000의 35%). 바꾸면 여기 700도 같이
    "실시간 연결 > 70%" = {
      expr     = "sum by (pod) (realtime_connections{cluster=\"orbit-dev\",job=\"orbit-server\"})"
      op       = "gt", threshold = 700, for = "5m"
      severity = "warning", summary = "{{ $labels.pod }} 실시간 연결이 상한 1,000의 70%를 넘었습니다"
    }
    # 기동 · 종료 때 잠깐 0이 된다 → 수집 주기(60초) 두 번을 넘길 때만
    "실시간 구독 끊김" = {
      expr     = "min by (pod) (realtime_subscription_listening{cluster=\"orbit-dev\",job=\"orbit-server\"})"
      op       = "lt", threshold = 1, for = "2m"
      severity = "warning", summary = "{{ $labels.pod }}가 Redis 실시간 채널을 구독하지 않습니다 (화면은 60초 주기 조회로만 갱신)"
    }
    # 구독 여부는 연결이 끊겨도 1로 남는다 → 발행은 됐는데 받은 신호가 0인 파드를 찾는다
    # 받은 적 없는 파드는 시계열이 없어 구독 지표로 0을 채운다. 지속 시간(15분)은 집계 구간(10분)보다 길게
    "실시간 신호 미수신" = {
      expr     = "((sum by (pod) (increase(realtime_signals_received_total{cluster=\"orbit-dev\",job=\"orbit-server\",result=\"delivered\"}[10m])) or 0 * max by (pod) (realtime_subscription_listening{cluster=\"orbit-dev\",job=\"orbit-server\"})) == bool 0) * on() group_left() (sum(increase(realtime_signals_published_total{cluster=\"orbit-dev\",job=\"orbit-server\",result=\"success\"}[10m])) > bool 0)"
      op       = "gt", threshold = 0, for = "15m"
      severity = "warning", summary = "{{ $labels.pod }}가 10분 동안 실시간 신호를 하나도 받지 못했습니다 (다른 파드는 발행 중)"
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

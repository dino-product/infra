# Grafana Cloud 대시보드 (폴더 orbit). JSON은 dashboards/build.py가 만든다
# 고칠 때: build.py 수정 → python3 terraform/shared/dashboards/build.py → apply (UI에서 고친 내용은 덮인다)
resource "grafana_dashboard" "orbit_overview" {
  provider    = grafana.stack
  folder      = grafana_folder.orbit.uid
  config_json = file("${path.module}/dashboards/orbit-overview.json")
  overwrite   = true
}

output "grafana_dashboard_url" { value = grafana_dashboard.orbit_overview.url }

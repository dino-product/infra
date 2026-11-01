#!/usr/bin/env python3
"""Grafana Cloud 대시보드 JSON을 만든다. 고친 뒤: python3 terraform/shared/dashboards/build.py → terraform apply
UI에서 고친 내용은 다음 apply 때 덮인다 → 여기서 고친다
"""
import json
import pathlib

PROM = {"type": "prometheus", "uid": "grafanacloud-prom"}
LOKI = {"type": "loki", "uid": "grafanacloud-logs"}
C = 'cluster="$cluster"'
APP = f'{C},job="orbit-server"'
NODE = C
HTTP = f"http_server_requests_seconds_count{{{APP}}}"

panels = []
_y = 0
_x = 0
_row_h = 0
_id = 0


def _next_id():
    global _id
    _id += 1
    return _id


def row(title):
    global _y, _x, _row_h
    _y += _row_h
    _x, _row_h = 0, 0
    panels.append({"type": "row", "title": title, "id": _next_id(), "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": _y}, "panels": []})
    _y += 1


def _place(w, h):
    global _y, _x, _row_h
    if _x + w > 24:
        _y += _row_h
        _x, _row_h = 0, 0
    pos = {"h": h, "w": w, "x": _x, "y": _y}
    _x += w
    _row_h = max(_row_h, h)
    return pos


def _targets(queries, instant=False, fmt=None):
    out = []
    for i, q in enumerate(queries):
        expr, legend = q if isinstance(q, tuple) else (q, "")
        t = {"refId": chr(65 + i), "expr": expr, "legendFormat": legend, "datasource": PROM}
        if instant:
            t["instant"], t["range"] = True, False
        if fmt:
            t["format"] = fmt
        out.append(t)
    return out


def _steps(steps):
    # steps: [(값 또는 None, 색)] — None은 기본값
    return {"mode": "absolute", "steps": [{"value": v, "color": c} for v, c in steps]}


def stat(title, expr, unit="none", steps=None, desc="", w=6, h=4, mappings=None, decimals=None):
    d = {"unit": unit, "thresholds": _steps(steps or [(None, "green")]), "color": {"mode": "thresholds"}}
    if mappings:
        d["mappings"] = mappings
    if decimals is not None:
        d["decimals"] = decimals
    panels.append({
        "type": "stat", "title": title, "description": desc, "id": _next_id(), "datasource": PROM,
        "gridPos": _place(w, h), "targets": _targets([expr], instant=True),
        "fieldConfig": {"defaults": d, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "none", "textMode": "value",
                    "justifyMode": "center", "orientation": "auto"},
    })


def ts(title, queries, unit="none", desc="", w=8, h=8, stack=False, steps=None, min0=True, overrides=None):
    custom = {"lineWidth": 1, "fillOpacity": 25 if stack else 8, "showPoints": "never",
              "spanNulls": True, "stacking": {"mode": "normal" if stack else "none", "group": "A"}}
    d = {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"}}
    if min0:
        d["min"] = 0
    if steps:
        d["thresholds"] = _steps(steps)
        custom["thresholdsStyle"] = {"mode": "dashed"}
    panels.append({
        "type": "timeseries", "title": title, "description": desc, "id": _next_id(), "datasource": PROM,
        "gridPos": _place(w, h), "targets": _targets(queries),
        "fieldConfig": {"defaults": d, "overrides": overrides or []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    })


def limit_line(name):
    # 한도 시계열은 빨간 점선
    return {"matcher": {"id": "byName", "options": name}, "properties": [
        {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}},
        {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [6, 4]}},
        {"id": "custom.fillOpacity", "value": 0},
        {"id": "custom.stacking", "value": {"mode": "none", "group": "A"}}]}


def table(title, queries, desc="", w=12, h=8, organize=None, overrides=None, sort=None):
    tr = [{"id": "merge", "options": {}}]
    if organize:
        tr.append({"id": "organize", "options": organize})
    p = {"type": "table", "title": title, "description": desc, "id": _next_id(), "datasource": PROM,
         "gridPos": _place(w, h), "targets": _targets(queries, instant=True, fmt="table"),
         "transformations": tr,
         "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": overrides or []},
         "options": {"showHeader": True, "cellHeight": "sm"}}
    if sort:
        p["options"]["sortBy"] = [{"displayName": sort, "desc": True}]
    panels.append(p)


def unit_override(name, unit, decimals=None):
    props = [{"id": "unit", "value": unit}]
    if decimals is not None:
        props.append({"id": "decimals", "value": decimals})
    return {"matcher": {"id": "byName", "options": name}, "properties": props}


def logs(title, expr, desc="", w=24, h=10):
    panels.append({
        "type": "logs", "title": title, "description": desc, "id": _next_id(), "datasource": LOKI,
        "gridPos": _place(w, h),
        "targets": [{"refId": "A", "expr": expr, "datasource": LOKI, "queryType": "range"}],
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                    "enableLogDetails": True, "dedupStrategy": "none", "prettifyLogMessage": False},
    })


# ---------- 한눈에 보기 ----------
row("한눈에 보기")
stat("앱 상태", f"min(up{{{APP}}})", desc="orbit-server가 지표 수집에 응답하는지. 0이면 다운",
     mappings=[{"type": "value", "options": {"1": {"text": "정상", "color": "green"},
                                             "0": {"text": "다운", "color": "red"}}},
               {"type": "special", "options": {"match": "null", "result": {"text": "지표 없음", "color": "red"}}}],
     steps=[(None, "red"), (1, "green")])
stat("요청 / 초", f"sum(rate({HTTP}[5m]))", unit="reqps", decimals=1, desc="최근 5분 평균 API 요청 수",
     steps=[(None, "blue")])
stat("오류율 (5xx)", f'(sum(rate(http_server_requests_seconds_count{{{APP},status=~"5..",status!="503"}}[5m])) or vector(0)) / sum(rate({HTTP}[5m]))',
     unit="percentunit", decimals=2, desc="503(의도한 과부하 거절) 제외. 알림 기준 5%",
     steps=[(None, "green"), (0.01, "orange"), (0.05, "red")])
stat("p95 응답 시간", f"histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{{{APP}}}[5m])))",
     unit="s", decimals=2, desc="요청 95%가 이 시간 안에 끝난다. 알림 기준 1초",
     steps=[(None, "green"), (0.5, "orange"), (1, "red")])
stat("과부하 거절 (503)", f'(sum(rate(http_server_requests_seconds_count{{{APP},status="503"}}[5m])) or vector(0)) / sum(rate({HTTP}[5m]))',
     unit="percentunit", decimals=1, desc="서버가 일부러 거절한 비율 (보드 동시 조회 상한 · DB 커넥션 대기). 알림 기준 10%",
     steps=[(None, "green"), (0.01, "orange"), (0.1, "red")])
stat("재시작 (24시간)", f'sum(increase(kube_pod_container_status_restarts_total{{{C},namespace="orbit-dev"}}[24h])) or vector(0)',
     decimals=0, desc="orbit-dev 컨테이너 재시작 횟수 (OOM · 기동 실패 · liveness 실패)",
     steps=[(None, "green"), (1, "orange"), (5, "red")])
stat("노드 여유 메모리", f"min(node_memory_MemAvailable_bytes{{{NODE}}} / node_memory_MemTotal_bytes{{{NODE}}})",
     unit="percentunit", decimals=0, desc="MemAvailable / 전체. 알림 기준 10%",
     steps=[(None, "red"), (0.1, "orange"), (0.2, "green")])
stat("배포 이상 앱", f'count(argocd_app_info{{{C},health_status!~"Healthy|Progressing"}} or argocd_app_info{{{C},sync_status!="Synced"}}) or vector(0)',
     decimals=0, desc="Argo CD에서 Synced · Healthy가 아닌 앱 수. 아래 '쿠버네티스 · 배포'에서 앱 이름",
     steps=[(None, "green"), (1, "red")])

# ---------- API ----------
row("API")
ts("초당 요청 (상태 코드별)",
   [(f'sum by (code) (label_replace(rate({HTTP}[5m]), "code", "${{1}}xx", "status", "([0-9]).."))', "{{code}}")],
   unit="reqps", stack=True, w=12, desc="2xx 정상 · 4xx 클라이언트 오류(인증 · 검증) · 5xx 서버 오류(503은 과부하 거절)",
   overrides=[{"matcher": {"id": "byName", "options": n}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
              for n, c in [("2xx", "green"), ("3xx", "blue"), ("4xx", "orange"), ("5xx", "red")]])
ts("응답 시간", [(f"histogram_quantile({q}, sum by (le) (rate(http_server_requests_seconds_bucket{{{APP}}}[5m])))", n)
             for q, n in [(0.5, "p50"), (0.95, "p95"), (0.99, "p99")]],
   unit="s", w=12, desc="빨간 점선이 알림 기준(p95 1초)", steps=[(None, "transparent"), (1, "red")])
table("엔드포인트별 (최근 1시간)", [
    (f"sum by (method, uri) (increase({HTTP}[1h])) > 0", ""),
    (f"histogram_quantile(0.95, sum by (method, uri, le) (rate(http_server_requests_seconds_bucket{{{APP}}}[1h]))) > 0", ""),
    (f'sum by (method, uri) (increase(http_server_requests_seconds_count{{{APP},status=~"4.."}}[1h]))', ""),
    (f'sum by (method, uri) (increase(http_server_requests_seconds_count{{{APP},status=~"5.."}}[1h]))', ""),
], w=24, h=9, desc="느린 · 실패하는 엔드포인트 찾기. 열 머리를 눌러 정렬",
   organize={"excludeByName": {"Time": True},
             "renameByName": {"method": "메서드", "uri": "경로", "Value #A": "요청", "Value #B": "p95",
                              "Value #C": "4xx", "Value #D": "5xx"},
             "indexByName": {"method": 0, "uri": 1, "Value #A": 2, "Value #B": 3, "Value #C": 4, "Value #D": 5}},
   overrides=[unit_override("요청", "short", 0), unit_override("p95", "s", 3),
              unit_override("4xx", "short", 0), unit_override("5xx", "short", 0)],
   sort="요청")

# ---------- 앱 ----------
row("앱 (메모리 · CPU · JVM)")
ts("컨테이너 메모리 vs 한도", [
    (f'sum by (pod) (container_memory_working_set_bytes{{{C},namespace="orbit-dev",container="app"}})', "{{pod}}"),
    (f'max(kube_pod_container_resource_limits{{{C},namespace="orbit-dev",container="app",resource="memory"}})', "한도"),
], unit="bytes", desc="한도(768Mi)에 닿으면 OOMKilled. 한도는 올리지 않는 원칙 (노드 위험)", overrides=[limit_line("한도")])
ts("CPU vs 한도", [
    (f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{C},namespace="orbit-dev",container="app"}}[5m]))', "{{pod}}"),
    (f'max(kube_pod_container_resource_limits{{{C},namespace="orbit-dev",container="app",resource="cpu"}})', "한도"),
], unit="none", desc="코어 수. 한도 1.5코어에 붙어 있으면 스로틀링으로 느려진다", overrides=[limit_line("한도")])
ts("JVM 힙", [
    (f'sum by (pod) (jvm_memory_used_bytes{{{APP},area="heap"}})', "사용 {{pod}}"),
    (f'sum by (pod) (jvm_memory_committed_bytes{{{APP},area="heap"}})', "확보 {{pod}}"),
    (f'max(sum by (pod) (jvm_memory_max_bytes{{{APP},area="heap"}}))', "최대"),
], unit="bytes", desc="톱니 모양이 정상 (GC). 바닥이 계속 오르면 누수 의심", overrides=[limit_line("최대")])
ts("GC 일시 정지", [
    (f"sum by (pod) (rate(jvm_gc_pause_seconds_sum{{{APP}}}[5m]))", "{{pod}}"),
], unit="percentunit", desc="1초 중 GC로 멈춘 비율. 5%를 넘으면 힙이 부족하다")
ts("톰캣 스레드", [
    (f"sum by (pod) (tomcat_threads_busy_threads{{{APP}}})", "사용 중 {{pod}}"),
    (f"max(tomcat_threads_config_max_threads{{{APP}}})", "최대"),
], desc="최대에 붙으면 요청이 줄을 선다", overrides=[limit_line("최대")])
ts("오류 · 경고 로그 수", [
    (f'sum by (level) (rate(logback_events_total{{{APP},level=~"error|warn"}}[5m])) * 60', "{{level}}"),
], unit="short", desc="분당 건수. 내용은 맨 아래 '로그'",
   overrides=[{"matcher": {"id": "byName", "options": "error"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]},
              {"matcher": {"id": "byName", "options": "warn"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}]}])

# ---------- DB · Redis ----------
row("DB · Redis")
ts("DB 커넥션 풀", [
    (f"sum(hikaricp_connections_active{{{APP}}})", "사용 중"),
    (f"sum(hikaricp_connections_idle{{{APP}}})", "대기(유휴)"),
    (f"sum(hikaricp_connections_pending{{{APP}}})", "커넥션 기다리는 요청"),
    (f"max(hikaricp_connections_max{{{APP}}})", "최대"),
], desc="'커넥션 기다리는 요청'이 2분 넘게 5를 넘으면 알림", overrides=[limit_line("최대")])
ts("DB 커넥션 얻는 시간", [
    (f"sum(rate(hikaricp_connections_acquire_seconds_sum{{{APP}}}[5m])) / sum(rate(hikaricp_connections_acquire_seconds_count{{{APP}}}[5m]))", "평균"),
    (f"sum(rate(hikaricp_connections_timeout_total{{{APP}}}[5m])) * 60", "타임아웃 / 분"),
], unit="s", desc="풀이 넉넉하면 거의 0", overrides=[unit_override("타임아웃 / 분", "short")])
ts("Redis 명령", [
    (f"sum(rate(lettuce_seconds_count{{{APP}}}[5m]))", "명령 / 초"),
    (f"sum(rate(lettuce_seconds_sum{{{APP}}}[5m])) / sum(rate(lettuce_seconds_count{{{APP}}}[5m]))", "평균 지연"),
], desc="Redis는 인증 상태(토큰 폐기 · nonce)와 실시간 신호에 쓴다",
   overrides=[unit_override("명령 / 초", "ops"), unit_override("평균 지연", "s")])

# ---------- 실시간 (SSE) ----------
row("실시간 (SSE)")
ts("실시간 연결 수", [
    (f"sum by (client) (realtime_connections{{{APP}}})", "{{client}}"),
], stack=True, desc="파드당 상한 1,000. 700(70%)을 5분 넘으면 알림", steps=[(None, "transparent"), (700, "orange"), (1000, "red")])
ts("연결 열림 · 닫힘 · 거절", [
    (f"sum(rate(realtime_connections_opened_total{{{APP}}}[5m])) * 60", "열림"),
    (f"sum(rate(realtime_connections_closed_total{{{APP}}}[5m])) * 60", "닫힘"),
    (f"sum(rate(realtime_connections_rejected_total{{{APP}}}[5m])) * 60", "거절"),
], unit="short", desc="분당 건수. 거절이 보이면 상한에 닿은 것")
ts("신호 발행 · 수신", [
    (f"sum by (result) (rate(realtime_signals_published_total{{{APP}}}[5m])) * 60", "발행 {{result}}"),
    (f"sum by (result) (rate(realtime_signals_received_total{{{APP}}}[5m])) * 60", "수신 {{result}}"),
    (f"min(realtime_subscription_listening{{{APP}}})", "구독 중 (1)"),
], unit="short", desc="분당 건수. 발행은 있는데 수신이 0이면 Redis 구독이 끊긴 것")

# ---------- 노드 ----------
row("노드 (EC2 t4g.medium)")
ts("CPU 사용률", [
    (f'1 - avg(rate(node_cpu_seconds_total{{{NODE},mode="idle"}}[5m]))', "사용률"),
], unit="percentunit", desc="90%를 10분 넘으면 알림. t4g는 오래 쓰면 크레딧 초과 요금",
   steps=[(None, "transparent"), (0.9, "red")])
ts("메모리", [
    (f"sum(node_memory_MemTotal_bytes{{{NODE}}}) - sum(node_memory_MemAvailable_bytes{{{NODE}}})", "사용"),
    (f"sum(node_memory_MemTotal_bytes{{{NODE}}})", "전체"),
    (f"sum(node_memory_SwapTotal_bytes{{{NODE}}}) - sum(node_memory_SwapFree_bytes{{{NODE}}})", "스왑 사용"),
], unit="bytes", desc="여유가 10% 아래로 10분이면 알림", overrides=[limit_line("전체")])
ts("디스크 사용률 (/)", [
    (f'1 - node_filesystem_avail_bytes{{{NODE},mountpoint="/"}} / node_filesystem_size_bytes{{{NODE},mountpoint="/"}}', "사용률"),
], unit="percentunit", desc="80% 넘으면 알림. 대개 쌓인 이미지 → crictl rmi --prune",
   steps=[(None, "transparent"), (0.8, "red")])
ts("네트워크", [
    (f"sum(rate(node_network_receive_bytes_total{{{NODE},device!~\"lo|veth.*|cni.*|flannel.*\"}}[5m]))", "받음"),
    (f"sum(rate(node_network_transmit_bytes_total{{{NODE},device!~\"lo|veth.*|cni.*|flannel.*\"}}[5m]))", "보냄"),
], unit="Bps")
ts("디스크 I/O", [
    (f"sum(rate(node_disk_read_bytes_total{{{NODE}}}[5m]))", "읽기"),
    (f"sum(rate(node_disk_written_bytes_total{{{NODE}}}[5m]))", "쓰기"),
], unit="Bps")
ts("자원 압박 · OOM", [
    (f"rate(node_pressure_cpu_waiting_seconds_total{{{NODE}}}[5m])", "CPU 대기"),
    (f"rate(node_pressure_memory_waiting_seconds_total{{{NODE}}}[5m])", "메모리 대기"),
    (f"rate(node_pressure_io_waiting_seconds_total{{{NODE}}}[5m])", "I/O 대기"),
    (f"increase(node_vmstat_oom_kill{{{NODE}}}[5m])", "OOM kill (5분)"),
], unit="percentunit", desc="작업이 자원을 기다린 시간 비율(PSI). OOM kill은 건수 (나면 알림)",
   overrides=[unit_override("OOM kill (5분)", "short", 0)])

# ---------- 쿠버네티스 · 배포 ----------
row("쿠버네티스 · 배포")
ts("컨테이너별 메모리 (상위 8)", [
    (f'topk(8, sum by (namespace, container) (container_memory_working_set_bytes{{{C},container!=""}}))', "{{namespace}}/{{container}}"),
], unit="bytes", stack=True, w=12, desc="노드 메모리를 누가 쓰는지")
ts("재시작 (1시간 단위)", [
    (f'sum by (namespace, container) (increase(kube_pod_container_status_restarts_total{{{C}}}[1h])) > 0', "{{namespace}}/{{container}}"),
], unit="short", w=12, desc="재시작 이유는 아래 표 · kubectl describe")
table("Argo CD 앱", [(f"max by (name, sync_status, health_status) (argocd_app_info{{{C}}})", "")],
      w=12, desc="모두 Synced · Healthy면 정상",
      organize={"excludeByName": {"Time": True, "Value": True},
                "renameByName": {"name": "앱", "sync_status": "동기화", "health_status": "상태"},
                "indexByName": {"name": 0, "sync_status": 1, "health_status": 2}},
      overrides=[{"matcher": {"id": "byName", "options": c}, "properties": [
          {"id": "custom.cellOptions", "value": {"type": "color-text"}},
          {"id": "mappings", "value": [{"type": "value", "options": {
              "Synced": {"color": "green"}, "Healthy": {"color": "green"}, "Progressing": {"color": "blue"},
              "OutOfSync": {"color": "orange"}, "Degraded": {"color": "red"}, "Missing": {"color": "red"}}}]}]}
          for c in ["동기화", "상태"]])
table("문제 있는 컨테이너", [
    (f"max by (namespace, pod, container, reason) (kube_pod_container_status_waiting_reason{{{C}}}) > 0", ""),
    (f"max by (namespace, pod, container, reason) (kube_pod_container_status_last_terminated_reason{{{C}}}) > 0", ""),
], w=12, desc="대기 중(CrashLoopBackOff · ImagePullBackOff)이거나 마지막 종료 이유(OOMKilled · Error)가 남은 컨테이너. 비어 있으면 정상",
   organize={"excludeByName": {"Time": True, "Value #A": True, "Value #B": True},
             "renameByName": {"namespace": "네임스페이스", "pod": "Pod", "container": "컨테이너", "reason": "이유"}})

# ---------- 로그 ----------
row("로그")
logs("orbit-server 오류 · 경고 로그",
     '{cluster="$cluster", namespace="orbit-dev", container="app"} |~ " (ERROR|WARN) "',
     desc="최신순. 전체 로그는 Explore → logs. 이메일 · 전화번호 · 토큰은 가려져 있다")

dashboard = {
    "uid": "orbit-overview",
    "title": "Orbit 서버 개요",
    "description": "orbit-server · 노드 · 배포 상태. 코드: infra terraform/shared/dashboards/build.py (UI 수정은 apply 때 덮인다)",
    "tags": ["orbit"],
    "timezone": "browser",
    "refresh": "1m",
    "time": {"from": "now-6h", "to": "now"},
    "schemaVersion": 39,
    "editable": True,
    "graphTooltip": 1,
    "templating": {"list": [{
        "name": "cluster", "label": "환경", "type": "query", "datasource": PROM,
        "query": {"query": "label_values(up{job=\"orbit-server\"}, cluster)", "refId": "cluster"},
        "definition": "label_values(up{job=\"orbit-server\"}, cluster)",
        "current": {"text": "orbit-dev", "value": "orbit-dev"}, "refresh": 2, "sort": 1,
    }]},
    "annotations": {"list": []},
    "links": [],
    "panels": panels,
}

out = pathlib.Path(__file__).with_name("orbit-overview.json")
out.write_text(json.dumps(dashboard, ensure_ascii=False, indent=2) + "\n")
print(f"{out.name}: 패널 {sum(p['type'] != 'row' for p in panels)}개")

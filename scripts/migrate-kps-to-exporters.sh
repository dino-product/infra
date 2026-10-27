#!/bin/bash
# kube-prometheus-stack(릴리스 kps) → exporter 2개 + ServiceMonitor CRD 전환 뒤, 남은 kps 리소스를 지운다 (2026-10-28, 한 번만)
# 로컬에서: KUBECONFIG=~/.kube/orbit-dev.yaml (SSM 터널) 상태로, PR이 main에 머지되고 새 앱(node-exporter · kube-state-metrics · monitoring-crds)이 Healthy인 뒤 실행
# Argo CD Application은 finalizer가 없어 앱이 지워져도 리소스는 남는다 → 직접 지운다. ServiceMonitor CRD는 monitoring-crds 앱이 넘겨받으므로 지우지 않는다
set -euo pipefail

kubectl -n argocd get application node-exporter kube-state-metrics monitoring-crds -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
kubectl -n argocd get application kps >/dev/null 2>&1 && { echo "kps Application이 아직 있습니다 (root-dev 동기화 대기)" >&2; exit 1; }

# 1) 릴리스 kps가 만든 것 (exporter 2개 · ServiceMonitor 4개 · RBAC)
kubectl -n monitoring delete deploy,ds,svc,sa,servicemonitor -l app.kubernetes.io/instance=kps --ignore-not-found
kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/instance=kps --ignore-not-found
# 2) operator가 만들었던 kubelet · etcd 수집 대상 (Alloy가 노드를 찾아 직접 긁는다, alloy-values.yaml)
kubectl -n kube-system delete svc,endpoints kps-kube-prometheus-stack-kubelet kps-kube-prometheus-stack-kube-etcd --ignore-not-found
# 3) 쓰지 않는 Prometheus Operator CRD 9개 (servicemonitors는 남긴다). 이 종류의 객체는 없다
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com alertmanagers.monitoring.coreos.com podmonitors.monitoring.coreos.com \
  probes.monitoring.coreos.com prometheusagents.monitoring.coreos.com prometheuses.monitoring.coreos.com \
  prometheusrules.monitoring.coreos.com scrapeconfigs.monitoring.coreos.com thanosrulers.monitoring.coreos.com --ignore-not-found
# 4) helm 릴리스 기록 (Argo CD는 helm template으로 적용해 릴리스 Secret은 처음 설치 때 것만 남아 있다)
kubectl -n monitoring delete secret -l name=kps,owner=helm --ignore-not-found

echo "완료. 남은 것:"; kubectl get crd | grep monitoring.coreos.com; kubectl -n monitoring get servicemonitor

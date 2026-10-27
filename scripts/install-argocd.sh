#!/bin/bash
# Argo CD를 설치 · 업그레이드하고 루트 앱을 건다 (dev)
# 로컬에서: AWS_PROFILE=orbit-admin, KUBECONFIG=~/.kube/orbit-dev.yaml (SSM 터널) 상태로 실행
#   bash scripts/install-argocd.sh
# 비밀번호 해시는 SSM에서 읽는다 (terraform/envs/dev/argocd.tf). 값 자체는 출력하지 않는다
set -euo pipefail
cd "$(dirname "$0")/.."

CHART_VERSION=10.11.6
get() { aws ssm get-parameter --region ap-northeast-2 --with-decryption \
  --name "$1" --query Parameter.Value --output text; }
ADMIN_HASH=$(get /orbit/shared/ARGOCD_DEV_ADMIN_BCRYPT)
GITHUB_SECRET=$(get /orbit/shared/ARGOCD_DEV_GITHUB_CLIENT_SECRET)   # GitHub OAuth 앱 (팀원 로그인)

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$CHART_VERSION" \
  -n argocd --create-namespace -f argocd/values.yaml \
  --set-string "configs.secret.argocdServerAdminPassword=${ADMIN_HASH}" \
  --set-string "configs.secret.extra.dex\.github\.clientSecret=${GITHUB_SECRET}" \
  --rollback-on-failure --timeout 10m

# 레포 접근 키(ESO)를 먼저 만들고 루트 앱을 건다. 이후 platform 앱이 이 ExternalSecret을 넘겨받는다
kubectl apply -f platform/argocd-repo-secret.yaml
kubectl apply -f argocd/root-dev.yaml

#!/bin/bash
# 공개 주소 라우트(platform/edge-<env>.yaml)에 비밀 헤더 값을 채워 적용한다
# 로컬에서: AWS_PROFILE=orbit-admin, KUBECONFIG=~/.kube/orbit-dev.yaml (SSM 터널) 상태로 실행
#   bash scripts/apply-edge.sh dev
# ORIGIN_VERIFY가 바뀌거나 공개 주소를 더할 때만 다시 돌린다
set -euo pipefail

ENV=${1:?"dev 또는 prod를 인자로 주세요"}
cd "$(dirname "$0")/.."

OV=$(aws ssm get-parameter --region ap-northeast-2 --with-decryption \
  --name "/orbit/${ENV}/ORIGIN_VERIFY" --query Parameter.Value --output text)

# 앱 네임스페이스가 아직 없으면(첫 배포 전) 만든다
kubectl create namespace "orbit-${ENV}" --dry-run=client -o yaml | kubectl apply -f -
sed "s|\${ORIGIN_VERIFY}|${OV}|" "platform/edge-${ENV}.yaml" | kubectl apply -f -

#!/bin/bash
# orbit-server를 helm으로 배포한다 (11-3)
# 노드에서 root로 실행: bash /opt/orbit/scripts/deploy.sh <dev|prod> <image-tag>
#   - 배포 job(server 레포)이 SSM Run Command로 번들을 /opt/orbit에 풀고 이 스크립트를 부른다
#   - 새 Pod가 10분 안에 Ready가 안 되면 helm이 이전 릴리스로 되돌리고 실패를 반환한다 → Actions 빨간불
set -euo pipefail

ENV=${1:?"dev 또는 prod를 인자로 주세요"}
TAG=${2:?"이미지 태그(server 커밋 SHA)를 인자로 주세요"}
[[ $ENV == dev || $ENV == prod ]] || { echo "ENV는 dev 또는 prod" >&2; exit 1; }
[[ $TAG =~ ^[0-9a-f]{7,40}$ ]] || { echo "이미지 태그는 커밋 SHA여야 합니다: $TAG" >&2; exit 1; }

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export AWS_DEFAULT_REGION=ap-northeast-2
NS="orbit-${ENV}"
cd "$(dirname "$0")/.."   # 번들 루트 (charts/ · scripts/ · platform/)

# 실패하면 원인을 Actions 로그에서 바로 보이게 남긴다 (Run Command 출력은 앞부분만 보이므로 짧게)
on_fail() {
  echo "::group::배포 실패 진단"
  kubectl -n "$NS" get pods -o wide || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 15 || true
  kubectl -n "$NS" logs deploy/orbit-server -c app --previous --tail=200 2>/dev/null \
    | grep -E "ERROR|Exception|Caused by" | tail -n 15 || true
  echo "::endgroup::"
}
trap on_fail ERR

OV=$(aws ssm get-parameter --name "/orbit/${ENV}/ORIGIN_VERIFY" --with-decryption \
  --query Parameter.Value --output text)

echo "deploy ${NS} orbit-server:${TAG} (helm $(helm version --short))"
helm upgrade --install orbit-server charts/orbit-server \
  -n "$NS" --create-namespace \
  -f "charts/orbit-server/values-${ENV}.yaml" \
  --set image.tag="${TAG}" --set-string originVerify="${OV}" \
  --rollback-on-failure --timeout 10m   # 실패하면 이전 버전으로 되돌린다 (wait 포함)

kubectl -n "$NS" get pods -o wide
helm -n "$NS" history orbit-server --max 3

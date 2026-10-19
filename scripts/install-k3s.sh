#!/bin/bash
# k3s 단일 노드 설치 (내장 etcd + S3 스냅샷)
# 사용법: sudo K3S_VERSION=v1.36.5+k3s1 bash install-k3s.sh dev
#   - K3S_VERSION은 dev · prod가 같은 값을 쓴다. 버전을 올릴 때는 한 마이너씩 (13단계)
#   - 다시 실행해도 된다: config.yaml을 새로 쓰고 같은 버전으로 재설치
set -euo pipefail

ENV=${1:?"dev 또는 prod를 인자로 주세요"}
: "${K3S_VERSION:?"K3S_VERSION을 지정하세요 (예: v1.36.5+k3s1)"}"
[[ $ENV == dev || $ENV == prod ]] || { echo "ENV는 dev 또는 prod" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "root로 실행하세요 (sudo)" >&2; exit 1; }

# 계정 ID와 노드 사설 IP (IMDSv2)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
NODE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
echo "env=$ENV account=$ACCOUNT_ID node-ip=$NODE_IP k3s=$K3S_VERSION"

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
cluster-init: true
node-ip: ${NODE_IP}
write-kubeconfig-mode: "0600"
etcd-expose-metrics: true          # 12단계 Prometheus가 :2381에서 etcd 지표를 긁는다
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 20
etcd-s3: true                      # 액세스 키 없음 → 노드 IAM 역할로 인증
etcd-s3-bucket: orbit-etcd-${ACCOUNT_ID}
etcd-s3-region: ap-northeast-2
etcd-s3-folder: ${ENV}
EOF

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server

# 노드가 Ready가 될 때까지 최대 2분
for _ in $(seq 1 24); do
  if k3s kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    k3s kubectl get nodes -o wide
    exit 0
  fi
  sleep 5
done
echo "노드가 2분 안에 Ready가 되지 않았습니다. journalctl -u k3s -n 100 으로 확인하세요" >&2
exit 1

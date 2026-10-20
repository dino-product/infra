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

# ECR 자격 증명 플러그인: k3s가 시작할 때 이 두 경로가 있으면 kubelet에 붙인다 (7단계)
# v1.36.x는 공식 아티팩트에 바이너리가 없어서 v1.37.0을 쓴다 (kubelet과는 안정 API v1로만 통신)
ECR_CP_VER=v1.37.0
mkdir -p /var/lib/rancher/credentialprovider/bin
curl -sfSL -o /var/lib/rancher/credentialprovider/bin/ecr-credential-provider \
  "https://artifacts.k8s.io/binaries/cloud-provider-aws/${ECR_CP_VER}/linux/arm64/ecr-credential-provider-linux-arm64"
chmod +x /var/lib/rancher/credentialprovider/bin/ecr-credential-provider
cat > /var/lib/rancher/credentialprovider/config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server

# helm: 배포 job이 SSM으로 노드에서 deploy.sh를 실행할 때 쓴다 (11단계). 로컬과 같은 메이저(v4)로 고정
HELM_VER=v4.3.1
curl -sfSL "https://get.helm.sh/helm-${HELM_VER}-linux-arm64.tar.gz" | tar -xz -C /tmp linux-arm64/helm
install -m 0755 /tmp/linux-arm64/helm /usr/local/bin/helm
rm -rf /tmp/linux-arm64

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

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
# 노드 예약: k3s 서버(제어부 + 내장 etcd, 실측 약 1.3GB)와 OS 몫을 Pod가 못 쓰게 한다
#   - 스케줄러가 보는 Pod용 메모리 = 3.8GiB - 1Gi - 256Mi - 200Mi ≈ 2.3GiB (요청 합이 이걸 넘으면 Pod가 Pending → prod를 같은 노드에 올릴 때 신호)
#   - kubelet이 pods cgroup에 한도(capacity - 예약)를 걸어 Pod 전체가 k3s 메모리를 밀어내지 못한다 (2026-10-27 부하 때 스왑 900MiB가 이 경우)
#   - memory.available < 200Mi면 요청보다 많이 쓰는 Pod부터 축출한다 (커널 OOM보다 먼저, 깔끔하게)
kubelet-arg:
  - "kube-reserved=cpu=300m,memory=1Gi"
  - "system-reserved=cpu=100m,memory=256Mi"
  - "eviction-hard=memory.available<200Mi,nodefs.available<5%,imagefs.available<5%"
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

# k3s 서버(Go)의 메모리 상한: 2026-10-31 부하 측정에서 k3s-server가 살아있는 힙 524Mi에 GC 여유분까지 RSS 1.46GiB + 스왑 0.5GiB를 쥐다가
#   etcd 응답이 7~9초로 늘어 리더 임대 갱신에 실패해 종료(재시작)됐다. GOMEMLIMIT을 주면 Go 런타임이 이 선 근처에서 GC를 더 자주 돌려 메모리를 반납한다.
#   kube-reserved(1Gi)와 같은 값. 드롭인이라 k3s 재설치 뒤에도 남는다.
mkdir -p /etc/systemd/system/k3s.service.d
cat > /etc/systemd/system/k3s.service.d/10-gomemlimit.conf <<'EOF'
[Service]
Environment=GOMEMLIMIT=1GiB
EOF
systemctl daemon-reload

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server

# helm: 노드에서 직접 차트를 다룰 때 (배포는 Argo CD). 로컬과 같은 메이저(v4)로 고정
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

#!/bin/bash
# 첫 부팅 때 한 번만 실행된다 (cloud-init). 로그: /var/log/cloud-init-output.log
set -eux
export DEBIAN_FRONTEND=noninteractive

# swap 2GB (메모리 4GB 노드의 완충)
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
sysctl --system

# 기본 도구. 첫 부팅 직후 unattended-upgrades가 apt 잠금을 잡고 있을 수 있어 최대 5분 기다린다
APT="apt-get -o DPkg::Lock::Timeout=300"
$APT update
$APT install -y jq unzip postgresql-client

# AWS CLI v2 (arm64)
curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscli.zip /tmp/aws

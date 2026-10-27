# Argo CD (dev 클러스터) 비밀값. 설치 · 앱 정의는 scripts/install-argocd.sh · argocd/
#
# 팀원은 GitHub 로그인(dino-product 조직원, argocd/values.yaml dex). 로컬 계정은 비상용 admin 하나
# admin 값은 /orbit/shared → 팀원 권한 밖. GitHub OAuth 앱 비밀은 /orbit/shared/ARGOCD_DEV_GITHUB_CLIENT_SECRET (콘솔에서 넣음)
# Argo CD는 bcrypt 해시를 받는다. bcrypt()는 실행마다 값이 달라서 처음 한 번만 넣고 이후 변경은 무시한다
resource "random_password" "argocd_admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "argocd_admin_password" {
  name  = "/orbit/shared/ARGOCD_DEV_ADMIN_PASSWORD"
  type  = "SecureString"
  value = random_password.argocd_admin.result
}

resource "aws_ssm_parameter" "argocd_admin_bcrypt" {
  name  = "/orbit/shared/ARGOCD_DEV_ADMIN_BCRYPT"
  type  = "SecureString"
  value = bcrypt(random_password.argocd_admin.result)
  lifecycle {
    ignore_changes       = [value]
    replace_triggered_by = [random_password.argocd_admin]
  }
}

# GitHub 웹훅 비밀: infra 레포 push → Argo CD가 바로 새로 고침 (없으면 3분마다 확인)
# 웹훅은 레포 설정에 한 번 등록한다 (주소 https://argocd.dev.orbi-t.com/api/webhook, 이 값을 Secret으로)
resource "random_password" "argocd_webhook" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "argocd_webhook_secret" {
  name  = "/orbit/shared/ARGOCD_DEV_WEBHOOK_SECRET"
  type  = "SecureString"
  value = random_password.argocd_webhook.result
}

# infra 레포 배포 키 2개 (공개 키는 output → gh repo deploy-key add로 등록)
# argocd_repo: Argo CD가 레포를 읽는다 (읽기 전용). ESO → Argo CD 레포 Secret (platform/argocd-repo-secret.yaml)
resource "tls_private_key" "argocd_repo" {
  algorithm = "ED25519"
}

resource "aws_ssm_parameter" "argocd_repo_key" {
  name  = "/orbit/dev/ARGOCD_REPO_SSH_KEY"
  type  = "SecureString"
  value = tls_private_key.argocd_repo.private_key_openssh
}

# infra_ci: server 레포 deploy-dev가 values-dev.yaml의 이미지 태그를 커밋한다 (쓰기). 개인 키는 server 레포 시크릿 INFRA_DEPLOY_KEY
resource "tls_private_key" "infra_ci" {
  algorithm = "ED25519"
}

output "argocd_repo_public_key" { value = tls_private_key.argocd_repo.public_key_openssh }
output "infra_ci_public_key" { value = tls_private_key.infra_ci.public_key_openssh }
output "infra_ci_private_key" {
  value     = tls_private_key.infra_ci.private_key_openssh
  sensitive = true
}

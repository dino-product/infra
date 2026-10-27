# 팀원(개발자)용 IAM Identity Center 그룹 · 권한 세트
# 콘솔에서 이미 만든 인스턴스 · AdministratorAccess · Admins · Junyong은 읽기만 하고 건드리지 않는다
# 사용자 생성 · 그룹 추가는 콘솔에서 이메일로 한다 (여기서는 그룹과 권한만)
data "aws_ssoadmin_instances" "main" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.main.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.main.identity_store_ids)[0]
  account_id        = "714047901967"
  region            = "ap-northeast-2"

  # 팀원이 값을 못 읽는 dev 파라미터: 앱 · 인프라 구성 요소만 쓴다
  # DATABASE_PASSWORD는 스키마 소유자라 막아야 사람용 orbit_dev_ro · rw 분리가 의미 있다
  dev_params_no_read = [
    "DATABASE_PASSWORD", "ORIGIN_VERIFY", "ARGOCD_REPO_SSH_KEY",
    "GRAFANA_CLOUD_TOKEN", "SLACK_WEBHOOK_URL", "SWAGGER_HTPASSWD",
  ]
  # 팀원은 읽기만: Terraform · put-params.sh가 넣는 값 (바꾸면 dev가 깨지거나 다음 apply에 되돌아간다)
  dev_params_no_write = [
    "DATABASE_URL", "DATABASE_USERNAME", "DATABASE_RO_PASSWORD", "DATABASE_RW_PASSWORD",
    "SWAGGER_PASSWORD", "MEDIA_*", "GRAFANA_CLOUD_*",
  ]
  dev_param_arn = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/orbit/dev"
}

resource "aws_identitystore_group" "developers" {
  identity_store_id = local.identity_store_id
  display_name      = "Developers"
  description       = "Orbit 팀원(개발자): 콘솔 조회 + dev 파라미터 읽기/쓰기 + dev RDS 포트 포워딩"
}

resource "aws_ssoadmin_permission_set" "dev_developer" {
  instance_arn = local.sso_instance_arn
  name         = "OrbitDevDeveloper"
  # 권한 세트 설명은 Latin-1 문자만 받는다 (한글 X)
  description      = "Orbit dev developer: view-only console, /orbit/dev params rw, dev RDS port forwarding only"
  session_duration = "PT8H"
}

# 콘솔은 둘러보기만 (ViewOnly는 파라미터 값 · S3 객체 내용을 읽지 못한다)
resource "aws_ssoadmin_managed_policy_attachment" "dev_developer_view_only" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.dev_developer.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

resource "aws_ssoadmin_permission_set_inline_policy" "dev_developer" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.dev_developer.arn
  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # dev 파라미터를 이름으로 읽고 쓴다 (경로 조회는 아래에서 막는다)
        # SecureString은 AWS 관리 키 aws/ssm이라 KMS 권한 없이 SSM을 거쳐 복호화된다
        Sid    = "DevParamsReadWrite"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:PutParameter",
        ]
        Resource = ["${local.dev_param_arn}/*"]
      },
      {
        Sid      = "DenyInfraDevParams"
        Effect   = "Deny"
        Action   = ["ssm:GetParameter*", "ssm:PutParameter", "ssm:DeleteParameter*"]
        Resource = [for n in local.dev_params_no_read : "${local.dev_param_arn}/${n}"]
      },
      {
        Sid      = "DenyWriteManagedDevParams"
        Effect   = "Deny"
        Action   = ["ssm:PutParameter", "ssm:DeleteParameter*"]
        Resource = [for n in local.dev_params_no_write : "${local.dev_param_arn}/${n}"]
      },
      {
        # 이름 · 메타데이터 목록만 보여 주고 값은 보여 주지 않는다 (리소스 지정 불가 → *)
        Sid      = "ListParams"
        Effect   = "Allow"
        Action   = "ssm:DescribeParameters"
        Resource = "*"
      },
      {
        # Env=dev 태그가 붙은 노드에만 세션을 연다
        # SessionDocumentAccessCheck: 문서를 명시 허용해야 세션이 열린다 → 기본 셸 문서(SSM-SessionManagerRunShell)는 막힌다
        Sid      = "StartSessionDevNode"
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = "arn:aws:ec2:${local.region}:${local.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Env" = "dev" }
          BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" }
        }
      },
      {
        # 허용 문서는 dev RDS 고정 포트 포워딩 하나뿐 (셸 X, 범용 포워딩 X). 문서엔 태그가 없어 노드 태그 조건과 문을 나눈다
        # 범용 문서(AWS-StartPortForwardingSession*)는 목적지를 마음대로 정할 수 있어 노드 localhost · IMDS까지 닿을 수 있다
        Sid      = "StartSessionDevRdsOnly"
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = aws_ssm_document.dev_rds_port_forward.arn
        Condition = {
          BoolIfExists = { "ssm:SessionDocumentAccessCheck" = "true" }
        }
      },
      {
        # 세션 데이터 채널. StartSession이 돌려준 토큰이 있어야 열리므로 남의 세션엔 못 붙는다
        # 세션 ID는 "<역할 세션 이름>-..."(예: Junyong-xxxx)라 문서 예시의 ${aws:userid}-* 와 맞지 않는다 → 계정 · 리전으로만 좁힌다
        Sid      = "SessionDataChannel"
        Effect   = "Allow"
        Action   = "ssmmessages:OpenDataChannel"
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:session/*"
      },
      {
        # 자기 세션만 끝내고 재개한다. Session Manager가 세션에 붙이는 aws:ssmmessages:session-id 태그 = "<역할 ID>:<세션 이름>" = aws:userid
        Sid      = "OwnSessionsOnly"
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:session/*"
        Condition = {
          StringLike = { "ssm:resourceTag/aws:ssmmessages:session-id" = "$${aws:userid}*" }
        }
      },
      {
        Sid    = "SessionDescribe"
        Effect = "Allow"
        Action = [
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ssm:DescribeInstanceInformation",
        ]
        Resource = "*"
      },
      {
        # 이중 잠금: prod 파라미터는 어떤 경로로도 읽기 · 쓰기 · 삭제 불가
        Sid    = "DenyProdParams"
        Effect = "Deny"
        Action = [
          "ssm:GetParameter*",
          "ssm:PutParameter",
          "ssm:DeleteParameter*",
        ]
        Resource = [
          "arn:aws:ssm:*:${local.account_id}:parameter/orbit/prod",
          "arn:aws:ssm:*:${local.account_id}:parameter/orbit/prod/*",
        ]
      },
      {
        # 경로 조회는 하위 파라미터의 개별 Deny를 무시하고 재귀로 값을 돌려준다 → 경로 조회 자체를 막는다
        # 이름 목록은 DescribeParameters로 본다
        Sid      = "DenyByPath"
        Effect   = "Deny"
        Action   = "ssm:GetParametersByPath"
        Resource = "*"
      },
      {
        # 이중 잠금: tfstate · etcd 스냅샷에는 비밀값이 들어 있다 (ViewOnly도 원래 못 읽는다)
        Sid    = "DenySecretBuckets"
        Effect = "Deny"
        Action = "s3:GetObject*"
        Resource = [
          "arn:aws:s3:::orbit-tfstate-${local.account_id}/*",
          "arn:aws:s3:::orbit-etcd-${local.account_id}/*",
        ]
      },
    ]
  })
}

# 팀원용 포트 포워딩 문서: 목적지를 dev RDS:5432로 고정한다 (로컬 포트만 바꿀 수 있음)
# 사용: aws ssm start-session --target <dev 노드 ID> --document-name Orbit-DevRdsPortForward
resource "aws_ssm_document" "dev_rds_port_forward" {
  name            = "Orbit-DevRdsPortForward"
  document_type   = "Session"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Port forward to the Orbit dev RDS (PostgreSQL 5432) through the dev node"
    sessionType   = "Port"
    parameters = {
      localPortNumber = {
        type           = "String"
        description    = "Local port on your machine"
        allowedPattern = "^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
        default        = "15432"
      }
    }
    properties = {
      type            = "LocalPortForwarding"
      host            = aws_db_instance.main.address
      portNumber      = "5432"
      localPortNumber = "{{ localPortNumber }}"
    }
  })
}

# Developers 그룹 → 이 계정 → OrbitDevDeveloper
resource "aws_ssoadmin_account_assignment" "developers" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.dev_developer.arn
  principal_id       = aws_identitystore_group.developers.group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

output "dev_developer_permission_set_arn" { value = aws_ssoadmin_permission_set.dev_developer.arn }
output "developers_group_id" { value = aws_identitystore_group.developers.group_id }

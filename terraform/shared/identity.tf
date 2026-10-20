# 팀원(개발자)용 IAM Identity Center 그룹 · 권한 세트
# 콘솔에서 이미 만든 인스턴스 · AdministratorAccess · Admins · Junyong은 읽기만 하고 건드리지 않는다
# 사용자 생성 · 그룹 추가는 콘솔에서 이메일로 한다 (여기서는 그룹과 권한만)
data "aws_ssoadmin_instances" "main" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.main.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.main.identity_store_ids)[0]
  account_id        = "714047901967"
  region            = "ap-northeast-2"
}

resource "aws_identitystore_group" "developers" {
  identity_store_id = local.identity_store_id
  display_name      = "Developers"
  description       = "Orbit 팀원(개발자): 콘솔 조회 + dev 파라미터 읽기/쓰기 + dev 노드 포트 포워딩"
}

resource "aws_ssoadmin_permission_set" "dev_developer" {
  instance_arn = local.sso_instance_arn
  name         = "OrbitDevDeveloper"
  # 권한 세트 설명은 Latin-1 문자만 받는다 (한글 X)
  description      = "Orbit dev developer: view-only console, /orbit/dev params rw, SSM port forwarding to dev node only"
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
        # dev 파라미터만 읽고 쓴다. GetParametersByPath는 경로 자체(/orbit/dev)로 권한을 본다 → 둘 다 적는다
        # SecureString은 AWS 관리 키 aws/ssm이라 KMS 권한 없이 SSM을 거쳐 복호화된다
        Sid    = "DevParamsReadWrite"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:PutParameter",
        ]
        Resource = [
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/orbit/dev",
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/orbit/dev/*",
        ]
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
        # 허용 문서는 포트 포워딩 두 개뿐 (셸 X). 문서엔 태그가 없어 노드 태그 조건과 문을 나눈다
        Sid    = "StartSessionPortForwardOnly"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          "arn:aws:ssm:${local.region}::document/AWS-StartPortForwardingSession",
          "arn:aws:ssm:${local.region}::document/AWS-StartPortForwardingSessionToRemoteHost",
        ]
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
        # 경로 권한이 있으면 하위 파라미터의 개별 Deny를 무시하고 재귀 조회된다 → /orbit/dev 밖 경로 조회 자체를 막는다
        Sid    = "DenyByPathOutsideDev"
        Effect = "Deny"
        Action = "ssm:GetParametersByPath"
        NotResource = [
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/orbit/dev",
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/orbit/dev/*",
        ]
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

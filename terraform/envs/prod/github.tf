# server 레포 main 브랜치의 GitHub Actions만 이 역할을 쓸 수 있다 (workflow_dispatch로 사람이 실행)
data "aws_iam_policy_document" "gh_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.shared.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # server 레포는 불변 subject(조직·레포 ID 포함)를 쓴다: gh api repos/dino-product/server/actions/oidc/customization/sub
      values = ["repo:dino-product@324172954/server@1369345285:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gh_server_prod" {
  name                 = "gh-server-prod"
  assume_role_policy   = data.aws_iam_policy_document.gh_trust.json
  max_session_duration = 3600
}

# prod는 빌드하지 않는다: dev에서 검증한 이미지에 prod- 태그만 덧붙인다 (재태그)
resource "aws_iam_role_policy" "gh_ecr_promote" {
  name = "ecr-promote"
  role = aws_iam_role.gh_server_prod.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Resource = local.shared.ecr_repo_arn
        Action   = ["ecr:BatchGetImage", "ecr:PutImage", "ecr:DescribeImages"]
      },
    ]
  })
}

# 14단계에서 envs/prod/main.tf(module "node")를 만든 뒤 추가:
# resource "aws_iam_role_policy_attachment" "node_ecr_pull" {
#   role       = module.node.role_name
#   policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
# }

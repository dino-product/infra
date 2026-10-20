# server 레포 develop 브랜치의 GitHub Actions만 이 역할을 쓸 수 있다 (OIDC, 액세스 키 없음)
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
      values = ["repo:dino-product@324172954/server@1369345285:ref:refs/heads/develop"]
    }
  }
}

resource "aws_iam_role" "gh_server_dev" {
  name                 = "gh-server-dev"
  assume_role_policy   = data.aws_iam_policy_document.gh_trust.json
  max_session_duration = 3600
}

# 이미지 빌드 → ECR push
resource "aws_iam_role_policy" "gh_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.gh_server_dev.id
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
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
        ]
      },
    ]
  })
}

# 노드는 ECR에서 받기만
resource "aws_iam_role_policy_attachment" "node_ecr_pull" {
  role       = module.node.role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

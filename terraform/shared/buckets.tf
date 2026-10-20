resource "aws_s3_bucket" "etcd" {
  bucket = "orbit-etcd-714047901967"
}

resource "aws_s3_bucket_versioning" "etcd" {
  bucket = aws_s3_bucket.etcd.id
  versioning_configuration {
    status = "Enabled"
  }
}

output "etcd_bucket" { value = aws_s3_bucket.etcd.bucket }

# 배포 번들(차트 + deploy.sh) 버킷: infra 레포가 올리고 노드가 받아 간다 (11단계)
resource "aws_s3_bucket" "deploy" {
  bucket = "orbit-deploy-714047901967"
}

resource "aws_s3_bucket_versioning" "deploy" {
  bucket = aws_s3_bucket.deploy.id
  versioning_configuration {
    status = "Enabled"
  }
}

output "deploy_bucket" { value = aws_s3_bucket.deploy.bucket }

# infra 레포 main 브랜치의 Actions만 이 역할을 쓸 수 있다 → 번들 업로드만
data "aws_iam_policy_document" "gh_infra_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # infra 레포도 불변 subject(조직·레포 ID 포함)를 쓴다: gh api repos/dino-product/infra/actions/oidc/customization/sub
      values = ["repo:dino-product@324172954/infra@1424591124:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gh_infra_publish" {
  name                 = "gh-infra-publish"
  assume_role_policy   = data.aws_iam_policy_document.gh_infra_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "gh_infra_publish" {
  name = "bundle-publish"
  role = aws_iam_role.gh_infra_publish.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.deploy.arn}/bundle/*"
      },
    ]
  })
}

output "gh_infra_publish_role_arn" { value = aws_iam_role.gh_infra_publish.arn }

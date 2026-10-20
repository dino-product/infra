resource "aws_ecr_repository" "server" {
  name                 = "orbit/server"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "server" {
  repository = aws_ecr_repository.server.name
  policy = jsonencode({ rules = [
    { rulePriority = 1, description = "prod 이미지 10개 보존",
      selection    = { tagStatus = "tagged", tagPrefixList = ["prod-"], countType = "imageCountMoreThan", countNumber = 10 },
    action = { type = "expire" } },
    { rulePriority = 2, description = "나머지는 최근 30개",
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 },
    action = { type = "expire" } },
  ] })
}

output "ecr_repo_arn" {
  value = aws_ecr_repository.server.arn
}

output "ecr_repo_url" {
  value = aws_ecr_repository.server.repository_url
}
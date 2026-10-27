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

# 계정의 모든 버킷(앞으로 만들 버킷 포함)에 퍼블릭 접근 차단. 버킷별 설정이 빠져도 막힌다
resource "aws_s3_account_public_access_block" "main" {
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

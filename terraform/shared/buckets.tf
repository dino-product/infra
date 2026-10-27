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

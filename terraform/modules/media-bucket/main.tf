# 사진 저장 버킷 (HM-353). 환경마다 하나: orbit-media-<env>-<ACCOUNT_ID>
# server와의 계약:
#   - 업로드 대기 incoming/{fileId} → 검증 후 media/{orgId}/{fileId} 로 복사 (fileId는 UUID)
#   - 클라이언트는 서버가 서명한 PUT URL로 올린다 (서명된 Content-Type 헤더만, 태그 헤더 없음)
#   - 서버는 객체를 지우지 않는다. 태그 status=expired만 붙이면 아래 수명 주기 규칙이 1일 뒤 지운다
#     → 노드 역할(Pod가 IMDSv2로 함께 씀)에 DeleteObject 권한을 주지 않는다
#   - Pod 환경 변수 MEDIA_BUCKET · MEDIA_REGION · MEDIA_RETENTION_MAX_DAYS 는 아래 SSM 파라미터에서 온다
#     → charts/orbit-server ExternalSecret(tfParamKeys, Argo CD가 main을 동기화) → ESO가 Secret orbit-server-env로 → Pod envFrom

variable "env" { type = string }

variable "node_role_name" {
  type        = string
  description = "버킷 권한을 붙일 노드 IAM 역할 이름 (module.node.role_name)"
}

variable "web_origins" {
  type        = list(string)
  default     = []
  description = "브라우저에서 서명 URL로 직접 PUT/GET 하는 사무실 웹 주소. 비면 CORS 설정을 만들지 않는다 (앱은 CORS 불필요)"
}

variable "retention_max_days" {
  type        = number
  default     = 1095
  description = "앱이 허용하는 최대 보관 기간(일). 서버에 MEDIA_RETENTION_MAX_DAYS로 전달"
}

variable "retention_margin_days" {
  type        = number
  default     = 90
  description = "media/ 시스템 보관 상한 = retention_max_days + 이 값. 서버가 태그를 못 붙여도 결국 지워지게 하는 안전망"
}

variable "versioning" {
  type        = bool
  default     = false
  description = "버전 관리 (prod에서 true). 켜면 이전 버전은 7일 뒤 만료"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name = "orbit-media-${var.env}-${data.aws_caller_identity.current.account_id}"
}

# 버킷은 env에 따라 두 리소스 중 하나로만 만든다 (lifecycle은 변수로 바꿀 수 없어 prod만 따로 둔다)
# 다른 리소스는 local.bucket_id · bucket_arn만 참조한다
resource "aws_s3_bucket" "media" {
  count         = var.env == "prod" ? 0 : 1
  bucket        = local.bucket_name
  force_destroy = true # dev: 객체가 남아 있어도 destroy 가능
}

# prod: 버킷을 지우거나 교체하는 plan은 plan 단계에서 실패한다 → 퍼블릭 차단 · 수명 주기 · 정책만 먼저 지워지는 일이 없다
# 단, module 블록을 통째로 지우면 이 설정도 함께 사라져 막지 못한다 (그땐 force_destroy = false가 비지 않은 버킷 삭제만 막는다)
resource "aws_s3_bucket" "media_prod" {
  count         = var.env == "prod" ? 1 : 0
  bucket        = local.bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  bucket_id  = one(concat(aws_s3_bucket.media[*].id, aws_s3_bucket.media_prod[*].id)) # = 버킷 이름
  bucket_arn = one(concat(aws_s3_bucket.media[*].arn, aws_s3_bucket.media_prod[*].arn))
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = local.bucket_id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# HTTP(평문) 요청은 모든 동작 거부. 서명 URL(https) · SDK(기본 https)는 영향 없다
# 허용은 넣지 않는다: 노드 역할 권한은 아래 IAM 정책으로 충분하다 (Deny만 있으니 퍼블릭 정책 차단에도 걸리지 않는다)
resource "aws_s3_bucket_policy" "media" {
  bucket = local.bucket_id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.media] # 퍼블릭 차단과 동시에 설정하면 S3가 충돌 오류를 낼 수 있다
}

resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = local.bucket_id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACL 비활성화
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = local.bucket_id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 (KMS 권한 불필요)
    }
  }
}

resource "aws_s3_bucket_versioning" "media" {
  count  = var.versioning ? 1 : 0
  bucket = local.bucket_id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_cors_configuration" "media" {
  count  = length(var.web_origins) > 0 ? 1 : 0
  bucket = local.bucket_id
  cors_rule {
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = var.web_origins
    allowed_headers = ["Content-Type"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# 한 객체에 규칙이 여러 개 걸리면 S3는 가장 이른 만료를 쓴다 (media/ + status=expired → 1일)
resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = local.bucket_id

  # 검증되지 않고 남은 업로드
  rule {
    id     = "incoming-expire"
    status = "Enabled"
    filter {
      prefix = "incoming/"
    }
    expiration {
      days = 1
    }
  }

  # 서버가 지우기로 표시한 객체 (서버는 DeleteObject 권한이 없다)
  rule {
    id     = "tagged-expired"
    status = "Enabled"
    filter {
      tag {
        key   = "status"
        value = "expired"
      }
    }
    expiration {
      days = 1
    }
  }

  # 시스템 보관 상한: 앱 최대 보관 기간 + 여유
  rule {
    id     = "media-max-retention"
    status = "Enabled"
    filter {
      prefix = "media/"
    }
    expiration {
      days = var.retention_max_days + var.retention_margin_days
    }
  }

  rule {
    id     = "abort-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # 버전 관리를 켠 버킷만: 만료로 생긴 이전 버전 · 남은 삭제 마커 정리
  dynamic "rule" {
    for_each = var.versioning ? [1] : []
    content {
      id     = "noncurrent-cleanup"
      status = "Enabled"
      filter {}
      noncurrent_version_expiration {
        noncurrent_days = 7
      }
      expiration {
        expired_object_delete_marker = true
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.media]
}

# 노드 역할(= Pod)이 쓰는 권한. Delete* 는 일부러 없다 → 삭제는 태그 + 수명 주기로만
resource "aws_iam_role_policy" "media" {
  name = "media-bucket"
  role = var.node_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 서명 URL PUT/GET · incoming → media 복사(CopyObject)
        Sid    = "ObjectReadWrite"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = [
          "${local.bucket_arn}/incoming/*",
          "${local.bucket_arn}/media/*",
        ]
      },
      {
        # CopyObject가 원본 태그를 복사할 때 읽는다
        Sid      = "IncomingTagRead"
        Effect   = "Allow"
        Action   = ["s3:GetObjectTagging"]
        Resource = "${local.bucket_arn}/incoming/*"
      },
      {
        # 삭제 표시(status=expired)
        Sid      = "MediaTagWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObjectTagging"]
        Resource = "${local.bucket_arn}/media/*"
      },
      {
        # 없는 키의 HeadObject/GetObject가 403 대신 404로 오게 하려는 것 (ListBucket이 있어야 404)
        # 접두사로 범위를 제한하지 않는다: 그 확인 요청과 prefix 없는 목록 조회엔 s3:prefix가 없어 IfExists로 통과한다
        Sid       = "ListForNotFound"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = local.bucket_arn
        Condition = { StringLikeIfExists = { "s3:prefix" = ["incoming/*", "media/*"] } }
      },
    ]
  })
}

# Pod 환경 변수 (ESO → orbit-server-env). 이 3개는 terraform 소유: scripts/put-params.sh로 넣거나 콘솔에서 고치지 말 것
# 비밀이 아니므로 String. 노드 역할의 params-read(/orbit/<env>/*)로 읽힌다
resource "aws_ssm_parameter" "bucket" {
  name  = "/orbit/${var.env}/MEDIA_BUCKET"
  type  = "String"
  value = local.bucket_id
}

resource "aws_ssm_parameter" "region" {
  name  = "/orbit/${var.env}/MEDIA_REGION"
  type  = "String"
  value = data.aws_region.current.region
}

resource "aws_ssm_parameter" "retention_max_days" {
  name  = "/orbit/${var.env}/MEDIA_RETENTION_MAX_DAYS"
  type  = "String"
  value = tostring(var.retention_max_days)
}

output "bucket" { value = local.bucket_id }
output "bucket_arn" { value = local.bucket_arn }

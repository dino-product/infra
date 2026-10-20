module "node" {
  source     = "../../modules/node"
  env        = "dev"
  private_ip = "10.10.0.10"
  subnet_id  = local.shared.public_subnet_id
  vpc_id     = local.shared.vpc_id
}

output "instance_id" {
  value = module.node.instance_id
}

output "public_ip" {
  value = module.node.public_ip
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_dev" {
  security_group_id            = local.shared.rds_sg_id
  referenced_security_group_id = module.node.sg_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "dev node"
}

# k3s etcd 스냅샷 → s3://orbit-etcd-<ACCOUNT_ID>/dev/ 만 읽고 쓰기
resource "aws_iam_role_policy" "etcd_snapshot" {
  name = "etcd-snapshot"
  role = module.node.role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # k3s는 시작할 때 버킷이 있는지 HEAD로 확인한다(prefix 없음) → IfExists로 그 요청도 허용
        Effect    = "Allow"
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = "arn:aws:s3:::${local.shared.etcd_bucket}"
        Condition = { StringLikeIfExists = { "s3:prefix" = ["dev/*", "dev"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${local.shared.etcd_bucket}/dev/*"
      },
    ]
  })
}

# ESO가 노드 역할로 Parameter Store /orbit/dev/* 만 읽는다 (SecureString은 기본 키 aws/ssm이라 KMS 권한 불필요)
resource "aws_iam_role_policy" "params_read" {
  name = "params-read"
  role = module.node.role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:ap-northeast-2:714047901967:parameter/orbit/dev/*"
      },
    ]
  })
}

# Grafana CloudWatch 데이터 소스가 노드 역할로 지표를 읽는다 (EC2 상태 검사 · CPU 크레딧, 12-2)
resource "aws_iam_role_policy" "cw_read" {
  name = "cloudwatch-read"
  role = module.node.role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Resource = "*"
        Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
      },
    ]
  })
}

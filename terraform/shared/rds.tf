resource "aws_db_subnet_group" "main" {
  name       = "orbit-db"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_c.id]
}

resource "aws_security_group" "rds" {
  name   = "orbit-rds"
  vpc_id = aws_vpc.main.id
  tags   = { Name = "orbit-rds" }
}

# 인바운드 규칙은 dev prod SG 하나씩 추가

resource "aws_db_instance" "main" {
  identifier                  = "orbit"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  availability_zone           = "ap-northeast-2a"
  publicly_accessible         = false
  multi_az                    = false
  username                    = "orbit_admin"
  manage_master_user_password = true
  backup_retention_period     = 7
  backup_window               = "17:00-17:30"
  maintenance_window          = "sun:18:00-sun:19:00"
  auto_minor_version_upgrade  = true
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "orbit-final"
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "rds_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}
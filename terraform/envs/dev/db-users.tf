# 사람용 DB 계정 비밀번호 (앱 계정 orbit_dev와 분리). 역할 · 권한은 scripts/db-users.sh가 만든다
#   orbit_dev_ro: 조회만 (기본 읽기 전용 트랜잭션)
#   orbit_dev_rw: 데이터 수정까지 (스키마 변경 · flyway 기록은 못 건드림)
# 값을 바꾸면 scripts/db-users.sh dev를 다시 실행해야 DB에 반영된다
resource "random_password" "db_human" {
  for_each = toset(["ro", "rw"])
  length   = 32
  special  = false
}

resource "aws_ssm_parameter" "db_human_password" {
  for_each = random_password.db_human
  name     = "/orbit/dev/DATABASE_${upper(each.key)}_PASSWORD"
  type     = "SecureString"
  value    = each.value.result
}

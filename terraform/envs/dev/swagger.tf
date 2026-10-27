# dev Swagger(/docs · /swagger-ui · /docs-json)에만 거는 기본 인증. 앱 API는 그대로
# 사용자 orbit, 비밀번호는 /orbit/dev/SWAGGER_PASSWORD (팀원이 읽을 수 있다)
# Traefik basicAuth는 htpasswd 줄을 받는다 → ESO가 /orbit/dev/SWAGGER_HTPASSWD를 Secret swagger-auth로 (차트 swagger-auth.yaml)
resource "random_password" "swagger" {
  length  = 20
  special = false
}

resource "aws_ssm_parameter" "swagger_password" {
  name  = "/orbit/dev/SWAGGER_PASSWORD"
  type  = "SecureString"
  value = random_password.swagger.result
}

# bcrypt()는 실행마다 값이 달라서 처음 한 번만 넣고 이후 변경은 무시한다
resource "aws_ssm_parameter" "swagger_htpasswd" {
  name  = "/orbit/dev/SWAGGER_HTPASSWD"
  type  = "SecureString"
  value = "orbit:${bcrypt(random_password.swagger.result)}"
  lifecycle {
    ignore_changes       = [value]
    replace_triggered_by = [random_password.swagger]
  }
}

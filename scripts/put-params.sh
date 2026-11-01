#!/bin/bash
# Parameter Store에 앱 비밀 값 20개를 한 번에 넣는다 (8-1)
# 사용법: AWS_PROFILE=orbit-admin bash scripts/put-params.sh dev   (DB 암호는 실행 중에 묻는다)
#   - 이미 있는 이름은 건너뛴다 → 다시 실행해도 기존 값(특히 암호화 키)을 덮어쓰지 않는다
#   - 값을 바꿀 때: aws ssm put-parameter --name /orbit/dev/<이름> --type SecureString --value '…' --overwrite
#   - 카카오 · Apple · 도메인 값은 임시 값으로 넣는다. 앱이 시작할 때 형식만 검사하므로 뜨는 데는 문제없고, 10단계에서 고친다
#   - terraform 소유 값(ORIGIN_VERIFY · MEDIA_* · GRAFANA_CLOUD_* · ARGOCD_* · SWAGGER_* · DATABASE_RO/RW_PASSWORD)은 여기서 넣지 않는다 (envs/<env> · modules/media-bucket · shared)
set -euo pipefail

ENV=${1:?"dev 또는 prod를 인자로 주세요"}
[[ $ENV == dev || $ENV == prod ]] || { echo "ENV는 dev 또는 prod" >&2; exit 1; }
REGION=ap-northeast-2

RDS_ENDPOINT=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier orbit \
  --query 'DBInstances[0].Endpoint.Address' --output text)
# DB_PASSWORD 환경 변수로 넘기면 묻지 않는다 (예: DB_PASSWORD=$DBPW bash scripts/put-params.sh dev)
DB_PASSWORD=${DB_PASSWORD:-}
[[ -n $DB_PASSWORD ]] || { read -rsp "orbit_${ENV} DB 사용자 암호 (5-3에서 만든 것): " DB_PASSWORD; echo; }
[[ -n $DB_PASSWORD ]] || { echo "암호가 비었습니다" >&2; exit 1; }

put() {
  local name="/orbit/${ENV}/$1"
  if aws ssm get-parameter --region "$REGION" --name "$name" >/dev/null 2>&1; then
    echo "skip $1 (이미 있음)"
    return
  fi
  aws ssm put-parameter --region "$REGION" --name "$name" --type SecureString --value "$2" >/dev/null
  echo "ok   $1"
}

put DATABASE_URL "jdbc:postgresql://${RDS_ENDPOINT}:5432/orbit_${ENV}?sslmode=require"
put DATABASE_USERNAME "orbit_${ENV}"
put DATABASE_PASSWORD "$DB_PASSWORD"
put AUTH_JWT_SECRET "$(openssl rand -base64 48)"                      # 32바이트 이상
put APPLE_REFRESH_TOKEN_ENCRYPTION_KEY "$(openssl rand -base64 32)"   # base64 32바이트. 바꾸면 저장된 토큰을 못 읽는다

# 임시 값 (도메인 값 외에는 10단계 이후 실제 값으로 --overwrite)
put KAKAO_ALLOWED_AUDIENCES "change-me"
put KAKAO_REST_API_KEY "change-me"                                  # KAKAO_ALLOWED_AUDIENCES에 들어 있어야 앱이 뜬다
put KAKAO_ADMIN_KEY "change-me"
put KAKAO_CLIENT_SECRET "change-me"
put APPLE_ALLOWED_AUDIENCES "change-me"
put APPLE_TEAM_ID "change-me"
put APPLE_KEY_ID "change-me"
put APPLE_SERVICES_ID "change-me"
put APPLE_PRIVATE_KEY "change-me"                                     # 실제 Apple 로그인 때 처음 읽는다 → .p8은 file://로 넣는다
API_HOST=$([[ $ENV == prod ]] && echo api.orbi-t.com || echo dev-api.orbi-t.com)
WEB_HOST=$([[ $ENV == prod ]] && echo orbi-t.com || echo dev.orbi-t.com)
put KAKAO_WEB_REDIRECT_URI "https://${API_HOST}/api/v1/auth/kakao/callback"
put KAKAO_WEB_RETURN_URI "https://${WEB_HOST}/"
put APPLE_WEB_REDIRECT_URI "https://${API_HOST}/api/v1/auth/apple/callback"
put APPLE_WEB_RETURN_URI "http://localhost:3000/auth/apple"           # 절대 URI여야 앱이 뜬다
put APPLE_ANDROID_RETURN_URI "orbit://auth/apple"
put CORS_ALLOWED_ORIGIN_PATTERNS "http://localhost:3000,http://localhost:5173"

echo
aws ssm get-parameters-by-path --region "$REGION" --path "/orbit/${ENV}" \
  --query 'Parameters[].Name' --output text | wc -w \
  | xargs echo "/orbit/${ENV} 파라미터 수 (이 스크립트 15개 + terraform 소유 값 · SLACK_WEBHOOK_URL까지 함께 센다):"

#!/bin/bash
# 사람용 DB 계정 orbit_<env>_ro · orbit_<env>_rw를 만들고 권한을 맞춘다. 다시 실행해도 된다 (비밀번호 · 권한을 덮어쓴다)
# 관리자가 로컬에서: AWS_PROFILE=orbit-admin, RDS 터널(localhost:15432)을 연 상태로 실행
#   aws ssm start-session --target <dev 노드 ID> --document-name Orbit-DevRdsPortForward
#   bash scripts/db-users.sh dev
# 비밀번호는 Parameter Store(terraform/envs/<env>/db-users.tf), 마스터 암호는 Secrets Manager(RDS 관리)에서 읽는다
set -euo pipefail

ENV=${1:?"dev 또는 prod를 인자로 주세요"}
DB="orbit_${ENV}"
REGION=ap-northeast-2
PORT=${PGPORT:-15432}
get() { aws ssm get-parameter --region "$REGION" --with-decryption \
  --name "/orbit/${ENV}/$1" --query Parameter.Value --output text; }

RO_PW=$(get DATABASE_RO_PASSWORD)
RW_PW=$(get DATABASE_RW_PASSWORD)
APP_PW=$(get DATABASE_PASSWORD)
SECRET_ARN=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier orbit \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
MASTER=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" \
  --query SecretString --output text)
MASTER_USER=$(jq -r .username <<<"$MASTER")
MASTER_PW=$(jq -r .password <<<"$MASTER")

conn() { echo "host=127.0.0.1 port=${PORT} sslmode=require dbname=$1 user=$2"; }

# 1) 역할 만들기 · 비밀번호 (마스터: CREATEROLE)
PGPASSWORD="$MASTER_PW" psql "$(conn postgres "$MASTER_USER")" -v ON_ERROR_STOP=1 -q <<SQL
\set ro_pw '${RO_PW}'
\set rw_pw '${RW_PW}'
SELECT format('CREATE ROLE %I LOGIN CONNECTION LIMIT 5', r)
  FROM unnest(ARRAY['${DB}_ro', '${DB}_rw']) AS r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
ALTER ROLE ${DB}_ro PASSWORD :'ro_pw';
ALTER ROLE ${DB}_rw PASSWORD :'rw_pw';
ALTER ROLE ${DB}_ro SET default_transaction_read_only = on;
SQL

# 2) 권한 (앱 계정: DB · 스키마 · 테이블 소유자). 앞으로 Flyway가 만드는 테이블에도 같은 권한이 붙는다
PGPASSWORD="$APP_PW" psql "$(conn "$DB" "$DB")" -v ON_ERROR_STOP=1 -q <<SQL
GRANT CONNECT ON DATABASE ${DB} TO ${DB}_ro, ${DB}_rw;
GRANT USAGE ON SCHEMA public TO ${DB}_ro, ${DB}_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${DB}_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${DB}_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${DB}_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${DB}_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${DB}_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${DB}_rw;
SELECT 'REVOKE INSERT, UPDATE, DELETE ON flyway_schema_history FROM ${DB}_rw'
 WHERE to_regclass('public.flyway_schema_history') IS NOT NULL \gexec
SQL

echo "완료: ${DB}_ro (조회) · ${DB}_rw (데이터 수정). 비밀번호 /orbit/${ENV}/DATABASE_RO_PASSWORD · DATABASE_RW_PASSWORD"

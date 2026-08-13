#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="$project_root/infra/docker-compose.yml"
test_database_url='postgresql://epistoria_test:epistoria-test-isolated@localhost:55433/epistoria_test?schema=public'

cleanup() {
  docker compose -f "$compose_file" --profile test rm --stop --force test-postgres \
    >/dev/null 2>&1 || true
  if docker compose -f "$compose_file" ps --status running --quiet minio 2>/dev/null | grep -q .; then
    docker compose -f "$compose_file" run --rm --no-deps --entrypoint /bin/sh minio-bootstrap \
      -ec 'mc alias set local http://minio:9000 epistoria epistoria-local-secret >/dev/null; mc rm --recursive --force local/epistoria-test-assets >/dev/null' \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
cleanup

docker compose -f "$compose_file" --profile test up -d --wait minio test-postgres
docker compose -f "$compose_file" run --rm minio-bootstrap
DATABASE_URL="$test_database_url" npm run prisma:deploy --workspace @epistoria/api
EPISTORIA_TEST_DATABASE_URL="$test_database_url" npm run test:e2e
EPISTORIA_CANARY_SCAN_DOCKER_LOGS=1 "$project_root/scripts/plaintext-canary.sh"

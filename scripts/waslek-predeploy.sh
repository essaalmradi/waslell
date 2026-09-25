#!/usr/bin/env bash
set -Eeuo pipefail

cd /var/www/html

log() {
  printf '[waslek-predeploy] %s\n' "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

require_variable() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "required variable is missing: $name"
}

for name in \
  DB_HOST DB_DATABASE DB_USERNAME DB_PASSWORD \
  WASLEK_BACKUP_BUCKET WASLEK_BACKUP_ENDPOINT WASLEK_BACKUP_REGION \
  WASLEK_BACKUP_ACCESS_KEY_ID WASLEK_BACKUP_SECRET_ACCESS_KEY; do
  require_variable "$name"
done

DB_PORT="${DB_PORT:-3306}"
for command in php gzip sha256sum rclone; do
  require_command "$command"
done

DUMP_BIN="$(command -v mysqldump || command -v mariadb-dump || true)"
ADMIN_BIN="$(command -v mysqladmin || command -v mariadb-admin || true)"
[[ -n "$DUMP_BIN" ]] || fail 'mysqldump or mariadb-dump is unavailable'
[[ -n "$ADMIN_BIN" ]] || fail 'mysqladmin or mariadb-admin is unavailable'

php_version="$(php -r 'echo PHP_VERSION;')"
[[ "$php_version" == 8.2.* ]] || fail "expected PHP 8.2, found $php_version"
log "PHP version check passed ($php_version)"

php -r "require 'vendor/autoload.php';" >/dev/null
log 'Composer autoload check passed'

lint_count=0
while IFS= read -r -d '' source; do
  php -l "$source" >/dev/null
  lint_count=$((lint_count + 1))
done < <(find \
  app/Core app/Modules config routes \
  database/migrations/2026_09_25_180000_create_rbac_tables.php \
  -type f -name '*.php' -print0)
[[ "$lint_count" -gt 0 ]] || fail 'no changed PHP files found for syntax validation'
log "PHP syntax checks passed ($lint_count files)"
route_output="$(mktemp)"
php artisan route:list --no-interaction >"$route_output"
route_count="$(wc -l <"$route_output" | tr -d ' ')"
rm -f "$route_output"
[[ "$route_count" -ge 50 ]] || fail "route:list returned only $route_count lines"
log "route:list passed ($route_count lines)"

mysql_ready=0
for _ in $(seq 1 60); do
  if MYSQL_PWD="$DB_PASSWORD" "$ADMIN_BIN" --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" --silent ping >/dev/null 2>&1; then
    mysql_ready=1
    break
  fi
  sleep 2
done
[[ "$mysql_ready" -eq 1 ]] || fail 'MySQL was not reachable within 120 seconds'
log 'MySQL connectivity check passed'

php artisan migrate:status --no-interaction >/dev/null
log 'migrate:status check passed'
workdir="$(mktemp -d -t waslek-predeploy-XXXXXX)"
backup_file="$workdir/waslek.sql.gz"
dump_error="$workdir/mysqldump.err"

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

run_dump() {
  local include_privileged="$1"
  local extra=()
  if [[ "$include_privileged" == 'yes' ]]; then
    extra=(--routines --events)
  fi

  set +e
  MYSQL_PWD="$DB_PASSWORD" "$DUMP_BIN" \
    --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USERNAME" \
    --single-transaction --quick --skip-lock-tables --triggers --hex-blob \
    --default-character-set=utf8mb4 "${extra[@]}" "$DB_DATABASE" \
    2>"$dump_error" | gzip -9 >"$backup_file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  [[ "${pipeline_status[0]}" -eq 0 && "${pipeline_status[1]}" -eq 0 ]]
}
if ! run_dump yes; then
  log 'full dump was not permitted; retrying standard transactional dump'
  rm -f "$backup_file"
  if ! run_dump no; then
    tail -c 2000 "$dump_error" >&2 || true
    fail 'database dump failed'
  fi
fi

[[ -s "$backup_file" ]] || fail 'database dump is empty'
gzip -t "$backup_file"
backup_size="$(stat -c %s "$backup_file")"
[[ "$backup_size" -ge 100 ]] || fail "database dump is unexpectedly small ($backup_size bytes)"
backup_sha="$(sha256sum "$backup_file" | awk '{print $1}')"
log "database dump validated (bytes=$backup_size sha256=$backup_sha)"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
deployment_id="${RAILWAY_DEPLOYMENT_ID:-manual}"
deployment_id="$(printf '%s' "$deployment_id" | tr -cd '[:alnum:]_-')"
object_key="mysql/production/waslek-${timestamp}-${deployment_id:-manual}.sql.gz"
remote_file="waslek:${WASLEK_BACKUP_BUCKET}/${object_key}"

export RCLONE_CONFIG_WASLEK_TYPE=s3
export RCLONE_CONFIG_WASLEK_PROVIDER=Other
export RCLONE_CONFIG_WASLEK_ACCESS_KEY_ID="$WASLEK_BACKUP_ACCESS_KEY_ID"
export RCLONE_CONFIG_WASLEK_SECRET_ACCESS_KEY="$WASLEK_BACKUP_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_WASLEK_REGION="$WASLEK_BACKUP_REGION"
export RCLONE_CONFIG_WASLEK_ENDPOINT="$WASLEK_BACKUP_ENDPOINT"
export RCLONE_CONFIG_WASLEK_FORCE_PATH_STYLE="${WASLEK_BACKUP_FORCE_PATH_STYLE:-false}"
export RCLONE_CONFIG_WASLEK_NO_CHECK_BUCKET=true

rclone copyto "$backup_file" "$remote_file" \
  --s3-no-check-bucket \
  --retries 3 \
  --low-level-retries 10 \
  --contimeout 30s \
  --timeout 10m

remote_size="$(rclone size --json "$remote_file" --s3-no-check-bucket \
  | php -r '$value=json_decode(stream_get_contents(STDIN), true); echo (int)($value["bytes"] ?? -1);')"
[[ "$remote_size" -eq "$backup_size" ]] || fail "backup size verification failed: expected $backup_size, got $remote_size"

remote_sha="$(rclone cat "$remote_file" --s3-no-check-bucket | sha256sum | awk '{print $1}')"
[[ "$remote_sha" == "$backup_sha" ]] || fail 'backup SHA-256 verification failed'
log "backup verified in bucket (key=$object_key bytes=$backup_size sha256=$backup_sha)"

php artisan migrate --force --no-interaction
log 'migrate --force completed successfully'
php artisan migrate:status --no-interaction >/dev/null
log 'post-migration status check passed'
log 'pre-deploy validation, backup, verification, and migration completed successfully'

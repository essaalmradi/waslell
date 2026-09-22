#!/bin/sh
set -eu

cd /var/www/html

mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true

if [ "${IMPORT_DB_ON_BOOT:-false}" = "true" ] && [ -f /opt/waslek/database.sql.gz.enc ]; then
  echo "[waslek] waiting for MySQL..."
  i=0
  until MYSQL_PWD="${DB_PASSWORD}" mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_USERNAME}" --silent; do
    i=$((i+1))
    [ "$i" -ge 60 ] && { echo "[waslek] MySQL unavailable"; exit 1; }
    sleep 2
  done

  tables="$(MYSQL_PWD="${DB_PASSWORD}" mysql -N -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_USERNAME}" "${DB_DATABASE}" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null || echo 0)"
  if [ "${tables:-0}" -lt 60 ]; then
    echo "[waslek] importing production database..."
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:DB_IMPORT_KEY -in /opt/waslek/database.sql.gz.enc \
      | gzip -dc \
      | MYSQL_PWD="${DB_PASSWORD}" mysql --max_allowed_packet=512M -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_USERNAME}" "${DB_DATABASE}"
    echo "[waslek] database import complete"
  else
    echo "[waslek] database already populated; skipping import"
  fi
fi

php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true

exec "$@"

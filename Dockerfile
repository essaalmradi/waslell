FROM alpine:3.20 AS payload
ARG BUNDLE_URL
RUN apk add --no-cache ca-certificates curl tar gzip
WORKDIR /payload
RUN test -n "$BUNDLE_URL" \
    && curl -fL --retry 5 --retry-delay 2 "$BUNDLE_URL" -o bundle.tar \
    && tar -xf bundle.tar \
    && mkdir -p /app \
    && gzip -t source.tar.gz \
    && tar -tzf source.tar.gz >/dev/null \
    && tar -xzf source.tar.gz -C /app

FROM php:8.2-apache
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates default-mysql-client gzip openssl rclone tar \
       libfreetype6-dev libjpeg62-turbo-dev libpng-dev libzip-dev libicu-dev libonig-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql mbstring zip intl gd exif \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
COPY --from=payload /app /var/www/html
COPY overlay.parts/ /tmp/overlay.parts/
RUN cat /tmp/overlay.parts/*.b64 > /tmp/overlay.b64 \
    && base64 -d /tmp/overlay.b64 > /tmp/architecture-overlay.tar.gz \
    && echo "24d07b0362b7f0c7219100da9d386d6f14de0c55d7d4360be13410c89806577e  /tmp/architecture-overlay.tar.gz" | sha256sum -c - \
    && gzip -t /tmp/architecture-overlay.tar.gz \
    && tar -tzf /tmp/architecture-overlay.tar.gz >/dev/null \
    && tar -xzf /tmp/architecture-overlay.tar.gz -C /var/www/html \
    && rm -rf /tmp/overlay.parts /tmp/overlay.b64 /tmp/architecture-overlay.tar.gz

COPY scripts/waslek-predeploy.sh /usr/local/bin/waslek-predeploy
COPY railway-start.sh /usr/local/bin/railway-start
RUN chmod +x /usr/local/bin/waslek-predeploy /usr/local/bin/railway-start \
    && bash -n /usr/local/bin/waslek-predeploy \
    && mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/railway-start"]
CMD ["apache2-foreground"]

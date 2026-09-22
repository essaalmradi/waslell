FROM alpine:3.20 AS payload
ARG BUNDLE_URL
RUN apk add --no-cache ca-certificates curl tar gzip
WORKDIR /payload
RUN test -n "$BUNDLE_URL" \
    && curl -fL --retry 5 --retry-delay 2 "$BUNDLE_URL" -o bundle.tar \
    && tar -xf bundle.tar \
    && mkdir -p /app \
    && tar -xzf source.tar.gz -C /app

FROM php:8.2-apache
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       default-mysql-client openssl gzip \
       libfreetype6-dev libjpeg62-turbo-dev libpng-dev libzip-dev libicu-dev libonig-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql mbstring zip intl gd exif \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public
WORKDIR /var/www/html

COPY --from=payload /app /var/www/html
COPY --from=payload /payload/database.sql.gz.enc /opt/waslek/database.sql.gz.enc
COPY --from=payload /app/docker/000-default.conf /etc/apache2/sites-available/000-default.conf
COPY railway-start.sh /usr/local/bin/railway-start

RUN chmod +x /usr/local/bin/railway-start \
    && mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/railway-start"]
CMD ["apache2-foreground"]

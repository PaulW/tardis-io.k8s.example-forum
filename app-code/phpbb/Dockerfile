# =====================================================================
# phpBB 3.3.x — an example multi-stage image.
#
# This is the SIMPLEST version that works. It is not the production
# image described in the blog post, which adds the OPcache tuning, the
# FPM pool sizing, the club assets, the extensions, and the
# verification suite.
#
# What is here:
#   * the runtime libraries and the PHP extensions phpBB needs
#   * a non-root user at UID 1000
#   * phpBB, downloaded and verified
#   * two build targets: an installer and a production runtime
#   * config.php generated at container start, not baked in
# =====================================================================
FROM php:8.5.12-fpm-alpine AS base

# Pinned phpBB release. Update both values together, and re-verify the
# SHA256 against the release directory before you change it.
ENV PHPBB_VERSION=3.3.19
ENV PHPBB_SHA256=66f35fa3d9bf3b90269205bbb281e1156727a0014eea344fe15f9c7376b78c66

# 1. The runtime libraries, and the PHP extensions compiled from source.
RUN apk add --no-cache \
        nginx \
        curl \
        tar \
        bzip2 \
        libpng \
        libjpeg-turbo \
        freetype \
        libwebp \
        libzip \
        icu-libs \
        oniguruma \
    && apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        libwebp-dev \
        libzip-dev \
        icu-dev \
        oniguruma-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        gd \
        mysqli \
        pdo_mysql \
        zip \
        intl \
        mbstring \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* /tmp/pear

# 2. The runtime user.
#
# Alpine's www-data is UID 82. The container runs as a non-root user,
# and the UID has to be one the platform is happy with. Pick yours and
# use it consistently, including in the compose file and the
# Kubernetes security context.
RUN addgroup -g 1000 -S phpbb \
    && adduser -u 1000 -S -G phpbb -h /var/www -s /sbin/nologin phpbb

# 3. The PHP-FPM pool.
#
# The stock www.conf runs the pool as www-data and sets a user and a
# group. The container already runs as phpbb, and PHP-FPM logs a
# notice when those directives are set while it is not running as
# root, so they are removed.
#
# `pm.max_children` has to stay below the database user's connection
# limit if you turn on persistent connections. See the blog post.
RUN sed -i '/^user =/d; /^group =/d' /usr/local/etc/php-fpm.d/www.conf \
    && { \
        echo '[www]'; \
        echo 'listen = 9000'; \
        echo 'clear_env = no'; \
        echo 'catch_workers_output = yes'; \
        echo 'decorate_workers_output = no'; \
        echo 'pm = dynamic'; \
        echo 'pm.max_children = 30'; \
        echo 'pm.start_servers = 6'; \
        echo 'pm.min_spare_servers = 6'; \
        echo 'pm.max_spare_servers = 12'; \
        echo 'pm.max_requests = 1000'; \
        echo 'pm.process_idle_timeout = 30s'; \
        echo 'request_terminate_timeout = 60s'; \
        echo 'access.log = /dev/null'; \
    } > /usr/local/etc/php-fpm.d/zz-phpbb.conf

# The OPcache settings, which are not board-specific. The stock
# values are not wrong so much as untuned for this workload.
#
# `validate_timestamps=0` removes a stat() from every request,
# because the code is immutable for the life of the pod. A
# deployment replaces the pod rather than changing the files in it.
#
# `max_accelerated_files=6500` sizes the hash table that maps a
# cached file to its slot, and the size is the value rounded up to
# the next prime. The primes PHP uses are 7963, then 16229, then
# 32531, so the stock default of 10000 and a value of 8000 both give
# a hash of 16229 slots and make no difference at all. 6500 rounds
# up to 7963, which halves the hash.
#
# The limit is the number of cache keys the hash can hold, and a key
# is a path rather than a file. A file reached by two different paths
# takes two slots. A phpBB board has around 3,000 PHP files, and
# 7,963 slots is room for it. A full hash schedules a restart of the
# cache rather than failing a request.
#
# `file_update_protection` is 0, not the stock 2. It is the number
# of seconds after a file is written before OPcache will compile it.
# The image is built and then run, and a build that produced a
# half-written file would fail at build time, not at request time.
#
# `save_comments` is off. phpBB does not read the doc comments at
# runtime, and keeping them costs memory for every cached script.
#
# There is no `revalidate_freq` here. It is only consulted when the
# timestamp check runs, and `validate_timestamps=0` is what skips it.
RUN { \
    echo 'opcache.enable=1'; \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.interned_strings_buffer=16'; \
    echo 'opcache.max_accelerated_files=6500'; \
    echo 'opcache.max_wasted_percentage=10'; \
    echo 'opcache.validate_timestamps=0'; \
    echo 'opcache.file_update_protection=0'; \
    echo 'opcache.save_comments=0'; \
    echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

WORKDIR /var/www/html

# 4. phpBB, with the download verified.
RUN curl -fSL "https://download.phpbb.com/pub/release/3.3/${PHPBB_VERSION}/phpBB-${PHPBB_VERSION}.tar.bz2" -o phpbb.tar.bz2 \
    && echo "${PHPBB_SHA256}  phpbb.tar.bz2" | sha256sum -c - \
    && tar -xjf phpbb.tar.bz2 --strip-components=1 \
    && rm phpbb.tar.bz2

# 5. The configuration.
#
# None of these are baked in. config.php is generated at container
# start, and the nginx configuration is a template because the forum
# can be served from the root of a host or from a path prefix.
COPY config.php.template /var/www/html/config.php.template
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY healthcheck.php /var/www/html/healthcheck.php
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY scripts/container-init.sh /usr/local/bin/container-init.sh
COPY scripts/render-nginx-config.sh /usr/local/bin/render-nginx-config.sh
COPY scripts/phpbb-install.sh /usr/local/bin/phpbb-install.sh

# The installer route. Each build target overwrites this file with its
# own variant, so there is only ever one 'location /install/' block.
COPY nginx/phpbb-install-location-production.conf /etc/nginx/phpbb-install-location.conf

# 6. Permissions for the non-root user.
RUN mkdir -p /tmp/nginx /var/log/nginx /var/lib/nginx/tmp \
    && chown -R phpbb:phpbb /var/www/html /tmp/nginx /var/log/nginx /var/lib/nginx \
    && chmod 640 /var/www/html/config.php.template \
    && chmod 770 /var/www/html/cache /var/www/html/store /var/www/html/files /var/www/html/images/avatars/upload \
    && chmod 755 /usr/local/bin/*.sh

# The php base image sets STOPSIGNAL to SIGQUIT, which the container
# does not handle. A pod deletion would fall through to SIGKILL after
# the grace period, and the container would be killed rather than shut
# down. Reset it to SIGTERM, which container-init.sh traps.
STOPSIGNAL SIGTERM

# ==========================================
# Stage 2: the installer.
# ==========================================
# The installer needs to be reachable at /install/. Build this target
# when you are installing a board for the first time.
FROM base AS installer
COPY nginx/phpbb-install-location-installer.conf /etc/nginx/phpbb-install-location.conf
USER phpbb
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/bin/container-init.sh"]

# ==========================================
# Stage 3: the production runtime. The default.
# ==========================================
# The install/ directory is removed, so a running forum cannot be
# reinstalled by anyone who reaches the web interface.
FROM base AS production
RUN rm -rf /var/www/html/install
USER phpbb
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/bin/container-init.sh"]

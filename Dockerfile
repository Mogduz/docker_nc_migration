# -----------------------------------------------------------------------------
# Dockerfile — Nextcloud on Ubuntu 20.04 with Apache + PHP 7.4
# FIX: Avoid build failure on Ubuntu 20.04 where 'php-smbclient' may be absent.
#      - Remove 'php-smbclient' from the mandatory apt list
#      - Try to install it if present (via apt-cache)
#      - Optional PECL fallback controlled by INSTALL_SMBCLIENT_PECL=1
# Also keeps prior fixes (heredoc & split RUN after heredoc).
# -----------------------------------------------------------------------------

ARG UBUNTU_VERSION=20.04
FROM ubuntu:${UBUNTU_VERSION}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Build-time toggles
# 1 = install ffmpeg + libreoffice for previews
ARG INSTALL_PREVIEW=0
# 1 = install APCu/Redis/Memcached PHP clients
ARG INSTALL_MEMCACHES=1
# 1 = build/install smbclient PHP extension via PECL if not in apt
ARG INSTALL_SMBCLIENT_PECL=0
# Nextcloud version to fetch
ARG NEXTCLOUD_VERSION="28.0.10"

# ---- OS + PHP + Apache + Modules --------------------------------------------------
RUN set -eux \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       apache2 mariadb-client \
       ca-certificates curl wget gnupg tzdata \
       bzip2 unzip \
       php7.4 libapache2-mod-php7.4 \
       php7.4-xml php7.4-zip php7.4-gd php7.4-mbstring php7.4-curl php7.4-opcache \
       php7.4-bz2 php7.4-intl php7.4-gmp php7.4-bcmath \
       php7.4-ldap php7.4-imap php7.4-ftp php7.4-exif \
       php7.4-mysql php7.4-pgsql php7.4-sqlite3 \
       php-imagick \
    # Try to install php-smbclient if available in this release; otherwise optionally build via PECL
    && if apt-cache show php-smbclient >/dev/null 2>&1; then \
         apt-get install -y --no-install-recommends php-smbclient; \
       elif [ "${INSTALL_SMBCLIENT_PECL}" = "1" ]; then \
         apt-get install -y --no-install-recommends php-pear php7.4-dev libsmbclient libzip-dev gcc make; \
         printf "\n" | pecl install smbclient; \
         echo "extension=smbclient.so" > /etc/php/7.4/mods-available/smbclient.ini; \
         phpenmod smbclient; \
       else \
         echo "php-smbclient not available in apt (Ubuntu ${UBUNTU_VERSION}); skipping."; \
       fi \
    # Optional memcache clients
    && if [ "${INSTALL_MEMCACHES}" = "1" ]; then \
         apt-get install -y --no-install-recommends php-apcu php-redis php-memcached; \
       fi \
    # Optional preview stack
    && if [ "${INSTALL_PREVIEW}" = "1" ]; then \
         apt-get install -y --no-install-recommends ffmpeg libreoffice; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# ---- Apache modules ---------------------------------------------------------------
RUN set -eux \
    && a2enmod rewrite headers env dir mime \
    && a2enmod setenvif || true \
    && a2dismod dav || true \
    && a2dismod dav_fs || true

# ---- Download + Verify Nextcloud --------------------------------------------------
WORKDIR /tmp/build
RUN set -eux \
    && NC_TARBALL="nextcloud-${NEXTCLOUD_VERSION}.tar.bz2" \
    && wget -O "${NC_TARBALL}" "https://download.nextcloud.com/server/releases/${NC_TARBALL}" \
    && wget -O "${NC_TARBALL}.sha256" "https://download.nextcloud.com/server/releases/${NC_TARBALL}.sha256" \
    && sha256sum -c "${NC_TARBALL}.sha256" < "${NC_TARBALL}" \
    && wget -O "${NC_TARBALL}.asc" "https://download.nextcloud.com/server/releases/${NC_TARBALL}.asc" || true \
    && if [ -s "${NC_TARBALL}.asc" ]; then \
         wget -O /tmp/nextcloud.asc https://nextcloud.com/nextcloud.asc; \
         gpg --import /tmp/nextcloud.asc; \
         gpg --verify "${NC_TARBALL}.asc" "${NC_TARBALL}"; \
       fi \
    && tar -xjf "${NC_TARBALL}" \
    && mv nextcloud /var/www/nextcloud \
    && chown -R www-data:www-data /var/www/nextcloud \
    && find /var/www/nextcloud -type d -exec chmod 750 {} \; \
    && find /var/www/nextcloud -type f -exec chmod 640 {} \; \
    && rm -rf /tmp/build

# ---- Apache vhost configuration (heredoc) ----------------------------------------
RUN set -eux; \
  cat >/etc/apache2/sites-available/nextcloud.conf <<'EOF'
<VirtualHost *:80>
  ServerName localhost
  DocumentRoot /var/www/nextcloud

  <Directory /var/www/nextcloud/>
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
    <IfModule mod_dav.c>
      Dav off
    </IfModule>
    # If parent dirs have basic auth, disable it for DAV endpoints
    # Satisfy Any
  </Directory>
</VirtualHost>
EOF

# Enable vhost in a separate RUN
RUN set -eux \
    && a2dissite 000-default.conf \
    && a2ensite nextcloud.conf

# ---- PHP recommended runtime tweaks (optional) ------------------------------------
RUN set -eux \
    && PHP_INI_DIR="/etc/php/7.4/apache2" \
    && { \
         echo "memory_limit = 512M"; \
         echo "upload_max_filesize = 512M"; \
         echo "post_max_size = 512M"; \
         echo "max_execution_time = 360"; \
       } > "${PHP_INI_DIR}/conf.d/99-nextcloud.ini"

# ---- Copy the bootstrap script from build context ---------------------------------
COPY ./src/bootstrap-nextcloud-apache-config.sh /usr/local/bin/bootstrap-nextcloud-apache-config.sh
RUN chmod +x /usr/local/bin/bootstrap-nextcloud-apache-config.sh

# ---- Volumes & Healthcheck --------------------------------------------------------
VOLUME ["/var/www/nextcloud", "/var/www/nextcloud/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://localhost/status.php || curl -fsS http://127.0.0.1/status.php || exit 1

# ---- Expose & Launch --------------------------------------------------------------
EXPOSE 80
STOPSIGNAL SIGWINCH
ENTRYPOINT ["/usr/local/bin/bootstrap-nextcloud-apache-config.sh"]
CMD ["/usr/sbin/apachectl", "-D", "FOREGROUND"]

# -----------------------------------------------------------------------------
# Build examples
#   # default (skip smbclient if absent in apt)
#   docker build -t nc_migrate:latest .
#
#   # force PECL build of smbclient if apt package is missing
#   docker build -t nc_migrate:pecl --build-arg INSTALL_SMBCLIENT_PECL=1 .
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Dockerfile — Nextcloud on Ubuntu 20.04 with Apache + PHP 7.4
# NOTES:
#   • Fixed: Dockerfile parser error caused by inline comments after ARG.
#     Dockerfiles do NOT support trailing inline comments; comments must be on
#     their own line beginning with '#'.
#   • Also keeps the corrected heredoc for vhost creation.
#   • ENTRYPOINT runs /usr/local/bin/bootstrap-nextcloud-apache-config.sh
# -----------------------------------------------------------------------------

ARG UBUNTU_VERSION=20.04
FROM ubuntu:${UBUNTU_VERSION}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Build-time toggles (place comments on separate lines — no inline comments)
# 1 = install ffmpeg + libreoffice for previews
ARG INSTALL_PREVIEW=0
# 1 = install APCu/Redis/Memcached PHP clients
ARG INSTALL_MEMCACHES=1
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
       php-imagick php-smbclient \
    && if [ "${INSTALL_MEMCACHES}" = "1" ]; then \
         apt-get install -y --no-install-recommends php-apcu php-redis php-memcached; \
       fi \
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

# ---- Apache vhost configuration (fixed heredoc) ----------------------------------
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
  a2dissite 000-default.conf; \
  a2ensite nextcloud.conf

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
# Build:
#   docker build -t my-nextcloud:28-php74 .
# Run:
#   docker run -d --name nextcloud -p 8080:80 \
#     -v $(pwd)/apache_config:/mnt/apache_config \
#     -v nc_data:/var/www/nextcloud/data \
#     my-nextcloud:28-php74
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Dockerfile — Nextcloud on Ubuntu 20.04 with Apache + PHP 7.4
# (integrated /src/bootstrap-nextcloud-apache-config.sh as container ENTRYPOINT)
# -----------------------------------------------------------------------------
# This image installs Nextcloud with Apache HTTPD and PHP 7.4 on Ubuntu 20.04
# and copies a startup script from ./src/bootstrap-nextcloud-apache-config.sh
# into /usr/local/bin. On container start, that script ensures an Apache vhost
# exists at /mnt/apache_config/nextcloud.conf (seeding a sample if missing)
# and then launches Apache in the foreground.
# -----------------------------------------------------------------------------

ARG UBUNTU_VERSION=20.04
FROM ubuntu:${UBUNTU_VERSION}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# ---- Build-time toggles (optional) ------------------------------------------------
ARG INSTALL_PREVIEW=0     # 1 = install ffmpeg + libreoffice for previews
ARG INSTALL_MEMCACHES=1   # 1 = install APCu/Redis/Memcached PHP clients
ARG NEXTCLOUD_VERSION="25.0.13"

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

# ---- Apache modules required/recommended by Nextcloud ------------------------------
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

# ---- Apache vhost configuration ---------------------------------------------------
RUN set -eux \
    && cat >/etc/apache2/sites-available/nextcloud.conf <<'EOF' \
<VirtualHost *:80>\n  ServerName localhost\n  DocumentRoot /var/www/nextcloud\n\n  <Directory /var/www/nextcloud/>\n    Require all granted\n    AllowOverride All\n    Options FollowSymLinks MultiViews\n    <IfModule mod_dav.c>\n      Dav off\n    </IfModule>\n    # If parent dirs have basic auth, disable it for DAV endpoints\n    # Satisfy Any\n  </Directory>\n</VirtualHost>\nEOF \
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
# Place your script at ./src/bootstrap-nextcloud-apache-config.sh in the repo.
# The script will ensure /mnt/apache_config/nextcloud.conf exists on startup.
COPY ./src/bootstrap-nextcloud-apache-config.sh /usr/local/bin/bootstrap-nextcloud-apache-config.sh
RUN chmod +x /usr/local/bin/bootstrap-nextcloud-apache-config.sh

# ---- Volumes & Healthcheck --------------------------------------------------------
VOLUME ["/var/www/nextcloud", "/var/www/nextcloud/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://localhost/status.php || curl -fsS http://127.0.0.1/status.php || exit 1

# ---- Expose & Launch --------------------------------------------------------------
EXPOSE 80
STOPSIGNAL SIGWINCH

# Use the bootstrap script as entrypoint; it will exec Apache if no args given.
ENTRYPOINT ["/usr/local/bin/bootstrap-nextcloud-apache-config.sh"]
CMD ["/usr/sbin/apachectl", "-D", "FOREGROUND"]

# -----------------------------------------------------------------------------
# Build example:
#   docker build -t my-nextcloud:28-php74 \
#       --build-arg NEXTCLOUD_VERSION=28.0.10 \
#       --build-arg INSTALL_PREVIEW=1 \
#       --build-arg INSTALL_MEMCACHES=1 \
#       .
# Run example (bind-mount Apache config dir so it persists):
#   docker run -d --name nextcloud -p 8080:80 \
#       -v $(pwd)/apache_config:/mnt/apache_config \
#       -v nc_data:/var/www/nextcloud/data \
#       my-nextcloud:28-php74
# -----------------------------------------------------------------------------

#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# bootstrap-nextcloud-apache-config.sh (symlink variant)
# -----------------------------------------------------------------------------
# Purpose:
#   Ensure /mnt/apache_config/nextcloud.conf exists, then symlink it into
#   /etc/apache2/sites-available/nextcloud.conf and enable the site (which
#   creates the symlink in sites-enabled). Finally start Apache in foreground
#   (or exec CMD if provided).
#
# Why symlinks?
#   Keeping the canonical file under /mnt/apache_config allows you to edit and
#   persist the vhost outside the container while Apache reads it via the
#   distro’s standard sites-available/sites-enabled mechanism.
# -----------------------------------------------------------------------------
set -Eeuo pipefail

LOG_TAG="[bootstrap-config-symlink]"
CFG_DIR_MNT="/mnt/apache_config"
CFG_SRC="${CFG_DIR_MNT}/nextcloud.conf"
CFG_AVAIL_DIR="/etc/apache2/sites-available"
CFG_AVAIL_LINK="${CFG_AVAIL_DIR}/nextcloud.conf"

# Optional sample locations to seed initial config if missing
SAMPLE_CANDIDATES=(
  "/usr/local/share/nextcloud/nextcloud.conf.sample"
  "/etc/apache2/sites-available/nextcloud.conf"  # baked-in default (if present)
)

mkdir -p "${CFG_DIR_MNT}"

# Seed config if absent in /mnt/apache_config
if [[ ! -f "${CFG_SRC}" ]]; then
  echo "${LOG_TAG} No ${CFG_SRC} found. Seeding from sample or generating default…"
  FOUND_SRC=""
  for s in "${SAMPLE_CANDIDATES[@]}"; do
    if [[ -f "${s}" ]]; then FOUND_SRC="${s}"; break; fi
  done
  if [[ -n "${FOUND_SRC}" ]]; then
    cp -f "${FOUND_SRC}" "${CFG_SRC}"
    echo "${LOG_TAG} Seeded ${CFG_SRC} from ${FOUND_SRC}."
  else
    cat >"${CFG_SRC}" <<'EOF'
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
  </Directory>
</VirtualHost>
EOF
    echo "${LOG_TAG} Wrote minimal default config to ${CFG_SRC}."
  fi
  chown root:root "${CFG_SRC}" && chmod 0644 "${CFG_SRC}"
fi

# Link into sites-available and enable site (creates sites-enabled symlink)
mkdir -p "${CFG_AVAIL_DIR}"
rm -f "${CFG_AVAIL_LINK}"
ln -s "${CFG_SRC}" "${CFG_AVAIL_LINK}"

# Enable recommended modules (idempotent)
a2enmod rewrite headers env dir mime >/dev/null 2>&1 || true
a2enmod setenvif >/dev/null 2>&1 || true
a2dismod dav dav_fs >/dev/null 2>&1 || true

# Enable vhost
a2dissite 000-default.conf >/dev/null 2>&1 || true
a2ensite nextcloud.conf >/dev/null 2>&1 || true

# Validate config before starting
if ! apache2ctl -t; then
  echo "${LOG_TAG} ERROR: Apache config test failed." >&2
  apache2ctl -t
  exit 1
fi

# Start Apache or exec provided command
if [[ $# -eq 0 ]]; then
  echo "${LOG_TAG} Starting Apache in foreground…"
  exec /usr/sbin/apachectl -D FOREGROUND
else
  echo "${LOG_TAG} Exec-ing: $*"
  exec "$@"
fi

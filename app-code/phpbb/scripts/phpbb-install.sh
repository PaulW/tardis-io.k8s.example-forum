#!/bin/sh
# =====================================================================
# A non-interactive phpBB installation.
# =====================================================================
#
# phpBB's CLI installer takes a YAML file shaped like
# `docs/install-config.sample.yml`. This script renders that file from
# the environment and runs the installer.
#
# The installer writes its own `config.php` with hardcoded values. The
# entrypoint re-renders the environment-driven config.php afterwards,
# so the database credentials stay in the environment and the image
# stays generic.
#
# Board settings that are not database connection details live in the
# phpbb_config table, not in config.php. Change them in the Admin
# Control Panel after the first install.
# =====================================================================
set -eu

PHPBB_ROOT="/var/www/html"
CONFIG_FILE="/tmp/phpbb-install.yml"

log() {
    echo "[phpbb-install] $*"
}

fail() {
    echo "[phpbb-install] ERROR: $*" >&2
    exit 1
}

: "${PHPBB_DB_HOST:?PHPBB_DB_HOST must be set}"
: "${PHPBB_DB_NAME:?PHPBB_DB_NAME must be set}"
: "${PHPBB_DB_USER:?PHPBB_DB_USER must be set}"
: "${PHPBB_ADMIN_PASSWORD:?PHPBB_ADMIN_PASSWORD must be set for the initial install}"

PHPBB_DB_PASS="${PHPBB_DB_PASS:-}"
PHPBB_DB_PORT="${PHPBB_DB_PORT:-3306}"
PHPBB_TABLE_PREFIX="${PHPBB_TABLE_PREFIX:-phpbb_}"
PHPBB_BOARD_NAME="${PHPBB_BOARD_NAME:-My Forum}"
PHPBB_BOARD_DESCRIPTION="${PHPBB_BOARD_DESCRIPTION:-A phpBB forum}"
PHPBB_BOARD_LANG="${PHPBB_BOARD_LANG:-en}"
PHPBB_ADMIN_NAME="${PHPBB_ADMIN_NAME:-admin}"
PHPBB_ADMIN_EMAIL="${PHPBB_ADMIN_EMAIL:-admin@example.com}"
PHPBB_SERVER_NAME="${PHPBB_SERVER_NAME:-localhost}"
PHPBB_SERVER_PORT="${PHPBB_SERVER_PORT:-8080}"
PHPBB_SERVER_PROTOCOL="${PHPBB_SERVER_PROTOCOL:-http://}"
PHPBB_SCRIPT_PATH="${PHPBB_SCRIPT_PATH:-/}"
PHPBB_COOKIE_SECURE="${PHPBB_COOKIE_SECURE:-false}"

# cookie_secure has to be a YAML boolean, not a quoted string. The
# installer rejects a string with INVALID_CONFIGURATION.
case "${PHPBB_COOKIE_SECURE}" in
    true|false) ;;
    *) fail "PHPBB_COOKIE_SECURE must be 'true' or 'false', got '${PHPBB_COOKIE_SECURE}'" ;;
esac

# Escape a value for a single-quoted YAML string.
yaml_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

log "rendering the install configuration"

cat > "${CONFIG_FILE}" <<EOF
installer:
    admin:
        name: $(yaml_quote "${PHPBB_ADMIN_NAME}")
        password: $(yaml_quote "${PHPBB_ADMIN_PASSWORD}")
        email: $(yaml_quote "${PHPBB_ADMIN_EMAIL}")

    board:
        lang: $(yaml_quote "${PHPBB_BOARD_LANG}")
        name: $(yaml_quote "${PHPBB_BOARD_NAME}")
        description: $(yaml_quote "${PHPBB_BOARD_DESCRIPTION}")

    database:
        dbms: mysqli
        dbhost: $(yaml_quote "${PHPBB_DB_HOST}")
        dbport: ${PHPBB_DB_PORT}
        dbuser: $(yaml_quote "${PHPBB_DB_USER}")
        dbpasswd: $(yaml_quote "${PHPBB_DB_PASS}")
        dbname: $(yaml_quote "${PHPBB_DB_NAME}")
        table_prefix: $(yaml_quote "${PHPBB_TABLE_PREFIX}")

    email:
        enabled: false
        smtp_delivery: ~
        smtp_host: ~
        smtp_port: ~
        smtp_auth: ~
        smtp_user: ~
        smtp_pass: ~

    server:
        cookie_secure: ${PHPBB_COOKIE_SECURE}
        server_protocol: $(yaml_quote "${PHPBB_SERVER_PROTOCOL}")
        force_server_vars: false
        server_name: $(yaml_quote "${PHPBB_SERVER_NAME}")
        server_port: ${PHPBB_SERVER_PORT}
        script_path: $(yaml_quote "${PHPBB_SCRIPT_PATH}")

    extensions: []
EOF

# The installer's own "already installed" guard reads config.php, and a
# leftover install_lock from a previous run would make it think an
# install is already in progress.
rm -f "${PHPBB_ROOT}/cache/install_lock"

log "running the installer"
cd "${PHPBB_ROOT}"
php install/phpbbcli.php install "${CONFIG_FILE}" --no-interaction

# The installer writes cache/install_lock while it works and removes it
# when it finishes. Remove any leftover so the next container start is
# not blocked.
rm -f "${PHPBB_ROOT}/cache/install_lock"

log "install complete"

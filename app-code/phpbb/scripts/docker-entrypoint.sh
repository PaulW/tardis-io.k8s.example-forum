#!/bin/sh
# =====================================================================
# The container entrypoint.
#
# Responsibilities:
#   1. Render config.php from config.php.template using the
#      environment. The environment is the single source of truth for
#      the database connection, so one image works locally and in the
#      cluster with no rebuild.
#   2. Render the nginx configuration, if there is a template.
#   3. Hand over to the container's command.
#
# This runs as PID 1's parent, and the command it hands over to is the
# container's PID 1.
# =====================================================================
set -eu

PHPBB_ROOT="/var/www/html"
CONFIG_TEMPLATE="${PHPBB_ROOT}/config.php.template"
CONFIG_FILE="${PHPBB_ROOT}/config.php"
INSTALL_LOCK="${PHPBB_ROOT}/cache/install_lock"

log() {
    echo "[entrypoint] $*"
}

fail() {
    echo "[entrypoint] ERROR: $*" >&2
    exit 1
}

# --- 1. Validate the required environment ---------------------------------
#
# The password may legitimately be empty, so it does not use the `:?`
# form that fails on an empty value.
: "${PHPBB_DB_HOST:?PHPBB_DB_HOST must be set}"
: "${PHPBB_DB_NAME:?PHPBB_DB_NAME must be set}"
: "${PHPBB_DB_USER:?PHPBB_DB_USER must be set}"

PHPBB_DB_PASS="${PHPBB_DB_PASS:-}"
PHPBB_DB_PORT="${PHPBB_DB_PORT:-3306}"
PHPBB_TABLE_PREFIX="${PHPBB_TABLE_PREFIX:-phpbb_}"
PHPBB_PATH_PREFIX="${PHPBB_PATH_PREFIX:-}"
PHPBB_INSTALLED="${PHPBB_INSTALLED:-true}"
PHPBB_RUN_INSTALLER="${PHPBB_RUN_INSTALLER:-false}"
# --- 2. Render config.php --------------------------------------------------
#
# The template is already valid PHP. It reads its values from the
# environment at runtime, so there is nothing to substitute except the
# install-state marker. Copying the file keeps the credentials out of
# the image and out of the process arguments.
#
# The marker matters. phpBB's installer guard is:
#
#   file_exists(config.php) && !file_exists(cache/install_lock) && filesize(config.php)
#
# So a NON-EMPTY config.php blocks the installer, and an empty one
# with the lock present lets it run.
if [ "${PHPBB_INSTALLED}" = "true" ]; then
    installed_block="@define('PHPBB_INSTALLED', true);"
else
    installed_block="// PHPBB_INSTALLED intentionally not defined (installer mode)."
fi

render_config() {
    sed "s|@@PHPBB_INSTALLED_BLOCK@@|${installed_block}|" \
        "${CONFIG_TEMPLATE}" > "${CONFIG_FILE}"
    chmod 640 "${CONFIG_FILE}"
}

# --- 2b. Run the installer -------------------------------------------------
#
# The installer is a one-shot job. It must not start the web server,
# or the container would run forever and the install would never be
# reported as complete. In the cluster this is a Kubernetes Job, which
# has to run to completion and exit 0.
if [ "${PHPBB_RUN_INSTALLER}" = "true" ]; then
    if [ ! -f "${PHPBB_ROOT}/install/phpbbcli.php" ]; then
        fail "install/phpbbcli.php is not there - the installer build target is required"
    fi

    log "running the phpBB installer"

    # Empty the config file and create the lock, so the installer's
    # guard is satisfied and the installer is allowed to run.
    : > "${CONFIG_FILE}"
    touch "${INSTALL_LOCK}"

    /usr/local/bin/phpbb-install.sh

    log "the installer finished - restoring the environment-driven config.php"
    render_config
    log "install complete, exiting"
    exit 0
fi

render_config

# --- 3. Render the nginx configuration ------------------------------------
#
# The rendered file goes in /tmp, because the container runs as a
# non-root user and cannot write to /etc/nginx.
if [ -f /etc/nginx/nginx.conf.template ]; then
    log "rendering the nginx configuration"
    PHPBB_PATH_PREFIX="${PHPBB_PATH_PREFIX}" \
        /usr/local/bin/render-nginx-config.sh \
        /etc/nginx/nginx.conf.template \
        /tmp/nginx.conf
fi

# --- 4. Hand over ----------------------------------------------------------
log "handing over to: $*"
exec "$@"

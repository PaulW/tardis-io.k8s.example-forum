#!/bin/sh
# =====================================================================
# phpBB scheduled tasks.
# =====================================================================
# phpBB runs housekeeping (pruning forums, tidying sessions, clearing
# caches, sending queued mail) through a set of cron tasks. phpBB
# triggers them opportunistically when a visitor loads a page, but
# that is not reliable for a low-traffic forum. This script runs them
# on a schedule instead.
#
# `bin/phpbbcli.php cron:run` with no argument runs every task that is
# ready. The command takes a database-backed lock, so it is safe to
# run from more than one replica at the same time.
#
# In the cluster this maps to a Kubernetes CronJob. Locally it maps to
# a `cron` service in docker-compose.
# =====================================================================
set -eu

PHPBB_ROOT="/var/www/html"

log() {
    echo "[phpbb-cron] $*"
}

cd "${PHPBB_ROOT}"

# phpBB's cron tasks need the environment-driven config.php to exist.
if [ ! -f "${PHPBB_ROOT}/config.php" ]; then
    echo "[phpbb-cron] ERROR: config.php not found - the entrypoint must run first" >&2
    exit 1
fi

log "running ready cron tasks"
php bin/phpbbcli.php cron:run --verbose

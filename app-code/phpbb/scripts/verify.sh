#!/bin/sh
# =====================================================================
# End-to-end verification of the local phpBB stack.
# =====================================================================
# Checks the behaviours that were previously broken:
#   1. The forum serves real content (no installer redirect loop).
#   2. config.php is driven by the environment, not hardcoded values.
#   3. config.php is not reachable over HTTP.
#   4. The installer is not reachable in the production image.
#   5. The nginx deny rule does not block ordinary forum URLs.
#   6. The liveness and readiness probes behave correctly.
#   7. The container runs as UID 1000 and can write its data paths.
#   8. The scheduled tasks run.
# =====================================================================
set -u

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
CONTAINER="${PHPBB_CONTAINER:-phpbb-app}"

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
}

# check <description> <expected> <actual>
check() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected '$2', got '$3')"
    fi
}

status_of() {
    curl -sS -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

echo "=== phpBB verification against ${BASE_URL} ==="
echo

echo "--- container ---"
if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
    running=$(docker inspect -f '{{.State.Status}}' "${CONTAINER}")
    check "container is running" "running" "${running}"

    uid=$(docker exec "${CONTAINER}" id -u 2>/dev/null || echo "unknown")
    check "container runs as UID 1000" "1000" "${uid}"

    for path in /var/www/html/cache /var/www/html/store /var/www/html/files /var/www/html/images/avatars/upload; do
        if docker exec "${CONTAINER}" sh -c "touch '${path}/.verify-write' && rm -f '${path}/.verify-write'" >/dev/null 2>&1; then
            pass "writable: ${path}"
        else
            fail "writable: ${path}"
        fi
    done
else
    fail "container ${CONTAINER} exists"
fi

echo
echo "--- probes ---"
check "liveness /healthz" "200" "$(status_of "${BASE_URL}/healthz")"
check "readiness /readyz" "200" "$(status_of "${BASE_URL}/readyz")"

echo
echo "--- routing ---"
check "forum root serves content" "200" "$(status_of "${BASE_URL}/")"

title=$(curl -sS "${BASE_URL}/" 2>/dev/null | grep -o -m1 '<title>[^<]*</title>' || echo "none")
case "${title}" in
    *Install*|*install*) fail "page title is not the installer (got '${title}')" ;;
    "<title>") fail "page has no title" ;;
    *) pass "page title is the forum (${title})" ;;
esac

# The installer redirect is a 302 to /install/app.php. A 302 to the
# forum index is fine; a 302 to the installer is not.
location=$(curl -sS -D - -o /dev/null "${BASE_URL}/" 2>/dev/null | grep -i '^location:' | tr -d '\r' || echo "")
case "${location}" in
    *install*) fail "forum redirects to the installer (${location})" ;;
    *) pass "forum does not redirect to the installer" ;;
esac

echo
echo "--- security ---"
check "config.php is blocked" "404" "$(status_of "${BASE_URL}/config.php")"
check "install/ is blocked" "404" "$(status_of "${BASE_URL}/install/app.php")"
check "store/ is blocked" "404" "$(status_of "${BASE_URL}/store/x")"
check "files/ is blocked" "404" "$(status_of "${BASE_URL}/files/x")"
check "cache/ is blocked" "404" "$(status_of "${BASE_URL}/cache/x")"
check "vendor/ is blocked" "404" "$(status_of "${BASE_URL}/vendor/x")"

echo
echo "--- the deny rule must not block forum URLs ---"
# These slugs match the OLD unanchored deny pattern and were broken.
# phpBB itself answers 404 for an unknown topic, so a 404 is expected
# here. The check is that the response is a phpBB page and NOT the
# nginx "404 Not Found" body that a denied path returns.
for slug in phpbb-tips cache-thread store-talk files-index includes-help; do
    body=$(curl -sS "${BASE_URL}/app.php/${slug}" 2>/dev/null)
    case "${body}" in
        *"nginx"*) fail "forum URL /app.php/${slug} was denied by nginx" ;;
        *) pass "forum URL /app.php/${slug} reaches phpBB" ;;
    esac
done

echo
echo "--- config.php is environment-driven ---"
if docker exec "${CONTAINER}" grep -q "getenv('PHPBB_DB_HOST')" /var/www/html/config.php 2>/dev/null; then
    pass "config.php reads PHPBB_DB_HOST from the environment"
else
    fail "config.php does not read PHPBB_DB_HOST from the environment"
fi

if docker exec "${CONTAINER}" grep -q "getenv('PHPBB_DB_PASS')" /var/www/html/config.php 2>/dev/null; then
    pass "config.php reads PHPBB_DB_PASS from the environment"
else
    fail "config.php does not read PHPBB_DB_PASS from the environment"
fi

# The password must never be written into the file. Check for the
# literal value that the local stack uses.
if docker exec "${CONTAINER}" grep -q "phpbb_secret_password" /var/www/html/config.php 2>/dev/null; then
    fail "config.php contains a hardcoded password"
else
    pass "config.php has no hardcoded password"
fi

# The install state must be set for the production image.
if docker exec "${CONTAINER}" grep -q "define('PHPBB_INSTALLED', true)" /var/www/html/config.php 2>/dev/null; then
    pass "config.php defines PHPBB_INSTALLED"
else
    fail "config.php does not define PHPBB_INSTALLED"
fi

perms=$(docker exec "${CONTAINER}" stat -c '%a' /var/www/html/config.php 2>/dev/null || echo "unknown")
case "${perms}" in
    640|600) pass "config.php permissions are owner-only (${perms})" ;;
    *) fail "config.php permissions are too open (${perms})" ;;
esac

echo
echo "--- logs ---"
# The container must write one access log line per request, not two.
# PHP-FPM logs every request it serves and nginx logs every request
# it forwards, so with both logs on, every request through the forum
# was written twice. The PHP-FPM line is the less useful of the two:
# it has no client address, because the request came from nginx on
# the loopback, and no query string, because it logs the SCRIPT_NAME
# after the rewrite.
#
# The two formats are told apart by the timestamp. nginx puts its
# timestamp in square brackets, and PHP-FPM does not:
#
#   nginx   127.0.0.1 - - [26/Oct/2026:18:23:19 +0000] "GET /forum/" 200
#   PHP-FPM 127.0.0.1 -  26/Oct/2026:18:23:19 +0000 "GET /forum/" 200
#
# The check counts the PHP-FPM lines, which must be none. The check
# is on the log and not on the config, because the config alone does
# not prove that the log is off.
curl -sS -o /dev/null "${BASE_URL}/index.php" 2>/dev/null
sleep 2
fpm_lines=$(docker logs "${CONTAINER}" 2>&1 \
    | grep -cE '^[0-9a-fA-F:.]+ - .*[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4} "' || true)
check "one log line per request (no PHP-FPM duplicate)" "0" "${fpm_lines}"

# The PHP-FPM access log must be off in the pool config. It is set
# in zz-phpbb.conf, the last file in the pool directory, so it
# overrides the stock setting in docker.conf.
access_log=$(docker exec "${CONTAINER}" sh -c \
    "php-fpm -tt 2>&1 | grep -E 'access\.log =' | head -1" 2>/dev/null | sed 's/.*access\.log = //')
check "the PHP-FPM access log is off" "/dev/null" "${access_log}"

echo
echo "--- performance settings ---"
# These are the settings that decide how much work a request costs.
# The measurements behind each one are in
# backup_recover/CLUSTER-DEPLOY.md.

# The OPcache must not stat() every included file on every request.
# The forum's code does not change while the pod is running, and a
# deployment replaces the pod.
check "opcache.validate_timestamps is off" "0" \
    "$(docker exec "${CONTAINER}" php -r 'echo ini_get("opcache.validate_timestamps");' 2>/dev/null)"

# The setting sizes the hash that maps a cached file to its slot, and
# the size is the value rounded up to the next prime. The primes PHP
# uses are 7963, then 16229, so anything from 7964 to 16229 gives a
# hash of 16229 slots and the setting makes no difference at all.
#
# Below 7963 the hash is 7963 slots, which is still more than twice
# the number of PHP files a phpBB board has, and it allocates 387 KiB
# less shared memory.
#
# The check is on the value that produces the small hash, not on the
# value itself, because 6500 and 7000 and 7963 all mean the same
# thing to the OPcache.
opcache_files=$(docker exec "${CONTAINER}" php -r 'echo ini_get("opcache.max_accelerated_files");' 2>/dev/null)
if [ "${opcache_files:-0}" -ge 6500 ] 2>/dev/null \
   && [ "${opcache_files:-0}" -le 7963 ] 2>/dev/null; then
    pass "opcache.max_accelerated_files gives the 7963 slot hash (${opcache_files})"
else
    fail "opcache.max_accelerated_files is not in the 6500 to 7963 range (${opcache_files})"
fi

# The pool must NOT be larger than the number of database connections
# the database user is allowed. The chart sets `maxUserConnections`
# on the User CR, and that is a hard limit. A worker that cannot get
# a connection fails the request with "MySQL server has gone away",
# and the forum answers 503.
#
# The limit is the one that matters, not the pool size on its own. A
# pool of 8 is correct against a limit of 10, and a pool of 30 is
# not, unless the limit is 40.
#
# The limit can be read from the User CR, but the verify script
# runs against the local stack, where the database is a plain
# container with no CR. The limit is passed in the environment, and
# it defaults to the 10 that the operator applies when the chart
# does not set it.
#
# The forum sets 40 in deployment/environments/values.yaml, and the
# pool is 30. The check must be run with the same limit, or it is
# checking the wrong thing:
#
#   DB_MAX_CONNECTIONS=40 make verify
DB_MAX_CONNECTIONS="${DB_MAX_CONNECTIONS:-10}"

max_children=$(docker exec "${CONTAINER}" sh -c \
    "php-fpm -tt 2>&1 | grep -E 'pm.max_children =' | head -1" 2>/dev/null | sed 's/.*= //')
if [ "${max_children:-0}" -gt 0 ] 2>/dev/null && [ "${max_children}" -lt "${DB_MAX_CONNECTIONS}" ] 2>/dev/null; then
    pass "the pool is below the connection limit (${max_children} of ${DB_MAX_CONNECTIONS})"
else
    fail "the pool exceeds the connection limit (${max_children} of ${DB_MAX_CONNECTIONS})"
fi

# A persistent connection is held by the worker for its whole life, so
# the pool is the number of connections. Without it, a worker holds a
# connection only while it is serving a request.
if [ "${PHPBB_DB_PERSISTENT:-0}" = "1" ] 2>/dev/null; then
    if [ "${max_children:-0}" -lt "${DB_MAX_CONNECTIONS}" ] 2>/dev/null; then
        pass "the persistent connection fits inside the limit"
    else
        fail "the persistent connection does not fit inside the limit"
    fi
fi

# The static assets must be compressed. phpBB compresses the HTML it
# generates, but not the stylesheets and the scripts, and those are
# the bulk of what a browser downloads.
gzip_static=$(curl -sS -H "Accept-Encoding: gzip" -o /dev/null -w '%{size_download}' \
    "${BASE_URL}/assets/css/font-awesome.min.css" 2>/dev/null)
gzip_plain=$(curl -sS -H "Accept-Encoding:" -o /dev/null -w '%{size_download}' \
    "${BASE_URL}/assets/css/font-awesome.min.css" 2>/dev/null)
if [ "${gzip_plain:-0}" -gt 0 ] && [ "${gzip_static:-0}" -lt "${gzip_plain}" ]; then
    pass "the static assets are compressed (${gzip_static} of ${gzip_plain} bytes)"
else
    fail "the static assets are not compressed (${gzip_static} of ${gzip_plain} bytes)"
fi

echo
echo "--- the scheduled tasks ---"
# phpBB runs the scheduled tasks opportunistically. When a visitor
# loads a page and a task is ready, phpBB puts a hidden image tag in
# the page and the browser fetches it:
#
#   <img class="sr-only" aria-hidden="true"
#        src="/forum/cron/cron.task.text_reparser.post_text?sid=...">
#
# This forum runs the tasks from a Kubernetes CronJob, so phpBB must
# not run them itself. The setting is use_system_cron.
#
# The URL is under /forum/cron/, which Cloudflare blocks, so the
# browser copy failed with a 403 in every visitor's console.
#
# The check is on the page, because the setting and the page are
# what matters, not the setting on its own.
#
# The pattern is "cron.task", and not "/cron/". The URL in the tag is
# HTML escaped, so the slashes are "&#x2F;" and a search for
# "/cron/" never matches it.
cron_refs=$(curl -sS "${BASE_URL}/index.php" 2>/dev/null | grep -c 'cron\.task' || true)
check "the page does not ask the browser to run the cron" "0" "${cron_refs}"

echo
echo "--- the database ---"
# The compound index on phpbb_sessions is the single most important
# index on the board. Without it, this query does a full table scan
# of the whole session table on every page load, for every user:
#
#   SELECT COUNT(session_id) FROM phpbb_sessions
#   WHERE session_user_id = 1 AND session_time >= <cutoff>
#
# In March 2026 that query scanned 345,991 rows on the old forum and
# took the database from 45 threads at load 35 down to 1 to 3
# threads once the index was added.
#
# phpBB 3.3.19's schema includes it, so it is normally there. The
# check is here because the loss of it is silent: the forum does not
# break, it just gets slow.
session_index=$(docker exec "${CONTAINER}" php /var/www/html/scripts/check-session-index.php 2>/dev/null | tail -1)
if [ "${session_index}" = "yes" ]; then
    pass "phpbb_sessions has the compound index on (session_user_id, session_time)"
elif [ "${session_index}" = "noconnection" ]; then
    echo "  SKIP the phpbb_sessions index check: the container cannot reach the database"
else
    fail "phpbb_sessions is missing the compound index on (session_user_id, session_time)"
fi

# nginx must keep the connection to PHP-FPM open, and must cache the
# open files, or every request pays for a new connection and every
# static file costs a stat() and an open().
for directive in "fastcgi_keep_conn on" "open_file_cache max="; do
    if docker exec "${CONTAINER}" sh -c "grep -q '$directive' /tmp/nginx.conf" 2>/dev/null; then
        pass "nginx has '${directive}'"
    else
        fail "nginx is missing '${directive}'"
    fi
done

echo
echo "--- container lifecycle ---"
# The image must use SIGTERM as the stop signal. The `php` base image
# sets SIGQUIT, which the container does not handle, so a pod deletion
# would fall through to SIGKILL.
stopsignal=$(docker inspect -f '{{.Config.StopSignal}}' "${CONTAINER}" 2>/dev/null || echo "unknown")
check "image stop signal is SIGTERM" "SIGTERM" "${stopsignal}"

# A failed child must terminate the container with a non-zero code so
# that Kubernetes restarts the pod. A container that keeps running with
# a dead worker hides the failure.
TEST_CONTAINER="phpbb-lifecycle-test"
docker rm -f "${TEST_CONTAINER}" >/dev/null 2>&1
docker run -d --name "${TEST_CONTAINER}" \
    -e PHPBB_DB_HOST=127.0.0.1 \
    -e PHPBB_DB_NAME=phpbb \
    -e PHPBB_DB_USER=phpbb \
    -e PHPBB_DB_PASS=unused \
    -e PHPBB_INSTALLED=true \
    "$(docker inspect -f '{{.Config.Image}}' "${CONTAINER}")" >/dev/null 2>&1

if [ "$(docker inspect -f '{{.State.Running}}' "${TEST_CONTAINER}" 2>/dev/null)" = "true" ]; then
    # Kill the PHP-FPM MASTER process. Killing a pool worker is not
    # enough: the master respawns it.
    #
    # The master is found by its PARENT, not by its process title.
    # The init script starts the master directly, so the master is
    # the php-fpm process whose parent is PID 1. The pool workers are
    # the master's children.
    #
    # The process title cannot be used for this. PHP-FPM rewrites its
    # own command line to "php-fpm: master process (...)", but only
    # when it can, and an image that does not rewrite it leaves the
    # title as the executable path. A check that matches on the title
    # then kills nothing at all, and reports the container's exit
    # code as if it were the result of the kill.
    #
    # The command line is read on its FIRST argument, because the
    # shell running this loop has its own script text in its command
    # line, and a substring match makes it kill itself.
    master=$(docker exec "${TEST_CONTAINER}" sh -c '
        for p in /proc/[0-9]*; do
            pid=${p#/proc/}
            [ "${pid}" = "1" ] && continue
            ppid=$(awk "{print \$4}" "${p}/stat" 2>/dev/null)
            [ "${ppid}" != "1" ] && continue
            first=$(tr "\0" "\n" < "${p}/cmdline" 2>/dev/null | head -1)
            case "${first}" in
                *php-fpm*) echo "${pid}"; break ;;
            esac
        done
    ' 2>/dev/null | tr -d '\r' | head -1)

    if [ -z "${master}" ]; then
        fail "the PHP-FPM master was found, so it can be killed"
    else
        pass "the PHP-FPM master was found (pid ${master})"

        docker exec "${TEST_CONTAINER}" sh -c "kill -9 ${master}" >/dev/null 2>&1

        # The master must actually be gone. If it is still there,
        # the kill did not work and the container's exit code says
        # nothing about the behaviour being tested.
        i=0
        while [ "${i}" -lt 10 ]; do
            alive=$(docker exec "${TEST_CONTAINER}" sh -c \
                "kill -0 ${master} 2>/dev/null && echo alive || echo gone" 2>/dev/null | tr -d '\r')
            [ "${alive}" = "gone" ] && break
            i=$((i + 1))
            sleep 1
        done
        if [ "${alive}" = "gone" ]; then
            pass "the PHP-FPM master was killed"
        else
            fail "the PHP-FPM master was killed (it is still running)"
        fi

        i=0
        while [ "${i}" -lt 20 ] && [ "$(docker inspect -f '{{.State.Running}}' "${TEST_CONTAINER}" 2>/dev/null || echo false)" = "true" ]; do
            i=$((i + 1))
            sleep 1
        done
        code=$(docker inspect -f '{{.State.ExitCode}}' "${TEST_CONTAINER}" 2>/dev/null || echo "-")
        if [ "${code}" != "0" ] && [ "${code}" != "-" ]; then
            pass "a failed child exits the container non-zero (${code})"
        else
            fail "a failed child exits the container non-zero (got ${code})"
        fi
    fi
else
    fail "lifecycle test container started"
fi
docker rm -f "${TEST_CONTAINER}" >/dev/null 2>&1

# A graceful stop must exit 0, so a pod deletion is not reported as a
# failure.
TEST_CONTAINER="phpbb-lifecycle-test"
docker rm -f "${TEST_CONTAINER}" >/dev/null 2>&1
docker run -d --name "${TEST_CONTAINER}" \
    -e PHPBB_DB_HOST=127.0.0.1 \
    -e PHPBB_DB_NAME=phpbb \
    -e PHPBB_DB_USER=phpbb \
    -e PHPBB_DB_PASS=unused \
    -e PHPBB_INSTALLED=true \
    "$(docker inspect -f '{{.Config.Image}}' "${CONTAINER}")" >/dev/null 2>&1
sleep 3
docker kill --signal=TERM "${TEST_CONTAINER}" >/dev/null 2>&1
i=0
while [ "${i}" -lt 30 ] && [ "$(docker inspect -f '{{.State.Running}}' "${TEST_CONTAINER}" 2>/dev/null || echo false)" = "true" ]; do
    i=$((i + 1))
    sleep 1
done
code=$(docker inspect -f '{{.State.ExitCode}}' "${TEST_CONTAINER}" 2>/dev/null || echo "-")
check "a graceful stop exits 0" "0" "${code}"
docker rm -f "${TEST_CONTAINER}" >/dev/null 2>&1

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ]

#!/bin/sh
# =====================================================================
# The container's PID 1: runs nginx and PHP-FPM.
# =====================================================================
#
# Two foreground processes have to run in one container, so the
# container needs a supervisor. A shell script is enough, and it
# removes a dependency.
#
# Behaviour
# ---------
# * If EITHER process exits, the other is stopped and this script
#   exits with a non-zero status. Kubernetes then restarts the pod. A
#   container must never keep running with a dead worker.
# * On SIGTERM (a pod deletion, or `docker stop`) both processes are
#   stopped gracefully and this script exits 0.
#
# The script runs as PID 1, so it must install a signal handler. PID 1
# in a namespace only receives the signals it has a handler for, and
# this handles SIGTERM, SIGINT and SIGQUIT.
#
# Why a poll loop and not `wait -n`
# ---------------------------------
# `wait -n` only returns when a CHILD of this shell exits. PHP-FPM
# does exactly the thing that breaks it: when the master is killed,
# the pool workers are re-parented to PID 1 and keep running, so
# `wait -n` never returns. The container would keep serving traffic
# with a dead master. The poll loop checks that each process is still
# alive, so the failure is detected however the process tree changed.
# =====================================================================
set -u

FPM_PID=""
NGINX_PID=""
SHUTDOWN=0
POLL_INTERVAL="${PHPBB_POLL_INTERVAL:-1}"

shutdown() {
    SHUTDOWN=1
    [ -n "${FPM_PID}" ] && kill -TERM "${FPM_PID}" 2>/dev/null
    [ -n "${NGINX_PID}" ] && kill -TERM "${NGINX_PID}" 2>/dev/null
    return 0
}

trap shutdown TERM INT QUIT

# --- Start the children ----------------------------------------------------
echo "[container-init] starting php-fpm" >&2
/usr/local/sbin/php-fpm -F &
FPM_PID=$!

echo "[container-init] starting nginx" >&2
# The configuration is the rendered one, when there is one.
if [ -f /tmp/nginx.conf ]; then
    /usr/sbin/nginx -c /tmp/nginx.conf -g 'daemon off;' &
else
    /usr/sbin/nginx -g 'daemon off;' &
fi
NGINX_PID=$!

# --- Watch the children ----------------------------------------------------
# The sleep runs as a child, so the signal handler interrupts it and
# the loop re-checks the shutdown flag.
while true; do
    sleep "${POLL_INTERVAL}" &
    wait $! 2>/dev/null

    if [ "${SHUTDOWN}" -eq 1 ]; then
        break
    fi

    if ! kill -0 "${FPM_PID}" 2>/dev/null; then
        echo "[container-init] php-fpm exited unexpectedly" >&2
        break
    fi

    if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
        echo "[container-init] nginx exited unexpectedly" >&2
        break
    fi
done

# --- Stop the surviving process -------------------------------------------
# Signal the whole process group of each child, so any workers that
# were re-parented are cleaned up too. A negative PID addresses the
# group. The direct PID is signalled as well, for the case where the
# child is not a group leader.
stop_children() {
    [ -n "${FPM_PID}" ] && kill -TERM "-${FPM_PID}" 2>/dev/null
    [ -n "${NGINX_PID}" ] && kill -TERM "-${NGINX_PID}" 2>/dev/null
    [ -n "${FPM_PID}" ] && kill -TERM "${FPM_PID}" 2>/dev/null
    [ -n "${NGINX_PID}" ] && kill -TERM "${NGINX_PID}" 2>/dev/null
    return 0
}

if [ "${SHUTDOWN}" -eq 1 ]; then
    echo "[container-init] shutdown requested, stopping php-fpm and nginx" >&2
    stop_children
    # Give them a moment to close their listeners, then insist.
    sleep 2
    stop_children
    wait "${FPM_PID}" 2>/dev/null
    wait "${NGINX_PID}" 2>/dev/null
    echo "[container-init] stopped cleanly" >&2
    exit 0
fi

# A process died. Stop the other one and fail, so Kubernetes restarts
# the pod and the failure is visible.
echo "[container-init] stopping the container so Kubernetes restarts the pod" >&2
stop_children
sleep 2
stop_children
wait "${FPM_PID}" 2>/dev/null
wait "${NGINX_PID}" 2>/dev/null

exit 1

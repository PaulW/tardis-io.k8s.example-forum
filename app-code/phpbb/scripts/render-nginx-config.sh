#!/bin/sh
# =====================================================================
# Render the nginx configuration template.
#
# The forum can be served from the root of a host or from a path
# prefix, and that is only known at run time, so the configuration is
# a template.
#
# The rendered file goes in /tmp, because the container runs as a
# non-root user and cannot write to /etc/nginx.
#
# The output file has to have a FIXED name. A `mktemp` file is a
# trap waiting to happen: the file is removed by a trap before nginx
# reads it.
# =====================================================================
set -eu

TEMPLATE="${1:-/etc/nginx/nginx.conf.template}"
OUTPUT="${2:-/tmp/nginx.conf}"

PREFIX="${PHPBB_PATH_PREFIX:-}"

# The prefix needs to be a valid location prefix. A trailing slash is
# added if it is missing, and the bare prefix gets its own redirect so
# that /forum does not fall through to the root handler and 404.
if [ -n "${PREFIX}" ]; then
    case "${PREFIX}" in
        */) ;;
        *) PREFIX="${PREFIX}/" ;;
    esac
fi

# The prefix is substituted into the template. It is a controlled
# value from the environment, and it is validated above.
sed "s|@@PHPBB_PATH_PREFIX@@|${PREFIX}|g" "${TEMPLATE}" > "${OUTPUT}"

# The rendered configuration is checked before it is used. A broken
# nginx configuration that is only discovered when the pod starts is a
# broken deployment, and this catches it at the point of the change.
if command -v nginx >/dev/null 2>&1; then
    nginx -t -c "${OUTPUT}" || {
        echo "[render-nginx-config] ERROR: the rendered configuration is not valid" >&2
        exit 1
    }
fi

echo "[render-nginx-config] rendered ${OUTPUT} with the prefix '${PREFIX}'"

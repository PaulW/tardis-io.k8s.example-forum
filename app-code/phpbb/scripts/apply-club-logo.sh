#!/bin/sh
# =====================================================================
# Put a site logo into the phpBB 3.3 prosilver theme.
# =====================================================================
# The stock prosilver theme draws the site logo with two rules:
#
#   theme/common.css
#     .site_logo { ... width: 149px; height: 52px; }
#   theme/colours.css
#     .site_logo { background-image: url("./images/site_logo.svg"); }
#
# A logo of a different size needs the box size changed as well as
# the image. The old board used exactly these values:
#
#   theme/common.css
#     .site_logo { display: inline-block; width: 295px; height: 96px; }
#   theme/colours.css
#     .site_logo { background-image: url("./images/site_logo.png"); }
#
# The rules are patched in place, in the image, at build time. The
# stock theme is not shipped in the repository, so the patch is the
# only way to change it. Each replacement is checked, so a prosilver
# upgrade that moves the rules fails the build rather than silently
# dropping the logo.
#
# Usage:
#   sh apply-club-logo.sh <html-root> <logo>
# =====================================================================
set -eu

ROOT="${1:-/var/www/html}"
THEME="${ROOT}/styles/prosilver/theme"
LOGO_SRC="${2:-/usr/local/share/phpbb-assets/style/site_logo.png}"

log() { echo "[logo] $*"; }
die() { echo "[logo] ERROR: $*" >&2; exit 1; }

[ -d "${THEME}" ] || die "the prosilver theme is not at ${THEME}"
[ -f "${LOGO_SRC}" ] || die "the logo is not at ${LOGO_SRC}"

# The club logo replaces the stock SVG.
cp "${LOGO_SRC}" "${THEME}/images/site_logo.png"
chmod 644 "${THEME}/images/site_logo.png"
log "the club logo is in place"

# colours.css: the image.
if grep -q 'background-image: url("./images/site_logo.svg");' "${THEME}/colours.css"; then
    sed -i 's|background-image: url("./images/site_logo.svg");|background-image: url("./images/site_logo.png");|' \
        "${THEME}/colours.css"
    log "colours.css: the logo image is the club PNG"
else
    die "colours.css does not have the expected .site_logo rule"
fi

# common.css: the box size.
if grep -q 'width: 149px;' "${THEME}/common.css" && grep -q 'height: 52px;' "${THEME}/common.css"; then
    sed -i 's|width: 149px;|width: 295px;|' "${THEME}/common.css"
    sed -i 's|height: 52px;|height: 96px;|' "${THEME}/common.css"
    log "common.css: the logo box is 295x96"
else
    die "common.css does not have the expected .site_logo size"
fi

# The result, so the build log shows what was done.
echo "[logo] the result:"
grep -A 2 -B 1 '^\.site_logo' "${THEME}/colours.css" | sed 's/^/[logo]   /'
grep -A 6 '^\.site_logo' "${THEME}/common.css" | sed 's/^/[logo]   /'

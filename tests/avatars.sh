#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced install.sh functions
# Set up avatar images against fake npm, npx, php, runuser and systemctl programs, and check what is written.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/calls" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

HOTEL_ROOT=$TEST_DIR/hotel
CAMERA_ENV=$TEST_DIR/etc/camera.env
CAMERA_BROWSERS=$TEST_DIR/browsers
CAMERA_APPARMOR=$TEST_DIR/apparmor
AVATAR_SECRET_FILE=$TEST_DIR/etc/avatar-imager.secret
AVATAR_CRON=$TEST_DIR/cron
NGINX_DIR=$TEST_DIR/nginx
renderer=$HOTEL_ROOT/emulator/CameraRenderer
cms=$HOTEL_ROOT/cms
mkdir -p "$TEST_DIR/fakebin" "$HOTEL_ROOT/emulator/Config" "$renderer" "$cms/app/Services" "$cms/bootstrap/cache" "$NGINX_DIR/sites-available" "$NGINX_DIR/conf.d"
for program in npm npx systemctl apparmor_parser nginx php; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$program" "$TEST_DIR" > "$TEST_DIR/fakebin/$program"
done
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH
runuser() { echo "runuser $*" >> "$TEST_DIR/calls"; }
chown() { :; }
install() { if [ "$1" = -d ]; then mkdir -p "${@: -1}"; fi; }
port_answers() { [ "$1" = 3921 ]; }
eval "$(declare -f camera_service | sed "s#/etc/systemd/system/plusemu-camera.service#$TEST_DIR/unit#")"
camera_value() { sed -n "s/^$1=//p" "$CAMERA_ENV"; }
website_value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$cms/.env"; }
echo '{"Camera":{"Bearer":"0123456789abcdef0123456789abcdef0123456789abcdef","OutputDirectory":"camera"}}' > "$HOTEL_ROOT/emulator/Config/config.json"
touch "$renderer/server.mjs"
printf 'APP_NAME="Hotel"\nAVATAR_IMAGER_SECRET=\n' > "$cms/.env"

# The secret is made once, kept private and reused.
secret=$(avatar_secret)
[ "${#secret}" = 48 ]
[ "$(stat -c %a "$AVATAR_SECRET_FILE")" = 600 ]
[ "$(avatar_secret)" = "$secret" ]

# A camera service that cannot draw avatars gets no avatar settings, and the website keeps the official imager.
camera_service
[ -z "$(camera_value AVATAR_IMAGER_SECRET)" ]
website_avatars
[ -z "$(website_value AVATAR_IMAGER_SECRET)" ]
[ ! -e "$AVATAR_CRON" ]

# A website that cannot sign addresses also keeps the official imager, even when the service could draw.
touch "$renderer/avatar.mjs"
camera_service
[ "$(camera_value AVATAR_IMAGER_SECRET)" = "$secret" ]
[ "$(camera_value AVATAR_IMAGER_ROOT)" = "$HOTEL_ROOT/avatars" ]
[ -d "$HOTEL_ROOT/avatars" ]
[ "$(stat -c %a "$CAMERA_ENV")" = 600 ]
website_avatars
[ -z "$(website_value AVATAR_IMAGER_SECRET)" ]

# With both sides ready the website signs with the same secret, and old images are cleaned up every day.
mkdir -p "$cms/app/Services/Avatar" && touch "$cms/app/Services/Avatar/AvatarImager.php"
touch "$cms/bootstrap/cache/config.php" # the website has cached its settings
: > "$TEST_DIR/calls"
website_avatars
[ "$(website_value AVATAR_IMAGER_SECRET)" = "$secret" ]
grep -q 'php artisan config:cache' "$TEST_DIR/calls"
grep -qF "find $HOTEL_ROOT/avatars -type f -atime +60 -delete" "$AVATAR_CRON"
grep -qF "find $HOTEL_ROOT/avatars -mindepth 2 -type d -empty -delete" "$AVATAR_CRON"
# A second run changes nothing and does not rebuild the website's settings.
: > "$TEST_DIR/calls"
website_avatars
[ "$(website_value AVATAR_IMAGER_SECRET)" = "$secret" ]
if grep -q 'php artisan' "$TEST_DIR/calls"; then echo 'the website settings were rebuilt without a change'; exit 1; fi

# An emulator release that no longer draws avatars sends the website back to the official imager.
rm "$renderer/avatar.mjs"
website_avatars
[ -z "$(website_value AVATAR_IMAGER_SECRET)" ]
[ ! -e "$AVATAR_CRON" ]
touch "$renderer/avatar.mjs"

# nginx serves a stored image itself, asks the camera service for a missing one, and keeps other websites out.
block=$(avatar_locations)
expect_block() { grep -qxF -- "$1" <<< "$block" || { echo "expected in the avatar block: $1"; echo "$block"; exit 1; }; }
expect_block '    location /avatars/ {'
expect_block "        root $HOTEL_ROOT;"
expect_block '        valid_referers none server_names;'
expect_block '        if ($invalid_referer) { return 403; }'
expect_block '        add_header Cache-Control "public, max-age=31536000, immutable";'
expect_block '        add_header Cross-Origin-Resource-Policy same-site always;'
expect_block '        try_files $uri @avatar;'
expect_block '        limit_req zone=plusemu_avatars burst=200 nodelay;'
expect_block '        proxy_pass http://127.0.0.1:3921;'
expect_block '        error_page 404 429 500 502 503 504 = @avatar_missing;'
expect_block '        add_header Cache-Control no-store always;'
expect_block '        empty_gif;'
request_limits
grep -qxF 'limit_req_zone $binary_remote_addr zone=plusemu_avatars:10m rate=20r/s;' "$NGINX_DIR/conf.d/plusemu-limits.conf"

# A site from an older installer gets the avatar route before the hotel files, and keeps the owner's own lines.
site=$NGINX_DIR/sites-available/hotel.conf
cat > "$site" <<'SITE'
server {
    # my own note
    location /camera/ { return 404; }

    # Furniture, clothes, badges and texts.
    location /hotel-files/ {
        expires 7d;
    }
}
SITE
original=$(cat "$site")
rm "$NGINX_DIR/conf.d/plusemu-limits.conf"
: > "$TEST_DIR/calls"
add_avatar_route
grep -qxF '    # my own note' "$site"
grep -qxF '    location /avatars/ {' "$site"
[ "$(grep -n 'location /avatars/ {' "$site" | cut -d: -f1)" -lt "$(grep -n 'Furniture, clothes' "$site" | cut -d: -f1)" ]
grep -q 'zone=plusemu_avatars' "$NGINX_DIR/conf.d/plusemu-limits.conf"
grep -q 'systemctl reload nginx' "$TEST_DIR/calls"
routed=$(cat "$site")
add_avatar_route
[ "$(cat "$site")" = "$routed" ]
# A site nginx rejects goes back to what it was.
printf '%s\n' "$original" > "$site"
nginx() { [ "$1" != -t ]; }
! add_avatar_route
[ "$(cat "$site")" = "$original" ]
unset -f nginx

printf 'Bash avatar checks passed\n' >&4

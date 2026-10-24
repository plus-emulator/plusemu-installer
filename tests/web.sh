#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced install.sh functions
# Write the nginx site against fake nginx, systemctl and curl programs, and check what it serves.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/fake/calls" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

export FAKE_DIR=$TEST_DIR/fake
NGINX_DIR=$TEST_DIR/nginx
REAL_IP_CONF=$NGINX_DIR/conf.d/cloudflare-real-ip.conf
SSL_DIR=$TEST_DIR/ssl
HOTEL_ROOT=$TEST_DIR/hotel
SITE=$NGINX_DIR/sites-available/hotel.conf
mkdir -p "$TEST_DIR/fakebin" "$FAKE_DIR" "$NGINX_DIR/conf.d" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled"
for program in systemctl ufw; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_DIR/calls"\n' "$program" > "$TEST_DIR/fakebin/$program"
done
printf '#!/usr/bin/env bash\necho "nginx $*" >> "$FAKE_DIR/calls"\nif [ "$1" = -v ]; then echo "nginx version: nginx/1.26.3" >&2; fi\n' > "$TEST_DIR/fakebin/nginx"
printf '#!/usr/bin/env bash\necho "curl $*" >> "$FAKE_DIR/calls"\nexit 7\n' > "$TEST_DIR/fakebin/curl"
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH
configure_firewall() { echo 'configure_firewall' >> "$FAKE_DIR/calls"; }

expect_site() { grep -qxF -- "$1" "$SITE" || { echo "expected in the site: $1"; cat "$SITE"; exit 1; }; }
game_block() { sed -n "\#location = $1 {#,\#^    }#p" "$SITE"; }
expect_game() { grep -qxF -- "$1" <<< "$(game_block "$2")" || { echo "expected in the game connection: $1"; game_block "$2"; exit 1; }; }
run_web() { : > "$FAKE_DIR/calls"; : > "$TEST_DIR/terminal"; derive_settings; configure_web; }

DOMAIN=example.com GUIDE_TOKEN=guidetoken12

# The game connection on the hotel's own name: nginx hands the visitor's address to the emulator.
WS_URL=wss://example.com/ws
run_web
expect_game '        if ($http_origin != "https://example.com") { return 403; }' /ws
expect_game '        proxy_pass http://127.0.0.1:2096;' /ws
expect_game '        proxy_set_header X-Real-IP $remote_addr;' /ws
expect_game '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' /ws
# Behind Cloudflare, $remote_addr is the visitor only because nginx restores it first.
grep -qx 'real_ip_header CF-Connecting-IP;' "$REAL_IP_CONF"
expect_site '    server_name example.com;'
expect_site '    listen 443 ssl;'
[ -L "$NGINX_DIR/sites-enabled/hotel.conf" ]
grep -qx 'configure_firewall' "$FAKE_DIR/calls"

# A game address of its own gets its own server with the same headers.
WS_URL=wss://ws.example.com/game
run_web
expect_site '    server_name ws.example.com;'
expect_game '        proxy_set_header X-Real-IP $remote_addr;' /game
expect_game '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' /game

printf 'Bash web server checks passed\n' >&4

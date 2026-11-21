#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; the state file is sourced
# Set up the AIR client against fake curl, ufw, nginx, php, systemctl and emulator programs, and check what it writes.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/calls" "$TEST_DIR/air.log" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

HOTEL_ROOT=$TEST_DIR/hotel
STATE_FILE=$TEST_DIR/etc/hotel.env
LOCK_FILE=$TEST_DIR/lock
LOG=$TEST_DIR/air.log
NGINX_DIR=$TEST_DIR/nginx
HEALTH_COMMAND=$TEST_DIR/sbin/plusemu-health
HEALTH_CRON=$TEST_DIR/cron.d/plusemu-health
HEALTH_LOG=$TEST_DIR/health.log
HEALTH_STATE=$TEST_DIR/health.state
AIR_MANIFEST_URL=https://assets.test/air/latest.json
export FAKE_DIR=$TEST_DIR/fake
emulator=$HOTEL_ROOT/emulator
config=$emulator/Config/config.json
mkdir -p "$TEST_DIR/fakebin" "$FAKE_DIR/air" "$emulator/Config" "$HOTEL_ROOT/cms" "$NGINX_DIR/sites-available"
: > "$FAKE_DIR/rules"
for program in systemctl php; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$program" "$TEST_DIR" > "$TEST_DIR/fakebin/$program"
done
# The fake ufw keeps its rules the way "ufw show added" prints them.
cat > "$TEST_DIR/fakebin/ufw" <<'FAKE'
#!/usr/bin/env bash
echo "ufw $*" >> "$FAKE_DIR/../calls"
case $1 in
    show) echo "Added user rules (see 'ufw status' for running firewall):"; sed 's/^/ufw /' "$FAKE_DIR/rules" ;;
    allow) if ! grep -qxF "allow $2" "$FAKE_DIR/rules"; then echo "allow $2" >> "$FAKE_DIR/rules"; fi ;;
esac
FAKE
# The emulator writes a new key, and refuses to overwrite one, like PlusEMU's --generate-rsa-key.
cat > "$emulator/Plus Emulator" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = --generate-rsa-key ] || exit 2
[ ! -e "$2" ] || exit 1
echo "key $RANDOM$RANDOM" > "$2"
echo "generate $2" >> "$FAKE_DIR/../calls"
FAKE
chmod +x "$TEST_DIR/fakebin/"* "$emulator/Plus Emulator"
export PATH=$TEST_DIR/fakebin:$PATH
chown() { :; }
nginx() { echo "nginx $*" >> "$TEST_DIR/calls"; }
# The published files are served from the fake folder, like assets.plusemu.dev.
curl() {
    local arg url='' out='' prev=''
    for arg in "$@"; do
        if [ "$prev" = -o ]; then out=$arg; fi
        if [[ $arg == http* ]]; then url=$arg; fi
        prev=$arg
    done
    case $url in
        https://assets.test/air/*)
            [ -f "$FAKE_DIR/air/${url##*/}" ] || return 22
            cp "$FAKE_DIR/air/${url##*/}" "$out" ;;
        *) return 7 ;;
    esac
}
publish() { # publish <version> <texts>: the manifest and the two text files
    printf 'flash.client.url=https://images.habbo.com/%s\n' "$1" > "$FAKE_DIR/air/external_variables.txt"
    printf '%s\n' "$2" > "$FAKE_DIR/air/external_flash_texts.txt"
    jq -n --arg version "$1" --arg variables "$(sha256sum "$FAKE_DIR/air/external_variables.txt" | cut -d' ' -f1)" \
        --arg texts "$(sha256sum "$FAKE_DIR/air/external_flash_texts.txt" | cut -d' ' -f1)" '{
        version: $version, habboVersion: "38",
        client: {url: "https://assets.test/air/client/\($version)/HabboWin.zip", sha256: ("0" * 64)},
        externalVariables: {url: "https://assets.test/air/external_variables.txt", sha256: $variables},
        externalFlashTexts: {url: "https://assets.test/air/external_flash_texts.txt", sha256: $texts}}' > "$FAKE_DIR/air/latest.json"
}
DOMAIN=example.com WS_URL=wss://example.com/ws HOTEL_NAME=Example ADMIN_USER=admin ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=initial-admin-password DB_PASSWORD=database-password GUIDE_TOKEN=guidetoken12 GUIDE_MODE=simple LOCAL=no
SERVER_IP=192.0.2.10

# ---------------------------------------------------------------- the saved choice

# --with-air and PLUSEMU_AIR=1 turn it on; a saved yes keeps it on without the option.
select_air
[ -z "$AIR" ]
AIR_OPTION=1 select_air
[ "$AIR" = yes ]
PLUSEMU_AIR=1 select_air ''
[ "$AIR" = yes ]
AIR_GAME_HOST=game.example.com
save_state
grep -qx "AIR='yes'" "$STATE_FILE"
AIR='' AIR_GAME_HOST=''
. "$STATE_FILE"
select_air "$AIR"
[ "$AIR" = yes ] && [ "$AIR_GAME_HOST" = game.example.com ]
AIR_GAME_HOST=''

# ---------------------------------------------------------------- the published files

publish 38-1 'texts one'
fetch_air_files "$emulator/Config"
[ "$AIR_VERSION" = 38-1 ]
[ "$AIR_CLIENT_URL" = https://assets.test/air/client/38-1/HabboWin.zip ]
[ "$(< "$emulator/Config/air/external_flash_texts.txt")" = 'texts one' ]
grep -q 'images.habbo.com/38-1' "$emulator/Config/air/external_variables.txt"
# A file that does not match its checksum changes nothing, and says why.
publish 39-1 'texts two'
printf 'tampered\n' > "$FAKE_DIR/air/external_flash_texts.txt"
AIR_VERSION='' AIR_CLIENT_URL=''
fetch_air_files "$emulator/Config" && exit 1
[[ $AIR_ERROR == *'external_flash_texts.txt'*'checksum'* ]]
[ "$(< "$emulator/Config/air/external_flash_texts.txt")" = 'texts one' ]
[ -z "$AIR_VERSION" ]
# A list that is not the AIR client list changes nothing either.
echo '{"version": "40-1"}' > "$FAKE_DIR/air/latest.json"
fetch_air_files "$emulator/Config" && exit 1
[[ $AIR_ERROR == *"$AIR_MANIFEST_URL"* ]]
# A new setup stops without the texts; one that has them keeps them; an update goes on without the AIR client.
rm -rf "$emulator/Config/air"
(air_texts "$emulator" new) && exit 1
grep -q 'Check the server' "$TEST_DIR/terminal"
air_texts "$emulator" update && exit 1
publish 38-1 'texts one'
air_texts "$emulator" new
: > "$TEST_DIR/terminal"
rm "$FAKE_DIR/air/latest.json"
air_texts "$emulator" update
grep -q 'keeps the texts it had' "$TEST_DIR/terminal"
publish 38-1 'texts one'
fetch_air_files "$emulator/Config"

# ---------------------------------------------------------------- the handshake key

echo '{"Encryption": {"RsaPrivateKeyFile": ""}}' > "$config"
air_key "$emulator"
key=$(< "$emulator/Config/rsa-private.pem")
[[ $key == key* ]]
# The key is made once: players' clients carry its modulus.
air_key "$emulator"
[ "$(< "$emulator/Config/rsa-private.pem")" = "$key" ]
[ "$(grep -c '^generate' "$TEST_DIR/calls")" = 1 ]
# A key the owner already set up is kept, also in another file.
echo 'my own key' > "$emulator/Config/mine.pem"
echo '{"Encryption": {"RsaPrivateKeyFile": "mine.pem"}}' > "$config"
air_key "$emulator"
[ "$(< "$emulator/Config/mine.pem")" = 'my own key' ]
[ "$(grep -c '^generate' "$TEST_DIR/calls")" = 1 ]

# ---------------------------------------------------------------- the emulator settings

cat > "$config" <<'EOF'
{
    "Database": {"Password": "secret"},
    "Flash": {"Hostname": "127.0.0.1", "Port": 1232, "Name": "Default Flash Server"},
    "Encryption": {"RsaPrivateKeyFile": ""},
    "AirClient": {"UrlPrefix": "", "ExternalVariablesFiles": [], "ExternalTextsFiles": ["my-texts.txt"], "ProductDataFile": "",
        "Variables": {"my.variable": "mine"}, "Name": "PlusEMU", "Environment": "en", "GameHost": "", "GamePorts": "30000",
        "ClientVersion": "", "ClientUrl": "", "TicketLifetimeSeconds": 60},
    "Camera": {"Bearer": "camera-password"}
}
EOF
chmod 600 "$config"
air_value() { jq -r "$1" "$config"; }
air_settings "$config"
[ "$(air_value .Flash.Hostname)" = 0.0.0.0 ] && [ "$(air_value .Flash.Port)" = 30000 ]
[ "$(air_value .Flash.Name)" = 'Default Flash Server' ]
[ "$(air_value .Encryption.RsaPrivateKeyFile)" = rsa-private.pem ]
[ "$(air_value .AirClient.UrlPrefix)" = https://example.com ]
[ "$(air_value '.AirClient.ExternalVariablesFiles | join(",")')" = air/external_variables.txt ]
[ "$(air_value '.AirClient.ExternalTextsFiles | join(",")')" = "air/external_flash_texts.txt,$HOTEL_ROOT/hotel-files/gamedata/ExternalTexts.json,my-texts.txt" ]
[ "$(air_value .AirClient.ProductDataFile)" = "$HOTEL_ROOT/hotel-files/gamedata/ProductData.json" ]
[ "$(air_value '.AirClient.Variables["external.texts.txt"]')" = https://example.com/gamedata/external_flash_texts/1 ]
[ "$(air_value '.AirClient.Variables["external.override.texts.txt"]')" = https://example.com/gamedata/external_flash_texts/1 ]
[ "$(air_value '.AirClient.Variables["badge.image.path"]')" = https://example.com/hotel-files/c_images/album1584 ]
[ "$(air_value '.AirClient.Variables["image.library.catalogue.url"]')" = https://example.com/hotel-files/c_images/catalogue/ ]
[ "$(air_value '.AirClient.Variables["my.variable"]')" = mine ]
[ "$(air_value .AirClient.GameHost)" = 192.0.2.10 ] && [ "$(air_value .AirClient.GamePorts)" = 30000 ]
[ "$(air_value .AirClient.ClientUrl)" = https://assets.test/air/client/38-1/HabboWin.zip ]
[ "$(air_value .AirClient.ClientVersion)" = 38-1 ]
# The other settings stay as they are.
[ "$(air_value .Database.Password)" = secret ] && [ "$(air_value .Camera.Bearer)" = camera-password ]
[ "$(air_value .AirClient.TicketLifetimeSeconds)" = 60 ] && [ "$(air_value .AirClient.Environment)" = en ]
[ "$(stat -c %a "$config")" = 600 ]
# A second run changes nothing.
settings=$(< "$config")
air_settings "$config"
[ "$(< "$config")" = "$settings" ]
# Without a new client list the client stays; game.<domain> wins once Cloudflare has it.
AIR_VERSION='' AIR_CLIENT_URL='' AIR_GAME_HOST=game.example.com
air_settings "$config"
[ "$(air_value .AirClient.ClientVersion)" = 38-1 ] && [ "$(air_value .AirClient.GameHost)" = game.example.com ]
# A local hotel keeps its game port on this PC.
LOCAL=yes air_settings "$config"
[ "$(air_value .Flash.Hostname)" = 127.0.0.1 ] && [ "$(air_value .AirClient.GameHost)" = 127.0.0.1 ]
[ "$(air_value .AirClient.UrlPrefix)" = http://localhost ]
AIR_GAME_HOST='' AIR_VERSION=38-1 AIR_CLIENT_URL=https://assets.test/air/client/38-1/HabboWin.zip

# ---------------------------------------------------------------- the website routes and the firewall

site=$NGINX_DIR/sites-available/hotel.conf
cat > "$site" <<'EOF'
server {
    # my own note
    location = /api/badges/leaderboard { proxy_pass http://127.0.0.1:8080; }

    # Furniture, clothes, badges and texts.
    location /hotel-files/ {
        expires 7d;
    }
}
EOF
original=$(cat "$site")
: > "$TEST_DIR/calls"
add_air_route
grep -qxF '    # my own note' "$site"
grep -qxF '    location = /api/client/air.json {' "$site"
grep -qxF '    location ~ ^/api/client/(air-ticket|air-launcher-token)$ {' "$site"
grep -qxF '    location = /gamedata/hashes {' "$site"
grep -qxF '    location ~ ^/gamedata/(external_flash_texts|external_variables|furnidata_xml|productdata)/[^/]+$ {' "$site"
[ "$(grep -c 'proxy_set_header X-Forwarded-Proto https;' "$site")" = 4 ]
[ "$(grep -n 'air.json' "$site" | cut -d: -f1)" -lt "$(grep -n 'Furniture, clothes' "$site" | cut -d: -f1)" ]
grep -q 'systemctl reload nginx' "$TEST_DIR/calls"
# A second run adds nothing.
routed=$(cat "$site")
add_air_route
[ "$(cat "$site")" = "$routed" ]
# A site nginx rejects goes back to what it was.
printf '%s\n' "$original" > "$site"
nginx() { [ "$1" != -t ]; }
add_air_route && exit 1
[ "$(cat "$site")" = "$original" ]
nginx() { echo "nginx $*" >> "$TEST_DIR/calls"; }
# A local hotel has no HTTPS.
[ "$(LOCAL=yes air_locations | grep -c 'X-Forwarded-Proto http;')" = 4 ]

# The game port is opened once, for every address.
air_firewall
air_firewall
[ "$(grep -c "^allow $AIR_PORT/tcp\$" "$FAKE_DIR/rules")" = 1 ]

# The website button is turned on once, with a fresh configuration cache.
printf 'APP_URL="https://example.com"\nAIR_CLIENT_ENABLED=false\n' > "$HOTEL_ROOT/cms/.env"
: > "$TEST_DIR/calls"
air_website
grep -qx 'AIR_CLIENT_ENABLED="true"' "$HOTEL_ROOT/cms/.env"
grep -qx 'APP_URL="https://example.com"' "$HOTEL_ROOT/cms/.env"
grep -q 'php artisan optimize$' "$TEST_DIR/calls"
: > "$TEST_DIR/calls"
air_website
if grep -q 'php' "$TEST_DIR/calls"; then echo 'the cache was rebuilt without a change'; exit 1; fi

# ---------------------------------------------------------------- Cloudflare

# game.<domain> gets an A record that Cloudflare does not proxy, and a proxied one is switched to DNS only.
CF_ZONE=zone1
cf_api() {
    echo "cf $1 $2 ${3:-}" >> "$TEST_DIR/calls"
    CF_BODY=$(< "$FAKE_DIR/records")
    [ "$1" = GET ] || CF_BODY='{"success": true, "result": {}}'
}
echo '{"success": true, "result": []}' > "$FAKE_DIR/records"
: > "$TEST_DIR/calls"
cloudflare_game_dns
grep -q 'cf POST /zones/zone1/dns_records .*"name":"game.example.com".*"proxied":false' "$TEST_DIR/calls"
[ "$AIR_GAME_HOST" = game.example.com ]
grep -qx "AIR_GAME_HOST='game.example.com'" "$STATE_FILE"
echo '{"success": true, "result": [{"id": "r1", "type": "A", "name": "game.example.com", "content": "192.0.2.10", "proxied": true}]}' > "$FAKE_DIR/records"
: > "$TEST_DIR/calls"
cloudflare_game_dns
grep -q 'cf PATCH /zones/zone1/dns_records/r1 {"content":"192.0.2.10","proxied":false}' "$TEST_DIR/calls"
echo '{"success": true, "result": [{"id": "r1", "type": "A", "name": "game.example.com", "content": "192.0.2.10", "proxied": false}]}' > "$FAKE_DIR/records"
: > "$TEST_DIR/calls"
cloudflare_game_dns
if grep -q 'PATCH\|POST' "$TEST_DIR/calls"; then echo 'a correct record was changed'; exit 1; fi
echo '{"success": true, "result": [{"id": "r1", "type": "CNAME", "name": "game.example.com"}]}' > "$FAKE_DIR/records"
cloudflare_game_dns && exit 1
[[ $CF_ERROR == *CNAME* ]]
AIR_GAME_HOST=''

# ---------------------------------------------------------------- the health check

for name in air_launcher air_gamedata air_port; do eval "health_$name() { echo 'health_$name' >> \"\$TEST_DIR/calls\"; }"; done
for entry in "${HEALTH_CHECKS[@]}"; do
    case $entry in air_*) ;; *) eval "health_${entry%%|*}() { :; }" ;; esac
done
mkdir -p "$(dirname "$HEALTH_STATE")"
: > "$TEST_DIR/calls"
AIR='' save_state
health_check > "$TEST_DIR/health"
if grep -q health_air "$TEST_DIR/calls"; then echo 'a hotel without the AIR client checks it'; exit 1; fi
grep -q 'OK: all 10 checks passed' "$TEST_DIR/health"
AIR=yes save_state
health_check > "$TEST_DIR/health"
[ "$(grep -c health_air "$TEST_DIR/calls")" = 3 ]
grep -q 'OK: all 13 checks passed' "$TEST_DIR/health"
health_air_launcher() { echo "https://example.com/api/client/air.json does not give the game address, handshake key and client (HTTP 404)."; return 1; }
sleep() { :; }
air_check && exit 1
[[ $AIR_ERROR == *'HTTP 404'* ]]

# ---------------------------------------------------------------- --with-air on an installed hotel

preflight() { :; }
wait_for_emulator() { :; }
derive_settings() { WS_HOST=example.com WS_PATH=/ws SITE_URL=https://example.com SERVER_IP=192.0.2.10; }
for name in air_launcher air_gamedata air_port; do eval "health_$name() { :; }"; done
printf '%s\n' "$original" > "$site"
printf 'APP_URL="https://example.com"\nAIR_CLIENT_ENABLED=false\n' > "$HOTEL_ROOT/cms/.env"
rm -f "$emulator/Config/rsa-private.pem" "$emulator/Config/mine.pem"
: > "$FAKE_DIR/rules"
AIR='' save_state
# An emulator without the AIR client saves the choice, so the next update sets it up.
echo '{"Flash": {"Hostname": "127.0.0.1", "Port": 1232}}' > "$config"
(main update --with-air) && exit 1
grep -q 'no AIR client yet' "$TEST_DIR/terminal"
grep -qx "AIR='yes'" "$STATE_FILE"
AIR='' save_state
printf '\xEF\xBB\xBF{"Database": {"Password": "secret"}, "Flash": {"Hostname": "127.0.0.1", "Port": 1232}, "Encryption": {"RsaPrivateKeyFile": ""}, "AirClient": {"GameHost": ""}}\n' > "$config"
: > "$TEST_DIR/calls"
: > "$TEST_DIR/terminal"
(main update --with-air)
grep -qx "AIR='yes'" "$STATE_FILE"
[ "$(air_value .Database.Password)" = secret ] && [ "$(air_value .Flash.Hostname)" = 0.0.0.0 ]
[ "$(air_value .AirClient.GameHost)" = 192.0.2.10 ] && [ "$(air_value .AirClient.ClientVersion)" = 38-1 ]
key=$(< "$emulator/Config/rsa-private.pem")
grep -q 'systemctl restart plusemu$' "$TEST_DIR/calls"
grep -qxF '    location = /api/client/air.json {' "$site"
[ "$(grep -c "^allow $AIR_PORT/tcp\$" "$FAKE_DIR/rules")" = 1 ]
grep -qx 'AIR_CLIENT_ENABLED="true"' "$HOTEL_ROOT/cms/.env"
grep -q 'air_launcher' "$HEALTH_COMMAND"
grep -q 'HabboCustomLauncher/releases' "$TEST_DIR/terminal"
grep -q 'Open AIR client' "$TEST_DIR/terminal"
grep -q 'PLUSEMU_CLOUDFLARE_TOKEN=<your token> plusemu-update --with-air' "$TEST_DIR/terminal"
# A second run keeps the key, the routes and the rule, and does not restart the emulator.
: > "$TEST_DIR/calls"
(main update --with-air)
[ "$(< "$emulator/Config/rsa-private.pem")" = "$key" ]
if grep -q 'systemctl restart plusemu$' "$TEST_DIR/calls"; then echo 'the emulator restarted without a change'; exit 1; fi
[ "$(grep -c 'location = /api/client/air.json' "$site")" = 1 ]
[ "$(grep -c "^allow $AIR_PORT/tcp\$" "$FAKE_DIR/rules")" = 1 ]
# A check that fails stops with the reason.
health_air_port() { echo "Nothing answers on port 30000."; return 1; }
(main update --with-air) && exit 1
grep -q 'Nothing answers on port 30000' "$TEST_DIR/terminal"

printf 'Bash AIR client checks passed\n' >&4

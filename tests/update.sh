#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced install.sh functions
# Exercise the real update mode against fake releases, without services, packages or network.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

HOTEL_ROOT=$TEST_DIR/hotel
STATE_FILE=$TEST_DIR/etc/hotel.env
VERSIONS_FILE=$TEST_DIR/etc/versions.env
BACKUP_ROOT=$TEST_DIR/backups
UPDATE_COMMAND=$TEST_DIR/bin/plusemu-update
UPDATE_LOG=$TEST_DIR/update.log
LOCK_FILE=$TEST_DIR/update.lock
RELEASES=$TEST_DIR/releases
MIGRATION=ok

preflight() { ARCH=x64; }
load_installer_files() { TEMPLATES=$ROOT/templates; }
chown() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_DIR/calls"; }
runuser() {
    printf 'runuser %s\n' "$*" >> "$TEST_DIR/calls"
    if [ "$MIGRATION" = interrupted ]; then kill -TERM "$BASHPID"; fi
    [ "$MIGRATION" = ok ]
}
mariadb-dump() { printf 'CREATE TABLE users (id INT);\n'; }
sql() { printf 'sql %s\n' "$*" >> "$TEST_DIR/calls"; cat >> "$TEST_DIR/sql-input"; }
curl() {
    local arg url='' out='' prev=''
    for arg in "$@"; do
        if [ "$prev" = -o ]; then out=$arg; fi
        if [[ $arg == http* ]]; then url=$arg; fi
        prev=$arg
    done
    case $url in
        https://github.com/plus-emulator/PlusEMU/releases/latest)
            printf 'https://github.com/plus-emulator/PlusEMU/releases/tag/%s' "$LATEST_EMULATOR" ;;
        https://github.com/plus-emulator/Volt/releases/latest)
            printf 'https://github.com/plus-emulator/Volt/releases/tag/%s' "$LATEST_CLIENT" ;;
        https://github.com/*/releases/download/*)
            local file=$RELEASES/${url#https://github.com/*/releases/download/}
            if [ ! -f "$file" ]; then
                if [[ " $* " == *' -w '* ]]; then printf 404; return 0; fi
                return 22
            fi
            if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
            if [[ " $* " == *' -w '* ]]; then printf 200; fi ;;
        http://127.0.0.1:8080/*)
            if [[ " $* " == *' -w '* ]]; then printf 200; fi ;;
        *) return 7 ;;
    esac
}

make_emulator_release() { # make_emulator_release <tag>
    local dir=$TEST_DIR/build/$1
    mkdir -p "$dir/Config" "$dir/Database" "$RELEASES/$1"
    printf 'emulator %s\n' "$1" > "$dir/Plus Emulator"
    chmod 755 "$dir/Plus Emulator"
    printf '%s' "$1" > "$dir/new-$1.dll"
    printf '\xEF\xBB\xBF{"Database": {"Password": "", "Port": 3306, "Timeout": 30}, "NewSection": {"Enabled": true}}\n' > "$dir/Config/config.json"
    printf 'default nlog\n' > "$dir/Config/nlog.config"
    printf 'default figuredata\n' > "$dir/Config/figuredata.xml"
    printf 'schema %s\n' "$1" > "$dir/Database/FreshInstall.sql"
    tar -C "$dir" -czf "$RELEASES/$1/plusemu-linux-x64.tar.gz" .
    (cd "$RELEASES/$1" && sha256sum plusemu-linux-x64.tar.gz > SHA256SUMS)
}

make_client_release() { # make_client_release <tag>
    local dir=$TEST_DIR/build/$1
    mkdir -p "$dir/assets" "$dir/configuration" "$dir/plugins" "$RELEASES/$1"
    printf 'client %s\n' "$1" > "$dir/index.html"
    printf 'bundle\n' > "$dir/assets/index-$1.js"
    printf '{}\n' > "$dir/configuration/ui-config.example"
    printf '{"pets": []}\n' > "$dir/configuration/pets.json"
    printf 'builder\n' > "$dir/plugins/room-builder.js"
    (cd "$dir" && python3 -m zipfile -c "$RELEASES/$1/volt-client.zip" index.html assets configuration plugins)
}

# Each run gets its own process state; set -e is re-enabled because a negated subshell disables it.
run_update() { (set -e; update_main "$@") < /dev/null; }
fails() {
    set +e
    run_update "$@"
    local status=$?
    set -e
    [ "$status" -ne 0 ]
}
make_hotel_files() { # make_hotel_files <revision>: the stock hotel files pack on the latest installer release
    local dir=$TEST_DIR/build/hotel-files-$1
    mkdir -p "$dir/gamedata" "$dir/assets/furni" "$RELEASES/hotel-files"
    printf 'figuredata %s\n' "$1" > "$dir/gamedata/FigureData.json"
    printf 'furni %s\n' "$1" > "$dir/assets/furni/stock_$1.nitro"
    tar -C "$dir" -czf "$RELEASES/hotel-files/hotel-files.tar.gz" .
    (cd "$RELEASES/hotel-files" && sha256sum hotel-files.tar.gz > SHA256SUMS)
}

snapshots() { find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l; }

# An installation made before update mode existed: no versions file, user edits everywhere.
mkdir -p "$TEST_DIR/etc" "$HOTEL_ROOT/emulator/Config" "$HOTEL_ROOT/emulator/plugins/MyPlugin" \
    "$HOTEL_ROOT/emulator/backups" "$HOTEL_ROOT/client/assets" "$HOTEL_ROOT/client/configuration" \
    "$HOTEL_ROOT/client/plugins"
cat > "$STATE_FILE" <<'EOF'
DOMAIN='example.com'
WS_URL='wss://example.com/ws'
HOTEL_NAME='Example'
ADMIN_USER='admin'
ADMIN_EMAIL='admin@example.com'
ADMIN_PASSWORD='OriginalAlpha123!'
DB_PASSWORD='database-secret'
GUIDE_TOKEN='token'
GUIDE_MODE='simple'
EOF
emulator=$HOTEL_ROOT/emulator client=$HOTEL_ROOT/client
printf 'emulator old\n' > "$emulator/Plus Emulator"
chmod 755 "$emulator/Plus Emulator"
printf 'old\n' > "$emulator/old.dll"
printf '{"Database": {"Password": "database-secret", "Port": 3306}, "Custom": "kept"}\n' > "$emulator/Config/config.json"
printf 'my nlog\n' > "$emulator/Config/nlog.config"
printf 'my custom clothes\n' > "$emulator/Config/figuredata.xml"
printf 'plugin\n' > "$emulator/plugins/MyPlugin/MyPlugin.dll"
printf 'dump\n' > "$emulator/backups/before-migration.sql"
printf 'client old\n' > "$client/index.html"
printf 'old bundle\n' > "$client/assets/index-old.js"
printf '{"socket.url": "wss://custom.example.com/game", "my.setting": 1}\n' > "$client/configuration/renderer-config.json"
printf '{"hotel.name": "Mine"}\n' > "$client/configuration/ui-config.json"
printf '{"apiBaseUrl": "https://example.com"}\n' > "$client/configuration/client-mode.json"
printf '{"text": "mine"}\n' > "$client/configuration/UITexts_en.jsonc"
printf 'ads\n' > "$client/ads.txt"
printf 'mine\n' > "$client/plugins/mine.js"
mkdir -p "$HOTEL_ROOT/hotel-files/gamedata"
printf 'figuredata 0\n' > "$HOTEL_ROOT/hotel-files/gamedata/FigureData.json"
touch "$HOTEL_ROOT/hotel-files/.complete"
cp -a "$HOTEL_ROOT" "$TEST_DIR/original"

make_emulator_release v2.0.0
make_client_release client-v2.0.0
make_hotel_files 1
LATEST_EMULATOR=v2.0.0 LATEST_CLIENT=client-v2.0.0

# --check reports available updates and changes nothing.
run_update --check
grep -Fq v2.0.0 "$TEST_DIR/terminal"
grep -Fq client-v2.0.0 "$TEST_DIR/terminal"
diff -r "$TEST_DIR/original" "$HOTEL_ROOT"
[[ $(snapshots) == 0 && ! -e "$TEST_DIR/calls" ]]

# A download that fails its checksum stops before the hotel is touched.
good_sums=$(< "$RELEASES/v2.0.0/SHA256SUMS")
printf '%064d  plusemu-linux-x64.tar.gz\n' 0 > "$RELEASES/v2.0.0/SHA256SUMS"
fails --yes
diff -r "$TEST_DIR/original" "$HOTEL_ROOT"
[[ $(snapshots) == 0 ]]
if grep -q 'systemctl stop' "$TEST_DIR/calls" 2> /dev/null; then exit 1; fi
printf '%s\n' "$good_sums" > "$RELEASES/v2.0.0/SHA256SUMS"

# A failed migration restores the previous emulator, client and database.
: > "$TEST_DIR/terminal"
MIGRATION=fail
fails --yes
diff -r "$TEST_DIR/original" "$HOTEL_ROOT"
[[ $(snapshots) == 1 ]]
grep -q 'DROP DATABASE' "$TEST_DIR/calls"
grep -Fq 'CREATE TABLE users' "$TEST_DIR/sql-input"
[[ $(grep systemctl "$TEST_DIR/calls" | tail -1) == *'start plusemu'* ]]
[[ ! -e $VERSIONS_FILE ]]
grep -qi restored "$TEST_DIR/terminal"

# An update stopped by a signal (for example a closed SSH session or a reboot) also restores.
: > "$TEST_DIR/calls"
MIGRATION=interrupted
fails --yes
diff -r "$TEST_DIR/original" "$HOTEL_ROOT"
[[ $(snapshots) == 2 ]]
grep -q 'DROP DATABASE' "$TEST_DIR/calls"
[[ $(grep systemctl "$TEST_DIR/calls" | tail -1) == *'start plusemu'* ]]

# A successful update installs both releases and keeps every user file and setting.
MIGRATION=ok
: > "$TEST_DIR/calls"
: > "$TEST_DIR/sql-input"
run_update --yes
[[ $(< "$emulator/Plus Emulator") == 'emulator v2.0.0' && -x "$emulator/Plus Emulator" ]]
[[ -f "$emulator/new-v2.0.0.dll" && ! -e "$emulator/old.dll" ]]
[[ $(< "$emulator/Database/FreshInstall.sql") == 'schema v2.0.0' ]]
config=$emulator/Config/config.json
[[ $(jq -r .Database.Password "$config") == database-secret ]]
[[ $(jq -r .Database.Timeout "$config") == 30 ]]
[[ $(jq -r .NewSection.Enabled "$config") == true ]]
[[ $(jq -r .Custom "$config") == kept ]]
[[ $(stat -c %a "$config") == 600 ]]
[[ $(< "$emulator/Config/nlog.config") == 'my nlog' ]]
# The stock pack came with this update, so the emulator's clothing data is the release's one that matches it.
[[ $(< "$emulator/Config/figuredata.xml") == 'default figuredata' ]]
[[ -f "$emulator/plugins/MyPlugin/MyPlugin.dll" && -f "$emulator/backups/before-migration.sql" ]]
grep -q 'runuser .*--migrate' "$TEST_DIR/calls"
[[ $(< "$client/index.html") == 'client client-v2.0.0' ]]
[[ -f "$client/assets/index-client-v2.0.0.js" && ! -e "$client/assets/index-old.js" ]]
[[ -f "$client/ads.txt" && -f "$client/plugins/mine.js" && -f "$client/plugins/room-builder.js" ]]
[[ -f "$client/configuration/pets.json" && -f "$client/configuration/UITexts_en.jsonc" ]]
renderer=$client/configuration/renderer-config.json
[[ $(jq -r '."socket.url"' "$renderer") == wss://custom.example.com/game ]]
[[ $(jq -r '."my.setting"' "$renderer") == 1 ]]
[[ $(jq -r '."asset.url"' "$renderer") == https://example.com/hotel-files/assets ]]
[[ $(jq -r '."hotel.name"' "$client/configuration/ui-config.json") == Mine ]]
grep -qx "EMULATOR_VERSION='v2.0.0'" "$VERSIONS_FILE"
grep -qx "CLIENT_VERSION='client-v2.0.0'" "$VERSIONS_FILE"
grep -qx "ASSETS_VERSION='$(cut -c1-12 "$RELEASES/hotel-files/SHA256SUMS")'" "$VERSIONS_FILE"
[[ $(< "$HOTEL_ROOT/hotel-files/gamedata/FigureData.json") == 'figuredata 1' && ! -e "$HOTEL_ROOT/hotel-files/.complete" ]]
[[ $(snapshots) == 3 ]]
latest=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
gunzip -c "$latest/database.sql.gz" | grep -Fq 'CREATE TABLE users'
[[ -x $UPDATE_COMMAND ]]
grep -Fq 'update "$@"' "$UPDATE_COMMAND"
cp -a "$HOTEL_ROOT" "$TEST_DIR/updated"

# Nothing to do when both components are current.
: > "$TEST_DIR/calls"
run_update --yes
[[ $(snapshots) == 3 ]]
if grep -q 'systemctl stop' "$TEST_DIR/calls"; then exit 1; fi
grep -qi 'up to date' "$TEST_DIR/terminal"

# --rollback returns to the state before the last update, database included.
: > "$TEST_DIR/sql-input"
run_update --yes --rollback
diff -r "$TEST_DIR/original" "$HOTEL_ROOT"
grep -Fq 'CREATE TABLE users' "$TEST_DIR/sql-input"
[[ ! -e $VERSIONS_FILE && $(snapshots) == 3 ]]
# The rollback saved the state it replaced, so a second rollback undoes it.
run_update --yes --rollback
diff -r "$TEST_DIR/updated" "$HOTEL_ROOT"
grep -qx "EMULATOR_VERSION='v2.0.0'" "$VERSIONS_FILE"

# Only the newest three backups are kept.
for tag in v2.1.0 v2.2.0; do
    make_emulator_release "$tag"
    LATEST_EMULATOR=$tag
    run_update --yes
done
[[ $(snapshots) == 3 && $(< "$emulator/Plus Emulator") == 'emulator v2.2.0' ]]
[[ $(< "$client/index.html") == 'client client-v2.0.0' ]]

# The stock hotel files are part of every update: a newer pack is installed without any option.
[[ $ASSET_PACK_URL == https://github.com/plus-emulator/plusemu-installer/releases/download/hotel-files/hotel-files.tar.gz ]]
hotel_files=$HOTEL_ROOT/hotel-files
mkdir -p "$hotel_files/gamedata" "$hotel_files/assets/custom"
printf 'figuredata 1\n' > "$hotel_files/gamedata/FigureData.json"
printf 'my furni\n' > "$hotel_files/assets/custom/my_furni.nitro"
make_hotel_files 2
pack_version=$(cut -c1-12 "$RELEASES/hotel-files/SHA256SUMS")
cp -a "$HOTEL_ROOT" "$TEST_DIR/before-assets"

# --check names the new pack and changes nothing, even though the emulator and client are current.
: > "$TEST_DIR/terminal"
run_update --check
grep -Fq "$pack_version" "$TEST_DIR/terminal"
if grep -qi 'everything is up to date' "$TEST_DIR/terminal"; then exit 1; fi
diff -r "$TEST_DIR/before-assets" "$HOTEL_ROOT"

# A damaged pack changes nothing.
good_sums=$(< "$RELEASES/hotel-files/SHA256SUMS")
printf '%064d  hotel-files.tar.gz\n' 0 > "$RELEASES/hotel-files/SHA256SUMS"
fails --yes
diff -r "$TEST_DIR/before-assets" "$HOTEL_ROOT"
printf '%s\n' "$good_sums" > "$RELEASES/hotel-files/SHA256SUMS"

# A failed update restores the hotel files too.
MIGRATION=fail
fails --yes
diff -r "$TEST_DIR/before-assets" "$HOTEL_ROOT"
MIGRATION=ok

# The update installs the stock pack over the hotel files and the emulator's matching clothing data.
: > "$TEST_DIR/terminal"
run_update --yes
[[ $(< "$hotel_files/gamedata/FigureData.json") == 'figuredata 2' ]]
[[ -f "$hotel_files/assets/furni/stock_2.nitro" && -f "$hotel_files/assets/custom/my_furni.nitro" ]]
[[ ! -e "$hotel_files/.complete" ]]
[[ $(< "$emulator/Config/figuredata.xml") == 'default figuredata' ]]
[[ $(< "$emulator/Config/nlog.config") == 'my nlog' ]]
[[ $(jq -r .Custom "$emulator/Config/config.json") == kept ]]
[[ $(< "$emulator/Plus Emulator") == 'emulator v2.2.0' ]]
grep -qx "ASSETS_VERSION='$pack_version'" "$VERSIONS_FILE"
grep -qx "EMULATOR_VERSION='v2.2.0'" "$VERSIONS_FILE"
grep -Fq "$pack_version" "$TEST_DIR/terminal"
latest=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
[[ -f "$latest/hotel-files.tar" ]]

# Everything current, hotel files included: nothing happens. --with-assets is still accepted.
: > "$TEST_DIR/calls"
: > "$TEST_DIR/terminal"
run_update --yes
grep -qi 'everything is up to date' "$TEST_DIR/terminal"
if grep -q 'systemctl stop' "$TEST_DIR/calls"; then exit 1; fi
if grep -Fq -- '--with-assets' "$TEST_DIR/terminal"; then exit 1; fi
run_update --yes --with-assets
if grep -q 'systemctl stop' "$TEST_DIR/calls"; then exit 1; fi

# --rollback also returns the hotel files.
run_update --yes --rollback
diff -r "$TEST_DIR/before-assets" "$HOTEL_ROOT"

# A re-run of the installer refreshes the hotel files when the published pack changed, and keeps added files.
EMULATOR_VERSION=v2.2.0 CLIENT_VERSION=client-v2.0.0 ASSETS_VERSION=unknown
mkdir -p "$hotel_files" && touch "$hotel_files/.complete"
STEP=0 TOTAL_STEPS=9
download_hotel_files
[[ $(< "$hotel_files/gamedata/FigureData.json") == 'figuredata 2' ]]
[[ -f "$hotel_files/assets/custom/my_furni.nitro" && ! -e "$hotel_files/.complete" ]]
grep -qx "ASSETS_VERSION='$pack_version'" "$VERSIONS_FILE"
make_hotel_files 3
printf 'edited\n' > "$hotel_files/gamedata/FigureData.json"
: > "$TEST_DIR/terminal"
download_hotel_files
[[ $(< "$hotel_files/gamedata/FigureData.json") == 'figuredata 3' ]]
[[ -f "$hotel_files/assets/furni/stock_2.nitro" && -f "$hotel_files/assets/furni/stock_3.nitro" ]]
grep -qx "ASSETS_VERSION='$(cut -c1-12 "$RELEASES/hotel-files/SHA256SUMS")'" "$VERSIONS_FILE"
printf 'edited again\n' > "$hotel_files/gamedata/FigureData.json"
: > "$TEST_DIR/terminal"
download_hotel_files
[[ $(< "$hotel_files/gamedata/FigureData.json") == 'edited again' ]]
grep -qi 'already' "$TEST_DIR/terminal"

printf 'Bash update checks passed\n' >&4

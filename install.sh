#!/usr/bin/env bash
# PlusEMU hotel installer for Debian 12/13 and Ubuntu 22.04/24.04/26.04.
#
#   curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh | sudo bash
#
# Installs and wires together: PlusEMU (emulator) and Volt (client) from their
# latest GitHub releases, Atom CMS (website), MariaDB, PHP, nginx and the hotel
# files. Everything is self-hosted on this server; Cloudflare sits in front.
# Safe to run again: settings are reused and finished steps are kept.
#
# Unattended runs can preset the answers: PLUSEMU_DOMAIN, PLUSEMU_WS_URL,
# PLUSEMU_HOTEL_NAME, PLUSEMU_ADMIN_USER, PLUSEMU_ADMIN_EMAIL, PLUSEMU_YES=1.
# PLUSEMU_GUIDE_MODE=simple|advanced selects the final instructions only.
set -Eeuo pipefail
shopt -u patsub_replacement 2> /dev/null || true # bash 5.2 would expand "&" in template values

INSTALLER_REPO=${INSTALLER_REPO:-plus-emulator/plusemu-installer}
INSTALLER_REF=${INSTALLER_REF:-main}
ASSET_PACK_URL=${ASSET_PACK_URL:-https://github.com/plus-emulator/plusemu-installer/releases/latest/download/hotel-files.tar.gz}
EMULATOR_REPO=plus-emulator/PlusEMU
CLIENT_REPO=plus-emulator/Volt
# Set to install a build from another place instead of the latest release (recorded as version "custom").
EMULATOR_URL=${EMULATOR_URL:-}
CLIENT_URL=${CLIENT_URL:-}
ATOM_REPO=${ATOM_REPO:-https://github.com/atom-projects/atom-cms.git}
# "auto" picks the Atom CMS that matches the downloaded emulator's database (see download_releases).
ATOM_REF=${ATOM_REF:-auto}

HOTEL_ROOT=/var/www/hotel
STATE_FILE=/etc/plusemu/hotel.env
VERSIONS_FILE=/etc/plusemu/versions.env
LOG=/var/log/plusemu-install.log
UPDATE_LOG=/var/log/plusemu-update.log
UPDATE_COMMAND=/usr/local/sbin/plusemu-update
BACKUP_ROOT=/var/backups/plusemu
KEEP_BACKUPS=3
LOCK_FILE=/run/plusemu-update.lock
MODE=install
PHP=8.5
NODE_MAJOR=22
TOTAL_STEPS=9
STEP=0

# ---------------------------------------------------------------- output

exec 3>&1
bold=$'\e[1m' green=$'\e[32m' red=$'\e[31m' yellow=$'\e[33m' cyan=$'\e[36m' reset=$'\e[0m'

say() { printf '%s\n' "$*" >&3 2> /dev/null || true; printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g'; }
step() { STEP=$((STEP + 1)); say ""; say "${bold}${cyan}[$STEP/$TOTAL_STEPS]${reset} ${bold}$*${reset}"; }
ok() { say "      ${green}✓${reset} $*"; }
die() { say ""; say "${red}${bold}✗ $*${reset}"; exit 1; }

on_error() {
    local code=$? line=$1 last
    # A failing ( subshell ) also runs this trap; only the main shell reports.
    [ "$BASHPID" = "$$" ] || exit "$code"
    last=$(tail -n 15 "$LOG")
    say ""
    say "${red}${bold}✗ Something went wrong (line $line, exit code $code).${reset}"
    say "  The last lines of the log:"
    printf '%s\n' "$last" | sed 's/^/    /' >&3 2> /dev/null || true
    say ""
    say "  Full log: ${bold}$LOG${reset}"
    if [ -f "$STATE_FILE" ]; then
        say "  Saved passwords: sudo cat $STATE_FILE (keep this file private)."
    fi
    if [ "$MODE" = update ]; then
        say "  The update stopped. Ask for help on DevBest with the log if you need it."
    else
        say "  Fix the problem (or ask for help on DevBest with the log), then run the installer again."
        say "  It continues where it stopped."
    fi
    exit "$code"
}

ask() { # ask <variable> <question> [default]
    local var=$1 question=$2 default=${3:-} answer
    if [ -n "$default" ]; then question="$question ${bold}[$default]${reset}"; fi
    printf '  %s: ' "$question" >&3
    if ! read -r answer < /dev/tty 2> /dev/null; then
        # No terminal (an unattended run): only questions with a default can be answered.
        [ -n "$default" ] || die "No answer for \"$2\". Run the installer in a terminal, or preset the PLUSEMU_* answers."
    fi
    printf -v "$var" '%s' "${answer:-$default}"
}

# ---------------------------------------------------------------- helpers

random_secret() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}" || true; }

# Keep database passwords and URL tokens alphanumeric. Atom requires at least
# 12 characters, mixed case, a number and a symbol; retain 16 random characters.
admin_password() {
    local secret
    secret=$(random_secret 16)
    [ "${#secret}" -eq 16 ] || return 1
    printf '%sAa1!' "$secret"
}

repair_admin_password() {
    # Only called while CMS setup is incomplete; never rotate an installed login.
    if [[ ${#ADMIN_PASSWORD} -lt 12 || $ADMIN_PASSWORD != *[A-Z]* ||
        $ADMIN_PASSWORD != *[a-z]* || $ADMIN_PASSWORD != *[0-9]* ||
        $ADMIN_PASSWORD != *[^a-zA-Z0-9[:space:]]* ]]; then
        ADMIN_PASSWORD=$(admin_password)
        save_state
        say "  Replaced the saved admin password to meet Atom's requirements. Saved in $STATE_FILE."
    fi
}

render() { # render <template> <output> [certificate fragment]: replace {{KEY}} with shell variable KEY
    local content key certificate_steps=""
    content=$(< "$1")
    if [ -n "${3-}" ]; then certificate_steps=$(< "$3"); fi
    content=${content//"{{CERTIFICATE_STEPS}}"/"$certificate_steps"}
    for key in DOMAIN SOCKET_URL FURNIDATA_URL SERVER_IP WS_HOST HOTEL_NAME ADMIN_USER ADMIN_EMAIL \
        CREDENTIALS_FILE RESTART_COMMAND LOG_COMMAND WS_DNS_ROW GUIDE_MODE_TITLE GUIDE_MODE_DETAILS; do
        content=${content//"{{$key}}"/${!key-}}
    done
    printf '%s\n' "$content" > "$2"
}

set_env() { # set_env <file> <KEY> <value>: replace or append KEY=value in a .env file
    local file=$1 key=$2 value=$3
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    if grep -q "^$key=" "$file"; then
        sed -i "s|^$key=.*|$key=\"${value//|/\\|}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$file"
    fi
}

clone() { # clone <repo> <branch or commit> <dir>: shallow checkout of exactly that ref
    if [ ! -d "$3/.git" ]; then
        rm -rf "$3"
        git init -q "$3"
        git -C "$3" remote add origin "$1"
    fi
    git -C "$3" fetch --depth 1 origin "$2"
    git -C "$3" reset -q --hard FETCH_HEAD
}

sql() { mariadb --protocol=socket -uroot "$@"; }

save_state() {
    install -d -m 700 "$(dirname "$STATE_FILE")"
    umask 077
    cat > "$STATE_FILE" <<EOF
DOMAIN='$DOMAIN'
WS_URL='$WS_URL'
HOTEL_NAME='${HOTEL_NAME//\'/}'
ADMIN_USER='$ADMIN_USER'
ADMIN_EMAIL='$ADMIN_EMAIL'
ADMIN_PASSWORD='$ADMIN_PASSWORD'
DB_PASSWORD='$DB_PASSWORD'
GUIDE_TOKEN='$GUIDE_TOKEN'
GUIDE_MODE='${GUIDE_MODE:-simple}'
EOF
    chmod 600 "$STATE_FILE"
    umask 022
}

save_versions() {
    install -d -m 700 "$(dirname "$VERSIONS_FILE")"
    printf "EMULATOR_VERSION='%s'\nCLIENT_VERSION='%s'\n" "$EMULATOR_VERSION" "$CLIENT_VERSION" > "$VERSIONS_FILE"
}

require_free_space() { # require_free_space <GB> [path]
    local free_gb
    free_gb=$(df -BG --output=avail "${2:-/}" | tail -1 | tr -dc 0-9)
    [ "$free_gb" -ge "$1" ] || die "Not enough disk space: ${free_gb} GB free, at least $1 GB needed."
}

release_version() { # release_version <owner/repo> <custom URL>: the tag of the newest release
    if [ -n "$2" ]; then
        printf custom
        return
    fi
    local url
    url=$(curl -fsSI --retry 3 -o /dev/null -w '%{redirect_url}' "https://github.com/$1/releases/latest") || return 1
    [[ $url == */releases/tag/* ]] || return 1
    printf '%s' "${url##*/releases/tag/}"
}

fetch_release() { # fetch_release <owner/repo> <tag> <asset> <file>: checked against SHA256SUMS when the release has one
    local base=https://github.com/$1/releases/download/$2 sums=$4.sums status expected
    curl -fsSL --retry 3 "$base/$3" -o "$4" || return 1
    status=$(curl -sSL --retry 3 -o "$sums" -w '%{http_code}' "$base/SHA256SUMS") || status=000
    case $status in
        200) expected=$(awk -v file="$3" '$2 == file || $2 == "*" file {print $1}' "$sums") ;;
        404) rm -f "$sums"; return 0 ;; # older releases publish no checksums
        *) rm -f "$sums"; die "Could not download the checksums of $2. Nothing was changed. Try again later." ;;
    esac
    rm -f "$sums"
    if [ -z "$expected" ] || [ "$(sha256sum "$4" | cut -d' ' -f1)" != "$expected" ]; then
        die "The download of $3 ($2) does not match its published checksum. Nothing was changed. Try again later."
    fi
}

stage_emulator() { # stage_emulator <version> <dir>: unpack the emulator release into a new dir
    local file
    mkdir -p "$2"
    file=$(mktemp -p "$(dirname "$2")")
    if [ -n "$EMULATOR_URL" ]; then
        curl -fsSL --retry 3 "${EMULATOR_URL//ARCH/$ARCH}" -o "$file"
    else
        fetch_release "$EMULATOR_REPO" "$1" "plusemu-linux-$ARCH.tar.gz" "$file" || die "Could not download PlusEMU $1. Nothing was changed. Try again later."
    fi
    tar xzf "$file" --no-same-owner -C "$2"
    rm -f "$file"
    [ -x "$2/Plus Emulator" ] || die "The PlusEMU $1 download is incomplete. Nothing was changed. Try again later."
}

stage_client() { # stage_client <version> <dir>: unpack the client release into a new dir
    local file
    mkdir -p "$2"
    file=$(mktemp -p "$(dirname "$2")")
    if [ -n "$CLIENT_URL" ]; then
        curl -fsSL --retry 3 "$CLIENT_URL" -o "$file"
    else
        # Client releases made before the Volt rename ship the same build as octane-client.zip.
        fetch_release "$CLIENT_REPO" "$1" volt-client.zip "$file" 2> /dev/null ||
            fetch_release "$CLIENT_REPO" "$1" octane-client.zip "$file" || die "Could not download Volt $1. Nothing was changed. Try again later."
    fi
    unzip -q "$file" -d "$2"
    rm -f "$file"
    [ -f "$2/index.html" ] || die "The Volt $1 download is incomplete. Nothing was changed. Try again later."
}

wait_for_emulator() {
    # Any HTTP answer from the emulator's web server means it has started; releases differ in their routes.
    for _ in $(seq 1 60); do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/gamedata/furnidata/version)" != 000 ]; then
            return 0
        fi
        sleep 2
    done
    journalctl -u plusemu -n 40 --no-pager
    return 1
}

install_update_command() {
    mkdir -p "$(dirname "$UPDATE_COMMAND")"
    cat > "$UPDATE_COMMAND" <<EOF
#!/usr/bin/env bash
# Installed by the PlusEMU installer. Updates the emulator and the Volt client with the newest installer:
#   sudo plusemu-update [--check] [--yes] [--rollback]
set -euo pipefail
script=\$(mktemp)
trap 'rm -f "\$script"' EXIT
curl -fsSL "https://raw.githubusercontent.com/$INSTALLER_REPO/$INSTALLER_REF/install.sh" -o "\$script"
bash "\$script" update "\$@"
EOF
    chmod 755 "$UPDATE_COMMAND"
}

# ---------------------------------------------------------------- steps

preflight() { # preflight [free GB needed]
    [ "$(id -u)" -eq 0 ] || die "Please run this as root, with sudo."
    [ -r /etc/os-release ] || die "This installer supports Debian 12/13 and Ubuntu 22.04/24.04/26.04 only."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=$ID OS_VERSION=${VERSION_ID:-} OS_CODENAME=${VERSION_CODENAME:-}
    case "$OS_ID:$OS_VERSION" in
        debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04 | ubuntu:26.04) ;;
        *) die "Unsupported system: ${PRETTY_NAME:-unknown}. Use Debian 12/13 or Ubuntu 22.04/24.04/26.04." ;;
    esac
    case "$(uname -m)" in
        x86_64) ARCH=x64 ;;
        aarch64) ARCH=arm64 ;;
        *) die "Unsupported processor: $(uname -m). A 64-bit (x86_64 or arm64) server is required." ;;
    esac
    require_free_space "${1:-10}"
}

load_installer_files() {
    # Templates ship next to this script. When run through `curl | bash` there
    # is no script directory, so the matching installer release is downloaded.
    [ -z "${TEMPLATES:-}" ] || return 0
    local here
    here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
    if [ -n "$here" ] && [ -f "$here/templates/setup-guide.html" ]; then
        TEMPLATES=$here/templates
        return
    fi
    INSTALLER_TMP=$(mktemp -d)
    curl -fsSL "https://codeload.github.com/$INSTALLER_REPO/tar.gz/$INSTALLER_REF" | tar xz -C "$INSTALLER_TMP" --strip-components 1
    TEMPLATES=$INSTALLER_TMP/templates
}

select_guide_mode() {
    GUIDE_MODE=${GUIDE_MODE_OPTION:-${PLUSEMU_GUIDE_MODE:-${1:-simple}}}
    case "$GUIDE_MODE" in
        simple | advanced) ;;
        *) die "Guide mode must be simple or advanced (this selects instructions only)." ;;
    esac
}

ask_questions() {
    select_guide_mode
    say ""
    say "${bold}Welcome to the PlusEMU hotel installer!${reset}"
    say "This sets up your emulator, client and website on this server in about 10 minutes."
    say ""

    if [ -f "$STATE_FILE" ]; then
        GUIDE_MODE=simple
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        select_guide_mode "$GUIDE_MODE"
        if [ -z "${GUIDE_TOKEN:-}" ]; then GUIDE_TOKEN=$(random_secret 12); fi
        save_state
        say "Found the settings of an earlier run for ${bold}$DOMAIN${reset}; continuing that installation."
        say "  Setup guide: $GUIDE_MODE. Selecting this guide does not change SSH, RDP, firewall, updates or backups."
        return
    fi

    DOMAIN=${PLUSEMU_DOMAIN:-}
    while true; do
        [ -n "$DOMAIN" ] || ask DOMAIN "Your hotel's domain name (for example myhotel.com)"
        DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | sed -E 's#^[a-z]+://##; s#/.*$##; s#^www\.##')
        if [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then break; fi
        say "  ${yellow}That doesn't look like a domain name. Type it like: myhotel.com${reset}"
        DOMAIN=
    done

    say ""
    say "  The game connects through a WebSocket. Press Enter to use the recommended"
    say "  address on your own domain (no extra Cloudflare setup), or type your own,"
    say "  for example ws.$DOMAIN."
    WS_URL=${PLUSEMU_WS_URL:-}
    while true; do
        [ -n "$WS_URL" ] || ask WS_URL "WebSocket address" "wss://$DOMAIN/ws"
        WS_URL="wss://$(printf '%s' "$WS_URL" | sed -E 's#^[a-zA-Z]+://##')"
        if [[ $WS_URL =~ ^wss://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/[A-Za-z0-9._/-]*)?$ ]]; then break; fi
        say "  ${yellow}Type it like wss://$DOMAIN/ws or ws.$DOMAIN (no port).${reset}"
        WS_URL=
    done

    local suggested=${DOMAIN%%.*}
    HOTEL_NAME=${PLUSEMU_HOTEL_NAME:-}
    [ -n "$HOTEL_NAME" ] || ask HOTEL_NAME "Hotel name" "${suggested^}"
    HOTEL_NAME=$(printf '%s' "$HOTEL_NAME" | tr -d '<>"`$\\'"'")
    ADMIN_USER=${PLUSEMU_ADMIN_USER:-}
    while true; do
        [ -n "$ADMIN_USER" ] || ask ADMIN_USER "Username for your admin account" "admin"
        if [[ $ADMIN_USER =~ ^[A-Za-z0-9._-]{3,25}$ ]]; then break; fi
        say "  ${yellow}Use 3-25 letters, numbers, dots, dashes or underscores.${reset}"
        ADMIN_USER=
    done
    ADMIN_EMAIL=${PLUSEMU_ADMIN_EMAIL:-}
    while true; do
        [ -n "$ADMIN_EMAIL" ] || ask ADMIN_EMAIL "Email for your admin account" "admin@$DOMAIN"
        if [[ $ADMIN_EMAIL =~ ^[^@[:space:]\']+@[^@[:space:]\']+\.[^@[:space:]\']+$ ]]; then break; fi
        say "  ${yellow}That doesn't look like an email address.${reset}"
        ADMIN_EMAIL=
    done
    ADMIN_PASSWORD=$(admin_password)
    DB_PASSWORD=$(random_secret 32)
    GUIDE_TOKEN=$(random_secret 12)

    say ""
    say "  Website:    ${bold}https://$DOMAIN${reset}"
    say "  WebSocket:  ${bold}$WS_URL${reset}"
    say "  Hotel name: ${bold}$HOTEL_NAME${reset}"
    say "  Admin:      ${bold}$ADMIN_USER${reset} ($ADMIN_EMAIL)"
    say "  Setup guide: $GUIDE_MODE. Selecting this guide does not change SSH, RDP, firewall, updates or backups."
    if [ "${PLUSEMU_YES:-0}" != 1 ]; then
        local go
        ask go "Start the installation? (y/n)" "y"
        [[ $go =~ ^[Yy] ]] || die "Installation cancelled. Nothing was changed."
    fi
    save_state
}

# shellcheck disable=SC2034 # the {{KEY}} values are read by render() through ${!key}
derive_settings() {
    local rest=${WS_URL#wss://}
    WS_HOST=${rest%%/*}
    WS_PATH=/${rest#*/}
    [ "$rest" != "$WS_HOST" ] || WS_PATH=/
    SOCKET_URL=$WS_URL
    SERVER_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org || curl -4 -fsS --max-time 5 https://ipv4.icanhazip.com || hostname -I | awk '{print $1}')
    SERVER_IP=$(printf '%s' "$SERVER_IP" | tr -d '[:space:]')
}

install_packages() {
    step "Installing system packages (nginx, MariaDB, PHP $PHP)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git unzip jq gnupg openssl cron ufw nginx mariadb-server mariadb-client libicu-dev xz-utils
    if ! apt-cache show "php$PHP-fpm" > /dev/null 2>&1; then
        # PHP 8.5 isn't in these releases yet: use the well-known Sury/Ondřej packages.
        if [ "$OS_ID" = ubuntu ]; then
            apt-get install -y software-properties-common
            add-apt-repository -y ppa:ondrej/php
        else
            curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg
            echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $OS_CODENAME main" > /etc/apt/sources.list.d/sury-php.list
        fi
        apt-get update
    fi
    apt-get install -y "php$PHP-fpm" "php$PHP-cli" "php$PHP-mysql" "php$PHP-mbstring" "php$PHP-xml" \
        "php$PHP-curl" "php$PHP-gd" "php$PHP-intl" "php$PHP-zip" "php$PHP-bcmath"
    ok "nginx, MariaDB $(mariadb --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1), PHP $(php -r 'echo PHP_VERSION;')"

    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
    if [ "$mem_mb" -lt 2500 ] && ! swapon --show | grep -q .; then
        # Building the website's theme needs more memory than small servers have.
        fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Added 4 GB of swap (this server has ${mem_mb} MB of memory)"
    fi
}

install_toolchains() {
    step "Installing Node.js $NODE_MAJOR and Composer (for the website)"
    if ! node --version 2>/dev/null | grep -q "^v$NODE_MAJOR\."; then
        local base=https://nodejs.org/dist/latest-v$NODE_MAJOR.x file
        file=$(curl -fsSL "$base/SHASUMS256.txt" | awk "/node-v.*-linux-$ARCH.tar.xz\$/ {print \$2}")
        curl -fsSL "$base/$file" -o "/tmp/$file"
        curl -fsSL "$base/SHASUMS256.txt" | grep " $file\$" | (cd /tmp && sha256sum -c -)
        rm -rf /opt/node && mkdir -p /opt/node
        tar xJf "/tmp/$file" -C /opt/node --strip-components 1
        rm -f "/tmp/$file"
        ln -sf /opt/node/bin/node /opt/node/bin/npm /opt/node/bin/npx /opt/node/bin/corepack /usr/local/bin/
    fi
    ok "Node.js $(node --version)"

    if ! command -v composer > /dev/null; then
        local expected
        expected=$(curl -fsSL https://composer.github.io/installer.sig)
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        [ "$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")" = "$expected" ] || die "The Composer download failed its checksum. Run the installer again."
        php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
    fi
    ok "Composer $(COMPOSER_ALLOW_SUPERUSER=1 composer --version 2>/dev/null | awk '{print $3}')"
}

download_releases() {
    step "Downloading PlusEMU, the Volt client and Atom CMS"
    # A re-run repairs and keeps the installed releases; `install.sh update` updates them.
    local out=$HOTEL_ROOT/emulator client=$HOTEL_ROOT/client
    EMULATOR_VERSION=unknown CLIENT_VERSION=unknown
    # shellcheck disable=SC1090
    if [ -f "$VERSIONS_FILE" ]; then . "$VERSIONS_FILE"; fi
    if [ -x "$out/Plus Emulator" ]; then
        ok "PlusEMU (already installed)"
    else
        EMULATOR_VERSION=$(release_version "$EMULATOR_REPO" "$EMULATOR_URL") || die "Could not find the latest PlusEMU release. Check the server's internet connection."
        rm -rf "$out"
        stage_emulator "$EMULATOR_VERSION" "$out"
        save_versions
        ok "PlusEMU $EMULATOR_VERSION"
    fi

    if [ -f "$client/index.html" ]; then
        ok "Volt client (already installed)"
    else
        CLIENT_VERSION=$(release_version "$CLIENT_REPO" "$CLIENT_URL") || die "Could not find the latest Volt release. Check the server's internet connection."
        rm -rf "$client.new"
        stage_client "$CLIENT_VERSION" "$client.new"
        rm -rf "$client"
        mv "$client.new" "$client"
        save_versions
        ok "Volt client $CLIENT_VERSION"
    fi

    local atom=$ATOM_REF
    if [ "$atom" = auto ]; then
        # Atom's dev branch reads user_currencies (PlusEMU migration 59); older emulator
        # releases need the last Atom commit before that.
        atom=e9918ed69d4f255511623d69a47e9b2f8e200a28
        if grep -q 'CREATE TABLE `user_currencies`' "$out/Database/FreshInstall.sql"; then atom=dev; fi
    fi
    clone "$ATOM_REPO" "$atom" "$HOTEL_ROOT/cms"
    ok "Atom CMS (${atom:0:12})"
}

# shellcheck disable=SC2034 # the {{KEY}} values are read by render() through ${!key}
write_client_config() { # write_client_config [dir]
    # Newer emulators build FurnitureData.json from the furniture table; older ones need the static file.
    FURNIDATA_URL='${gamedata.url}/FurnitureData.json?t=%timestamp%'
    if curl -fsS -o /dev/null http://127.0.0.1:8080/api/gamedata/furnidata; then
        FURNIDATA_URL="https://$DOMAIN/api/gamedata/furnidata"
    fi
    local config=${1:-$HOTEL_ROOT/client/configuration} file
    for file in renderer-config.json ui-config.json client-mode.json; do
        render "$TEMPLATES/$file" "$config/$file"
    done
}

setup_database() {
    step "Creating the hotel database"
    systemctl enable --now mariadb
    sql <<EOF
CREATE DATABASE IF NOT EXISTS plus CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'hotel'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER 'hotel'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON plus.* TO 'hotel'@'localhost';
FLUSH PRIVILEGES;
EOF
    # The import ends by filling server_status, so a missing or empty one means it never finished.
    local imported=0
    if [ "$(sql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'plus' AND table_name = 'server_status'")" = 1 ]; then
        imported=$(sql -N plus -e 'SELECT COUNT(*) FROM server_status')
    fi
    if [ "$imported" = 0 ]; then
        sql -e "DROP DATABASE plus; CREATE DATABASE plus CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        sql plus < "$HOTEL_ROOT/emulator/Database/FreshInstall.sql"
        ok "Imported the PlusEMU database ($(sql -N plus -e 'SELECT COUNT(*) FROM furniture') furniture types)"
    else
        ok "The database already exists; kept it as it is"
    fi
}

download_hotel_files() {
    step "Downloading the hotel files (furniture, clothes, badges, texts; about 470 MB)"
    local files=$HOTEL_ROOT/hotel-files
    if [ -f "$files/.complete" ]; then
        ok "Already downloaded"
        return
    fi
    rm -rf "$files" && mkdir -p "$files"
    local progress=-sS
    if [ -t 3 ]; then progress=--progress-bar; fi
    curl -fL --retry 3 "$progress" "$ASSET_PACK_URL" 2>&3 | tar xz --no-same-owner -C "$files"
    touch "$files/.complete"
    ok "Hotel files ready ($(du -sh "$files" | cut -f1))"
}

start_emulator() {
    step "Starting the emulator"
    id plusemu > /dev/null 2>&1 || useradd --system --home-dir "$HOTEL_ROOT/emulator" --shell /usr/sbin/nologin plusemu
    local out=$HOTEL_ROOT/emulator config=$HOTEL_ROOT/emulator/Config/config.json
    sed -i '1s/^\xEF\xBB\xBF//' "$config"
    # Every packet is logged at Trace level by default, which floods the journal.
    sed -i 's/minlevel="Trace"/minlevel="Info"/' "$out/Config/nlog.config"
    jq --arg pass "$DB_PASSWORD" '
        .Database.Hostname = "127.0.0.1" | .Database.Port = 3306 | .Database.Username = "hotel"
        | .Database.Password = $pass | .Database.Name = "plus"
        | .Flash.Hostname = "127.0.0.1"
        | .Nitro.Hostname = "127.0.0.1" | .Nitro.Port = 2096 | .Nitro.Name = "Volt"
        | .Rcon.Hostname = "127.0.0.1" | .Rcon.Port = 30001 | .Rcon.AllowedAddresses = ["127.0.0.1", "localhost"]' "$config" > "$config.new"
    mv "$config.new" "$config"
    chmod 600 "$config"
    chown -R plusemu:plusemu "$out"

    cat > /etc/systemd/system/plusemu.service <<EOF
[Unit]
Description=PlusEMU hotel emulator
After=network-online.target mariadb.service
Wants=network-online.target
Requires=mariadb.service

[Service]
User=plusemu
WorkingDirectory=$out
ExecStart="$out/Plus Emulator"
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable plusemu
    systemctl restart plusemu
    wait_for_emulator || die "The emulator didn't start. See: journalctl -u plusemu -n 100"
    ok "The emulator is running (service: plusemu)"
}

install_cms() {
    step "Installing the Atom CMS website"
    local cms=$HOTEL_ROOT/cms env=$HOTEL_ROOT/cms/.env
    export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
    cd "$cms"
    [ -f "$env" ] || cp .env.example "$env"
    set_env "$env" APP_NAME "$HOTEL_NAME"
    set_env "$env" APP_ENV production
    set_env "$env" APP_DEBUG false
    set_env "$env" APP_URL "https://$DOMAIN"
    set_env "$env" LOG_LEVEL warning
    set_env "$env" DB_CONNECTION mariadb
    set_env "$env" DB_HOST 127.0.0.1
    set_env "$env" DB_PORT 3306
    set_env "$env" DB_DATABASE plus
    set_env "$env" DB_USERNAME hotel
    set_env "$env" DB_PASSWORD "$DB_PASSWORD"
    set_env "$env" EMULATOR_DRIVER plus
    set_env "$env" CLIENT_NITRO_ENABLED true
    set_env "$env" NITRO_CLIENT_PATH "https://$DOMAIN/client"
    set_env "$env" RCON_HOST 127.0.0.1
    set_env "$env" RCON_PORT 30001
    set_env "$env" FORCE_HTTPS true
    set_env "$env" SESSION_SECURE_COOKIE true
    set_env "$env" TRUSTED_PROXIES 127.0.0.1
    chmod 640 "$env"

    composer install --no-dev --optimize-autoloader
    npm ci --no-audit --no-fund
    php artisan atom:install --emulator=plus --theme=dusk --no-interaction

    if [ "$(sql -N plus -e 'SELECT COUNT(*) FROM website_installation WHERE completed = 1' 2>/dev/null || echo 0)" = 0 ]; then
        repair_admin_password
        local settings
        settings=$(mktemp)
        jq -n --arg name "$HOTEL_NAME" '{hotel_name: $name}' > "$settings"
        ATOM_ADMIN_EMAIL=$ADMIN_EMAIL ATOM_ADMIN_PASSWORD=$ADMIN_PASSWORD \
            php artisan atom:setup --complete --settings="$settings" --admin="$ADMIN_USER" --no-interaction
        rm -f "$settings"
        # Atom seeds a placeholder "Admin" with a random password, and --admin=admin
        # only promotes it, so set the admin's name, email and password explicitly.
        ADMIN_USER=$ADMIN_USER ADMIN_EMAIL=$ADMIN_EMAIL ADMIN_PASSWORD=$ADMIN_PASSWORD php <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$user = App\Models\User::where('username', getenv('ADMIN_USER'))->firstOrFail();
$user->forceFill(['username' => getenv('ADMIN_USER'), 'mail' => getenv('ADMIN_EMAIL'), 'password' => getenv('ADMIN_PASSWORD')])->save();
PHP
    fi
    sql plus <<EOF
UPDATE website_settings SET value = CASE \`key\`
    WHEN 'nitro_path' THEN 'https://$DOMAIN/client'
    WHEN 'rcon_ip' THEN '127.0.0.1'
    WHEN 'rcon_port' THEN '30001'
    WHEN 'badges_path' THEN 'https://$DOMAIN/hotel-files/c_images/album1584'
    WHEN 'furniture_icons_path' THEN 'https://$DOMAIN/hotel-files/c_images/hof_furni/icons'
    ELSE value END
WHERE \`key\` IN ('nitro_path', 'rcon_ip', 'rcon_port', 'badges_path', 'furniture_icons_path');
EOF
    php artisan optimize:clear
    php artisan optimize
    chown -R www-data:www-data storage bootstrap/cache
    chgrp www-data "$env"
    echo "* * * * * www-data cd $cms && php artisan schedule:run > /dev/null 2>&1" > /etc/cron.d/atom-cms
    cd /
    ok "Website installed (admin: $ADMIN_USER)"
}

cloudflare_real_ip() {
    local ranges
    ranges=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4; echo; curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6) || true
    if ! printf '%s' "$ranges" | grep -q '/'; then
        ranges="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18
190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14
172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
2a06:98c0::/29 2c0f:f248::/32"
    fi
    {
        echo "# Cloudflare edge ranges: log and rate-limit the visitor's address, not Cloudflare's."
        for range in $ranges; do echo "set_real_ip_from $range;"; done
        echo "real_ip_header CF-Connecting-IP;"
    } > /etc/nginx/conf.d/cloudflare-real-ip.conf
}

ws_location() { # the nginx block that hands the game connection to the emulator
    cat <<EOF
    location = $WS_PATH {
        if (\$http_origin != "https://$DOMAIN") { return 403; }
        proxy_pass http://127.0.0.1:2096;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
    }
EOF
}

configure_web() {
    step "Configuring nginx, HTTPS and the firewall"
    local ssl=/etc/ssl/plusemu php_sock=/run/php/php$PHP-fpm.sock
    mkdir -p "$ssl"
    if [ ! -f "$ssl/cert.pem" ]; then
            openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$ssl/key.pem" -out "$ssl/cert.pem" \
            -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN" 2> /dev/null
        chmod 600 "$ssl/key.pem"
    fi
    cloudflare_real_ip
    # Added to nginx's own list; .hab and .nitro already fall back to application/octet-stream.
    echo 'types { application/json jsonc; }' > /etc/nginx/conf.d/hotel-mime.conf

    # nginx 1.25.1 replaced "listen ... http2" with the http2 directive.
    local ssl_listen="listen 443 ssl http2;
    listen [::]:443 ssl http2;"
    if printf '%s\n' 1.25.1 "$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" | sort -V -C; then
        ssl_listen="listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;"
    fi

    local ws_main="" ws_server=""
    if [ "$WS_HOST" = "$DOMAIN" ]; then
        ws_main=$(ws_location)
    else
        ws_server=$(cat <<EOF

server {
    listen 80;
    listen [::]:80;
    $ssl_listen
    server_name $WS_HOST;
    ssl_certificate $ssl/cert.pem;
    ssl_certificate_key $ssl/key.pem;
$(ws_location)
    location / { return 404; }
}
EOF
)
    fi

    cat > /etc/nginx/sites-available/hotel.conf <<EOF
# Generated by the PlusEMU installer. Re-running the installer rewrites this file.

# Requests by IP address get nothing, except the setup guide at its private address.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location /$GUIDE_TOKEN/ { alias $HOTEL_ROOT/setup-guide/; index index.html; }
    location / { return 444; }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate $ssl/cert.pem;
    ssl_certificate_key $ssl/key.pem;
    return 444;
}

server {
    listen 80;
    listen [::]:80;
    $ssl_listen
    server_name www.$DOMAIN;
    ssl_certificate $ssl/cert.pem;
    ssl_certificate_key $ssl/key.pem;
    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 80;
    listen [::]:80;
    $ssl_listen
    server_name $DOMAIN;
    ssl_certificate $ssl/cert.pem;
    ssl_certificate_key $ssl/key.pem;

    root $HOTEL_ROOT/cms/public;
    index index.php;
    charset utf-8;
    client_max_body_size 20m;
    server_tokens off;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/javascript image/svg+xml application/wasm;

$ws_main

    # The game client (Volt). Hashed bundles never change; config is re-read every load.
    location /client/ {
        alias $HOTEL_ROOT/client/;
        index index.html;
        location ~ ^/client/(src/)?assets/ { expires max; }
        location ~ ^/client/(index\.html|configuration/) { expires -1; }
    }
    location = /client { return 301 /client/; }
    location = /ads.txt { alias $HOTEL_ROOT/client/ads.txt; }

    # Answered by the emulator: FurnitureData.json built from the furniture table, and badge rarity.
    location = /api/gamedata/furnidata { proxy_pass http://127.0.0.1:8080; }
    location = /api/badges/leaderboard { proxy_pass http://127.0.0.1:8080; }

    # Furniture, clothes, badges and texts.
    location /hotel-files/ {
        alias $HOTEL_ROOT/hotel-files/;
        expires 7d;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:$php_sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param HTTPS on;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known) { deny all; }
}
$ws_server
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/hotel.conf /etc/nginx/sites-enabled/hotel.conf
    nginx -t
    systemctl enable --now "php$PHP-fpm" nginx
    systemctl reload nginx
    ok "nginx serves https://$DOMAIN"

    local port ports
    ports=$( (sshd -T 2>/dev/null || true) | awk '/^port / {print $2}')
    for port in 22 $ports; do ufw allow "$port/tcp"; done
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    ok "Firewall on: only SSH, HTTP and HTTPS are open (the database and emulator stay private)"
}

# shellcheck disable=SC2034 # the {{KEY}} values are read by render() through ${!key}
write_guide() {
    step "Writing your setup guide"
    mkdir -p "$HOTEL_ROOT/setup-guide"
    CREDENTIALS_FILE=$STATE_FILE
    RESTART_COMMAND="sudo systemctl restart plusemu"
    LOG_COMMAND="sudo journalctl -u plusemu -f"
    GUIDE_MODE_TITLE=${GUIDE_MODE^}
    GUIDE_MODE_DETAILS=$(< "$TEMPLATES/guide-$GUIDE_MODE.html")
    WS_DNS_ROW=""
    if [ "$WS_HOST" != "$DOMAIN" ]; then
        WS_DNS_ROW="<tr><td>A</td><td><code>${WS_HOST%."$DOMAIN"}</code></td><td><code>$SERVER_IP</code></td><td>Proxied (orange cloud)</td></tr>"
    fi
    render "$TEMPLATES/setup-guide.html" "$HOTEL_ROOT/setup-guide/index.html" "$TEMPLATES/certificate-linux.html"
    ok "Guide written"
}

finish() {
    systemctl is-active --quiet plusemu || systemctl restart plusemu
    say ""
    say "${green}${bold}🎉 Your hotel is installed!${reset}"
    say ""
    say "  One last part: connect your domain and install your Cloudflare origin certificate."
    say "  Open this page in your browser for easy step-by-step instructions:"
    say ""
    say "      ${bold}${cyan}http://$SERVER_IP/$GUIDE_TOKEN/${reset}"
    say ""
    say "  Your admin login for https://$DOMAIN (also saved in $STATE_FILE):"
    say "      Username: ${bold}$ADMIN_USER${reset}"
    # Passwords go to the operator's terminal, not the log they may share for help.
    printf '      Password: %s\n' "$ADMIN_PASSWORD" >&3
    say ""
    say "  MariaDB connection (on this server, or through an SSH tunnel):"
    say "      Host: 127.0.0.1    Port: 3306    Database: plus    Username: hotel"
    printf '      Password: %s\n' "$DB_PASSWORD" >&3
    say "      Connect locally: mariadb --host=127.0.0.1 --port=3306 --user=hotel --password plus"
    say "      Database root uses local socket authentication: sudo mariadb (no generated root password)."
    say ""
    say "  Retrieve saved passwords: sudo cat $STATE_FILE"
    say "  Update the emulator and the client later with: sudo plusemu-update"
    say "  Store passwords somewhere safe. Change the initial admin password after logging in;"
    say "  the saved file retains the initial password. Keep passwords out of shared logs and screenshots."
    say ""
}

# ---------------------------------------------------------------- update

carry_over() { # carry_over <installed dir> <new dir> [skipped path regex]: copy the files the new release lacks
    local old=$1 new=$2 skip=${3:-} file
    while IFS= read -r -d '' file; do
        file=${file#./}
        if [ -n "$skip" ] && [[ $file =~ $skip ]]; then continue; fi
        if [ ! -e "$new/$file" ] && [ ! -L "$new/$file" ]; then
            mkdir -p "$new/$(dirname "$file")"
            cp -a "$old/$file" "$new/$file"
        fi
    done < <(cd "$old" && find . \( -type f -o -type l \) -print0)
}

keep_emulator_files() { # keep_emulator_files <installed dir> <new dir>
    local old=$1 new=$2 defaults
    defaults=$(sed '1s/^\xEF\xBB\xBF//' "$new/Config/config.json")
    # The release's own libraries replace the old ones; the other files it lacks are the hotel's.
    carry_over "$old" "$new" '^([^/]+\.(dll|so|pdb|json)|backups/.*)$'
    cp -a "$old/Config/." "$new/Config/"
    # Keep every installed setting and add the settings this release introduced.
    jq -s '.[0] * .[1]' <(printf '%s' "$defaults") <(sed '1s/^\xEF\xBB\xBF//' "$old/Config/config.json") > "$new/Config/config.json.new" ||
        die "Could not read $old/Config/config.json. Fix the file, then run the update again. Nothing was changed."
    mv "$new/Config/config.json.new" "$new/Config/config.json"
    chmod 600 "$new/Config/config.json"
    chown -R plusemu:plusemu "$new"
}

keep_client_files() { # keep_client_files <installed dir> <new dir>
    local old=$1 new=$2 rendered file
    # Hashed bundles belong to one release; the other files the release lacks are the hotel's.
    carry_over "$old" "$new" '^(src/)?assets/'
    if [ -d "$old/configuration" ]; then
        mkdir -p "$new/configuration"
        cp -a "$old/configuration/." "$new/configuration/"
    fi
    rendered=$(mktemp -d)
    write_client_config "$rendered"
    for file in renderer-config.json ui-config.json client-mode.json; do
        if [ ! -f "$new/configuration/$file" ]; then
            cp "$rendered/$file" "$new/configuration/$file"
        elif jq -s '.[0] * .[1]' "$rendered/$file" "$new/configuration/$file" > "$rendered/$file.new" 2> /dev/null; then
            mv "$rendered/$file.new" "$new/configuration/$file"
        else
            say "      ${yellow}Kept configuration/$file as it is: it is not plain JSON, so no new settings were added.${reset}"
        fi
    done
    rm -rf "$rendered"
}

create_snapshot() { # sets SNAPSHOT to a new backup of the database, the emulator, the client and the versions
    SNAPSHOT=$BACKUP_ROOT/$(date -u +%Y%m%d-%H%M%S-%N)
    local partial=$SNAPSHOT.partial
    install -d -m 700 "$BACKUP_ROOT"
    install -d -m 700 "$partial"
    mariadb-dump --protocol=socket -uroot --single-transaction --routines --triggers --events plus | gzip > "$partial/database.sql.gz"
    # The emulator's own database backups stay in place and are not copied again.
    # Exit code 1 only means a file changed while it was read, for example a log of the running emulator.
    tar -C "$HOTEL_ROOT" --exclude=emulator/backups --warning=no-file-changed -czf "$partial/files.tar.gz" emulator client || [ "$?" = 1 ]
    if [ -f "$VERSIONS_FILE" ]; then cp "$VERSIONS_FILE" "$partial/versions.env"; fi
    mv "$partial" "$SNAPSHOT"
}

restore_snapshot() { # restore_snapshot <backup dir> <restore the database: 0|1>
    local snapshot=$1 staging=$HOTEL_ROOT/.restore
    systemctl stop plusemu || return 1
    rm -rf "$staging" && mkdir -p "$staging" || return 1
    tar xzf "$snapshot/files.tar.gz" -C "$staging" || return 1
    if [ -d "$HOTEL_ROOT/emulator/backups" ] && [ ! -e "$staging/emulator/backups" ]; then
        mv "$HOTEL_ROOT/emulator/backups" "$staging/emulator/backups" || return 1
    fi
    rm -rf "$HOTEL_ROOT/emulator" "$HOTEL_ROOT/client" || return 1
    mv "$staging/emulator" "$staging/client" "$HOTEL_ROOT/" && rmdir "$staging" || return 1
    chown -R plusemu:plusemu "$HOTEL_ROOT/emulator" || return 1
    if [ "$2" = 1 ]; then
        sql -e "DROP DATABASE IF EXISTS plus; CREATE DATABASE plus CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
        gunzip -c "$snapshot/database.sql.gz" | sql plus || return 1
    fi
    if [ -f "$snapshot/versions.env" ]; then
        cp "$snapshot/versions.env" "$VERSIONS_FILE" || return 1
    else
        rm -f "$VERSIONS_FILE"
    fi
    systemctl start plusemu
}

prune_snapshots() {
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*.partial' -exec rm -rf {} +
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -n -"$KEEP_BACKUPS" | xargs -r -d '\n' rm -rf
}

finish_update() { # the EXIT trap: undo an unfinished update and remove temporary files
    local snapshot=${RESTORE_FROM:-}
    RESTORE_FROM=
    rm -rf "${INSTALLER_TMP:-}"
    if [ -n "$snapshot" ]; then
        say ""
        say "  Restoring the previous version from $snapshot ..."
        if restore_snapshot "$snapshot" "$RESTORE_DATABASE"; then
            say "  ${green}Your hotel was restored to the version it had before this update.${reset}"
        else
            systemctl start plusemu || true
            say "  ${red}${bold}The automatic restore failed.${reset} Your backup is in $snapshot"
            say "  (files.tar.gz and database.sql.gz). The previous files are also in ${WORK:-$HOTEL_ROOT}."
            say "  Ask for help on DevBest with the log: $LOG"
            return
        fi
    elif [ "${EMULATOR_STOPPED:-0}" = 1 ]; then
        systemctl start plusemu || true
    fi
    rm -rf "${WORK:-}"
}

require_update_space() {
    # Staged copies and the backup of the files, plus two dumps of the database: the backup's and the emulator's own.
    local files_mb database_mb
    files_mb=$(du -smc --exclude=emulator/backups "$HOTEL_ROOT/emulator" "$HOTEL_ROOT/client" | tail -1 | cut -f1)
    database_mb=$(sql -N -e "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1048576), 0) FROM information_schema.tables WHERE table_schema = 'plus'" < /dev/null)
    require_free_space $(((files_mb * 3 + ${database_mb:-0} * 2) / 1024 + 1)) "$HOTEL_ROOT"
}

confirm_update() { # confirm_update <question>
    [ "${PLUSEMU_YES:-0}" != 1 ] || return 0
    local go
    ask go "$1 (y/n)" "y"
    [[ $go =~ ^[Yy] ]] || die "Cancelled. Nothing was changed."
}

rollback_update() {
    local target name versions="unknown versions"
    target=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' 2> /dev/null | sort | tail -1)
    [ -n "$target" ] || die "No backup found in $BACKUP_ROOT. Nothing was changed."
    name=${target##*/}
    if [ -f "$target/versions.env" ]; then
        versions=$(EMULATOR_VERSION=unknown CLIENT_VERSION=unknown
            # shellcheck disable=SC1091
            . "$target/versions.env"
            printf 'emulator %s, client %s' "$EMULATOR_VERSION" "$CLIENT_VERSION")
    fi
    say ""
    say "${bold}Restore the backup from ${name:0:4}-${name:4:2}-${name:6:2} ${name:9:2}:${name:11:2} UTC${reset} ($versions)."
    say "  ${yellow}The database goes back to that moment too: game changes made since then are lost.${reset}"
    confirm_update "Restore this backup?"

    require_update_space
    TOTAL_STEPS=2
    step "Backing up the current state"
    systemctl stop plusemu
    EMULATOR_STOPPED=1
    create_snapshot
    ok "Saved in $SNAPSHOT"
    step "Restoring the backup"
    RESTORE_FROM=$SNAPSHOT RESTORE_DATABASE=1
    restore_snapshot "$target" 1 || die "Could not restore $target."
    RESTORE_FROM='' EMULATOR_STOPPED=0
    wait_for_emulator || die "The restored emulator didn't start. See: journalctl -u plusemu -n 100"
    prune_snapshots
    ok "Restored $target"
    say ""
    say "  ${green}${bold}Done.${reset} To undo this, run the same command again: sudo plusemu-update --rollback"
}

update_main() {
    local check=0 rollback=0 arg latest_emulator latest_client update_emulator=0 update_client=0
    for arg in "$@"; do
        case "$arg" in
            --check) check=1 ;;
            --yes) PLUSEMU_YES=1 ;;
            --rollback) rollback=1 ;;
            *) die "Unknown option: $arg. Usage: plusemu-update [--check] [--yes] [--rollback]" ;;
        esac
    done
    MODE=update
    LOG=$UPDATE_LOG
    trap 'on_error $LINENO' ERR
    preflight 1
    if [ ! -f "$STATE_FILE" ] || [ ! -x "$HOTEL_ROOT/emulator/Plus Emulator" ]; then
        die "No hotel from the PlusEMU installer was found on this server. Install one first."
    fi
    exec 9> "$LOCK_FILE"
    flock -n 9 || die "Another update is already running."
    : > "$LOG"
    chmod 600 "$LOG"
    exec >> "$LOG" 2>&1
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    EMULATOR_VERSION=unknown CLIENT_VERSION=unknown
    # shellcheck disable=SC1090
    if [ -f "$VERSIONS_FILE" ]; then . "$VERSIONS_FILE"; fi
    # A closed SSH session does not stop the update; other stop signals restore the previous version.
    trap '' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap finish_update EXIT

    if [ "$rollback" = 1 ]; then
        rollback_update
        return
    fi

    latest_emulator=$(release_version "$EMULATOR_REPO" "$EMULATOR_URL") || die "Could not find the latest PlusEMU release. Check the server's internet connection."
    latest_client=$(release_version "$CLIENT_REPO" "$CLIENT_URL") || die "Could not find the latest Volt release. Check the server's internet connection."
    if [ "$EMULATOR_VERSION" != "$latest_emulator" ]; then update_emulator=1; fi
    if [ "$CLIENT_VERSION" != "$latest_client" ]; then update_client=1; fi
    say ""
    say "${bold}PlusEMU hotel update${reset}"
    if [ "$update_emulator" = 1 ]; then
        say "  Emulator (PlusEMU): $EMULATOR_VERSION -> ${bold}$latest_emulator${reset}"
    else
        say "  Emulator (PlusEMU): $EMULATOR_VERSION (up to date)"
    fi
    if [ "$update_client" = 1 ]; then
        say "  Client (Volt):      $CLIENT_VERSION -> ${bold}$latest_client${reset}"
    else
        say "  Client (Volt):      $CLIENT_VERSION (up to date)"
    fi
    if [ "$update_emulator" = 0 ] && [ "$update_client" = 0 ]; then
        say ""
        say "  ${green}Everything is up to date.${reset}"
        return
    fi
    if [ "$check" = 1 ]; then
        say ""
        say "  Install the update with: sudo plusemu-update"
        return
    fi
    say ""
    say "  Your settings and added files are kept, and a backup is made first."
    if [ "$update_emulator" = 1 ]; then say "  Players are disconnected for about a minute."; fi
    confirm_update "Update now?"

    require_update_space
    WORK=$(mktemp -d "$HOTEL_ROOT/.update.XXXXXX")
    TOTAL_STEPS=4

    step "Downloading the new versions"
    if [ "$update_emulator" = 1 ]; then
        stage_emulator "$latest_emulator" "$WORK/emulator"
        keep_emulator_files "$HOTEL_ROOT/emulator" "$WORK/emulator"
        ok "PlusEMU $latest_emulator (your settings and added files are kept)"
    fi
    if [ "$update_client" = 1 ]; then
        load_installer_files
        derive_settings
        stage_client "$latest_client" "$WORK/client"
        keep_client_files "$HOTEL_ROOT/client" "$WORK/client"
        ok "Volt $latest_client (your configuration and added files are kept)"
    fi

    step "Backing up your hotel"
    if [ "$update_emulator" = 1 ]; then
        systemctl stop plusemu
        EMULATOR_STOPPED=1
    fi
    create_snapshot
    ok "Database, emulator and client saved in $SNAPSHOT"
    RESTORE_FROM=$SNAPSHOT RESTORE_DATABASE=0

    step "Installing the new versions"
    if [ "$update_emulator" = 1 ]; then
        if [ -d "$HOTEL_ROOT/emulator/backups" ]; then mv "$HOTEL_ROOT/emulator/backups" "$WORK/emulator/backups"; fi
        mv "$HOTEL_ROOT/emulator" "$WORK/emulator.old"
        mv "$WORK/emulator" "$HOTEL_ROOT/emulator"
        RESTORE_DATABASE=1
        runuser -u plusemu -- env -C "$HOTEL_ROOT/emulator" "./Plus Emulator" --migrate < /dev/null
        ok "PlusEMU $latest_emulator installed and the database updated"
    fi
    if [ "$update_client" = 1 ]; then
        mv "$HOTEL_ROOT/client" "$WORK/client.old"
        mv "$WORK/client" "$HOTEL_ROOT/client"
        ok "Volt $latest_client installed"
    fi

    step "Starting the emulator"
    if [ "$update_emulator" = 1 ]; then
        systemctl start plusemu
        wait_for_emulator || die "The new emulator didn't start. See: journalctl -u plusemu -n 100"
        EMULATOR_STOPPED=0
        ok "The emulator is running"
    else
        ok "The emulator kept running"
    fi
    RESTORE_FROM=
    EMULATOR_VERSION=$latest_emulator CLIENT_VERSION=$latest_client
    save_versions
    prune_snapshots
    install_update_command

    say ""
    say "${green}${bold}✓ Your hotel is up to date.${reset}"
    say "  Emulator: $EMULATOR_VERSION    Client: $CLIENT_VERSION"
    say "  Players get the new client when they reload the hotel page."
    say "  Backup of the previous version: $SNAPSHOT"
    say "  Undo this update: sudo plusemu-update --rollback"
    say "  Next time, update with: sudo plusemu-update"
    say ""
}

main() {
    if [ "${1:-}" = update ]; then
        shift
        update_main "$@"
        return
    fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --guide-mode)
                if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                    die "Usage: install.sh [--guide-mode simple|advanced]"
                fi
                GUIDE_MODE_OPTION=$2
                shift 2
                ;;
            *) die "Unknown option: $1. Usage: install.sh [--guide-mode simple|advanced]" ;;
        esac
    done
    select_guide_mode
    trap 'on_error $LINENO' ERR
    preflight
    : > "$LOG"
    chmod 600 "$LOG"
    exec >> "$LOG" 2>&1
    load_installer_files
    ask_questions
    say "  Admin and database passwords are saved in $STATE_FILE. Retrieve them with: sudo cat $STATE_FILE"
    derive_settings
    install_packages
    install_toolchains
    download_releases
    setup_database
    download_hotel_files
    start_emulator
    write_client_config
    install_cms
    configure_web
    write_guide
    install_update_command
    finish
}

main "$@"

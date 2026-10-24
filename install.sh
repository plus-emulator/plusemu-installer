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
# PLUSEMU_CLOUDFLARE_TOKEN sets up Cloudflare with that API token; it is never saved.
set -Eeuo pipefail
shopt -u patsub_replacement 2> /dev/null || true # bash 5.2 would expand "&" in template values

INSTALLER_REPO=${INSTALLER_REPO:-plus-emulator/plusemu-installer}
INSTALLER_REF=${INSTALLER_REF:-main}
# The hotel files pack is rebuilt from the asset bucket and published on the rolling "hotel-files" release.
ASSET_PACK_URL=${ASSET_PACK_URL:-https://github.com/plus-emulator/plusemu-installer/releases/download/hotel-files/hotel-files.tar.gz}
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
NIGHTLY_ROOT=$BACKUP_ROOT/nightly
KEEP_NIGHTLY=7
BACKUP_COMMAND=/usr/local/sbin/plusemu-backup
BACKUP_CRON=/etc/cron.d/plusemu-backup
BACKUP_LOG=/var/log/plusemu-backup.log
SSL_DIR=/etc/ssl/plusemu
LOCK_FILE=/run/plusemu-update.lock
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-plusemu.conf
REAL_IP_CONF=/etc/nginx/conf.d/cloudflare-real-ip.conf
CLOUDFLARE_COMMAND=/usr/local/sbin/plusemu-cloudflare-ips
CLOUDFLARE_CRON=/etc/cron.d/plusemu-cloudflare-ips
CLOUDFLARE_LOG=/var/log/plusemu-cloudflare-ips.log
CLOUDFLARE_TAG=plusemu-cloudflare
UFW_DEFAULTS=/etc/default/ufw
CF_API=https://api.cloudflare.com/client/v4
ORIGIN_CA_ROOT_URL=https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem
TTY=/dev/tty
LOGROTATE_CONF=/etc/logrotate.d/plusemu
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/90-plusemu.conf
MODE=install
PHP=8.5
NODE_MAJOR=22
TOTAL_STEPS=11
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
    # The fragments come first, so the placeholders inside them are filled too.
    for key in CLOUDFLARE_STATUS MANUAL_START MANUAL_END GUIDE_INTRO GAME_ADDRESS_ITEM DOMAIN SOCKET_URL FURNIDATA_URL SERVER_IP WS_HOST HOTEL_NAME ADMIN_USER ADMIN_EMAIL \
        CREDENTIALS_FILE RESTART_COMMAND LOG_COMMAND WS_DNS_ROW GUIDE_MODE_TITLE GUIDE_MODE_DETAILS CERTIFICATE_EXPIRES CLOUDFLARE_ERROR_HTML; do
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
CLOUDFLARE_SETUP='${CLOUDFLARE_SETUP:-}'
CLOUDFLARE_CERT_EXPIRES='${CLOUDFLARE_CERT_EXPIRES:-}'
EOF
    chmod 600 "$STATE_FILE"
    umask 022
}

save_versions() {
    install -d -m 700 "$(dirname "$VERSIONS_FILE")"
    printf "EMULATOR_VERSION='%s'\nCLIENT_VERSION='%s'\nASSETS_VERSION='%s'\n" "$EMULATOR_VERSION" "$CLIENT_VERSION" "$ASSETS_VERSION" > "$VERSIONS_FILE"
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

fetch_checked() { # fetch_checked <base URL> <asset> <file>: checked against SHA256SUMS next to it, when there is one
    local base=$1 sums=$3.sums status expected
    if [ -t 3 ] && [ "$2" = "${ASSET_PACK_URL##*/}" ]; then
        curl -fL --retry 3 --progress-bar "$base/$2" -o "$3" 2>&3 || return 1
    else
        curl -fsSL --retry 3 "$base/$2" -o "$3" || return 1
    fi
    status=$(curl -sSL --retry 3 -o "$sums" -w '%{http_code}' "$base/SHA256SUMS") || status=000
    case $status in
        200) expected=$(awk -v file="$2" '$2 == file || $2 == "*" file {print $1}' "$sums") ;;
        404) rm -f "$sums"; return 0 ;; # older releases publish no checksums
        *) rm -f "$sums"; die "Could not download the checksums for $2. Nothing was changed. Try again later." ;;
    esac
    rm -f "$sums"
    if [ -z "$expected" ] || [ "$(sha256sum "$3" | cut -d' ' -f1)" != "$expected" ]; then
        die "The download of $2 does not match its published checksum. Nothing was changed. Try again later."
    fi
}

fetch_release() { # fetch_release <owner/repo> <tag> <asset> <file>
    fetch_checked "https://github.com/$1/releases/download/$2" "$3" "$4"
}

pack_version() { # the start of the hotel files pack's published checksum, or "custom" when it has none
    local sums status version
    sums=$(mktemp)
    status=$(curl -sSL --retry 3 -o "$sums" -w '%{http_code}' "${ASSET_PACK_URL%/*}/SHA256SUMS") || status=000
    case $status in
        200) version=$(awk -v file="${ASSET_PACK_URL##*/}" '$2 == file || $2 == "*" file {print substr($1, 1, 12)}' "$sums") ;;
        404) version=custom ;;
    esac
    rm -f "$sums"
    [ -n "${version:-}" ] || return 1
    printf '%s' "$version"
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
#   sudo plusemu-update [--check] [--yes] [--assets] [--rollback]
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
    apt-get install -y ca-certificates curl git unzip jq gnupg openssl cron ufw nginx mariadb-server mariadb-client libicu-dev xz-utils \
        fail2ban python3-systemd unattended-upgrades
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
    EMULATOR_VERSION=unknown CLIENT_VERSION=unknown ASSETS_VERSION=unknown
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
    step "Downloading the hotel files (furniture, clothes, badges, texts; about 550 MB)"
    # A re-run installs the newest pack over the hotel files when it changed. Files the owner added stay.
    local files=$HOTEL_ROOT/hotel-files latest pack
    latest=$(pack_version) || latest=unknown
    if [ "$latest" != unknown ] && [ "$latest" = "$ASSETS_VERSION" ] && [ -d "$files" ]; then
        ok "Already downloaded (version $latest)"
        return
    fi
    mkdir -p "$files"
    pack=$(mktemp -p "$HOTEL_ROOT")
    fetch_checked "${ASSET_PACK_URL%/*}" "${ASSET_PACK_URL##*/}" "$pack" || die "Could not download the hotel files. Run the installer again."
    tar xzf "$pack" --no-same-owner -C "$files"
    rm -f "$pack" "$files/.complete"
    ASSETS_VERSION=$latest
    save_versions
    ok "Hotel files $latest ready ($(du -sh "$files" | cut -f1))"
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

cloudflare_ranges() { # Cloudflare's published address ranges, one per line; fails unless both lists download and parse
    local list
    for list in ips-v4 ips-v6; do
        curl -fsS --max-time 20 "https://www.cloudflare.com/$list" | python3 -I -c '
import ipaddress, sys
version = int(sys.argv[1])
try:
    ranges = [ipaddress.ip_network(line.strip()) for line in sys.stdin if line.strip()]
except ValueError as error:
    sys.exit(error)
if not ranges or any(r.version != version for r in ranges):
    sys.exit("not a list of IPv%d ranges" % version)
# The same form ufw writes, so the old rules can be told apart from the new ones.
for r in ranges:
    print(r.network_address if r.prefixlen == r.max_prefixlen else r)
' "${list#ips-v}" || return 1
    done
}

real_ip_conf() { # real_ip_conf <ranges> [unchecked]: nginx settings for visitors that come through Cloudflare
    local range others=0 note="The hotel answers only Cloudflare and this server, so nobody can go around Cloudflare."
    # A list that was not downloaded and checked may be out of date, so it blocks nobody.
    if [ "${2:-}" = unchecked ]; then
        others=1
        note="This list was not checked, so the hotel answers every address until plusemu-cloudflare-ips runs."
    fi
    echo "# Cloudflare edge ranges: log and rate-limit the visitor's address, not Cloudflare's."
    for range in $1; do echo "set_real_ip_from $range;"; done
    echo "real_ip_header CF-Connecting-IP;"
    echo ""
    echo "# $note"
    echo "geo \$realip_remote_addr \$plusemu_from_cloudflare {"
    echo "    default $others;"
    echo "    127.0.0.0/8 1;"
    echo "    ::1 1;"
    for range in $1; do echo "    $range 1;"; done
    echo "}"
}

allow_https_from() { # allow_https_from <ranges>: HTTPS only from these ranges, replacing the previous ones
    local ipv6=no range rule added open pattern="^ufw allow from ([^ ]+) to any port 443 proto tcp comment '$CLOUDFLARE_TAG'\$"
    local -A wanted=()
    # With IPv6 off, ufw neither lists nor accepts IPv6 rules.
    if grep -qsx 'IPV6=yes' "$UFW_DEFAULTS"; then ipv6=yes; fi
    for range in $1; do
        if [[ $range == *:* && $ipv6 != yes ]]; then continue; fi
        wanted[$range]=1
        ufw allow proto tcp from "$range" to any port 443 comment "$CLOUDFLARE_TAG" > /dev/null
    done
    # The new rules are in before the old ones go, so HTTPS never closes. Other rules, such as fail2ban's bans, stay.
    added=$(ufw show added)
    while read -r rule; do
        if [[ $rule =~ $pattern ]]; then
            range=${BASH_REMATCH[1]}
            if [[ -z ${wanted[$range]:-} && ($range != *:* || $ipv6 == yes) ]]; then
                ufw delete allow proto tcp from "$range" to any port 443 comment "$CLOUDFLARE_TAG" > /dev/null
            fi
        elif [ "$rule" = 'ufw allow 443/tcp' ]; then
            ufw delete allow 443/tcp > /dev/null
        fi
    done <<< "$added"
    open=$(ufw show added | grep -E "^ufw allow (443|https|'Nginx (Full|HTTPS)')(/tcp)?( comment .*)?\$" || true)
    while read -r rule; do
        if [ -n "$rule" ]; then
            cloudflare_warn "Another firewall rule still lets every address reach HTTPS. Remove it with: sudo ${rule/ufw /ufw delete }"
        fi
    done <<< "$open"
}

cloudflare_warn() { if [ -t 1 ]; then printf '\e[33m%s\e[0m\n' "$*"; else printf '%s\n' "$*"; fi; }

# The plusemu-cloudflare-ips command. Without fresh, valid lists it changes nothing, so the hotel stays reachable.
refresh_cloudflare() {
    local ranges conf previous
    if ! ranges=$(cloudflare_ranges); then
        cloudflare_warn "$(date) Could not download Cloudflare's address ranges. The firewall and nginx were left as they are."
        return 1
    fi
    allow_https_from "$ranges"
    conf=$(real_ip_conf "$ranges")
    previous=$(cat "$REAL_IP_CONF" 2> /dev/null || true)
    if [ "$previous" != "$conf" ]; then
        printf '%s\n' "$conf" > "$REAL_IP_CONF"
        if ! nginx -t; then
            if [ -n "$previous" ]; then printf '%s\n' "$previous" > "$REAL_IP_CONF"; else rm -f "$REAL_IP_CONF"; fi
            cloudflare_warn "$(date) nginx did not accept the new Cloudflare ranges, so nginx keeps the previous ones."
            return 1
        fi
        systemctl try-reload-or-restart nginx
    fi
    echo "$(date) HTTPS is accepted only from Cloudflare's $(wc -l <<< "$ranges") address ranges."
}

install_cloudflare_command() {
    mkdir -p "$(dirname "$CLOUDFLARE_COMMAND")" "$(dirname "$CLOUDFLARE_CRON")"
    {
        echo '#!/usr/bin/env bash'
        echo '# Installed by the PlusEMU installer. Cron runs it every Sunday at 03:00; run it by hand with: sudo plusemu-cloudflare-ips'
        echo 'set -Eeuo pipefail'
        echo 'PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin'
        declare -p REAL_IP_CONF CLOUDFLARE_TAG UFW_DEFAULTS
        declare -f cloudflare_ranges real_ip_conf allow_https_from cloudflare_warn refresh_cloudflare
        echo 'refresh_cloudflare'
    } > "$CLOUDFLARE_COMMAND"
    chmod 700 "$CLOUDFLARE_COMMAND"
    echo "0 3 * * 0 root $CLOUDFLARE_COMMAND >> $CLOUDFLARE_LOG 2>&1" > "$CLOUDFLARE_CRON"
}

cloudflare_real_ip() {
    local ranges
    if ranges=$(cloudflare_ranges); then
        real_ip_conf "$ranges" > "$REAL_IP_CONF"
    elif ! grep -qs plusemu_from_cloudflare "$REAL_IP_CONF"; then
        # Cloudflare's ranges when this installer was written; plusemu-cloudflare-ips replaces them.
        real_ip_conf "173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18
190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14
172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
2a06:98c0::/29 2c0f:f248::/32" unchecked > "$REAL_IP_CONF"
    fi
}

request_limits() {
    cat > /etc/nginx/conf.d/plusemu-limits.conf <<'EOF'
# Per-visitor limits. The visitor's address comes from cloudflare-real-ip.conf.
# Only POSTs to the login forms count, so opening the pages is never limited.
# The game client and hotel files have no limits: the client loads hundreds of them at once.
map $request_method $plusemu_login_key {
    POST $binary_remote_addr;
    default "";
}
limit_req_zone $plusemu_login_key zone=plusemu_login:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=plusemu_housekeeping:10m rate=30r/m;
limit_conn_zone $binary_remote_addr zone=plusemu_conn:10m;
limit_conn_zone $binary_remote_addr zone=plusemu_ws:10m;
limit_req_status 429;
limit_conn_status 429;
EOF
}

ws_location() { # the nginx block that hands the game connection to the emulator
    cat <<EOF
    location = $WS_PATH {
        if (\$http_origin != "https://$DOMAIN") { return 403; }
        limit_conn plusemu_ws 20;
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
    local ssl=$SSL_DIR php_sock=/run/php/php$PHP-fpm.sock
    mkdir -p "$ssl"
    if [ ! -f "$ssl/cert.pem" ]; then
            openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$ssl/key.pem" -out "$ssl/cert.pem" \
            -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN" 2> /dev/null
        chmod 600 "$ssl/key.pem"
    fi
    cloudflare_real_ip
    request_limits
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

    # Slow clients that hold connections open without sending a request are dropped.
    local timeouts="client_header_timeout 10s;
    client_body_timeout 10s;
    keepalive_timeout 20s;"
    # The hotel's own names answer only Cloudflare and this server (see cloudflare-real-ip.conf).
    local cloudflare_only='if ($plusemu_from_cloudflare = 0) { return 444; }'

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
    $timeouts
    $cloudflare_only
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
    $timeouts
    location /$GUIDE_TOKEN/ { alias $HOTEL_ROOT/setup-guide/; index index.html; }
    location / { return 444; }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate $ssl/cert.pem;
    ssl_certificate_key $ssl/key.pem;
    $timeouts
    return 444;
}

server {
    listen 80;
    listen [::]:80;
    $ssl_listen
    server_name www.$DOMAIN;
    ssl_certificate $ssl/cert.pem;
    ssl_certificate_key $ssl/key.pem;
    $timeouts
    $cloudflare_only
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
    $timeouts
    $cloudflare_only

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), usb=()" always;

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

    # Atom CMS sign-in, registration and password reset forms.
    location ~ ^/(login|register|forgot-password|reset-password/[^/]+|two-factor-challenge)\$ {
        limit_req zone=plusemu_login burst=5 nodelay;
        limit_conn plusemu_conn 50;
        try_files \$uri /index.php?\$query_string;
    }

    location /housekeeping {
        limit_req zone=plusemu_housekeeping burst=20 nodelay;
        limit_conn plusemu_conn 50;
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location / {
        limit_conn plusemu_conn 50;
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        limit_conn plusemu_conn 50;
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
    configure_firewall
}

# HTTP stays open to everyone for the setup guide and the redirects. HTTPS only takes Cloudflare's addresses,
# so nobody can go around Cloudflare to reach the hotel.
configure_firewall() {
    local port ports
    ports=$( (sshd -T 2>/dev/null || true) | awk '/^port / {print $2}')
    for port in 22 $ports; do ufw allow "$port/tcp"; done
    ufw allow 80/tcp
    # HTTPS is open to everyone until plusemu-cloudflare-ips has limited it to Cloudflare.
    if ! ufw show added | grep -qF "comment '$CLOUDFLARE_TAG'"; then ufw allow 443/tcp; fi
    ufw --force enable
    ok "Firewall on: only SSH, HTTP and HTTPS are open (the database and emulator stay private)"
    install_cloudflare_command
    if "$CLOUDFLARE_COMMAND"; then
        ok "HTTPS is accepted only from Cloudflare's addresses, refreshed every Sunday at 03:00"
    elif ufw show added | grep -qF "comment '$CLOUDFLARE_TAG'"; then
        say "      ${yellow}Could not refresh Cloudflare's addresses; HTTPS keeps the previous ones. Try again later: sudo plusemu-cloudflare-ips${reset}"
    else
        say "      ${yellow}Could not download Cloudflare's addresses, so HTTPS stays open to every address. Try again later: sudo plusemu-cloudflare-ips${reset}"
    fi
}

# ---------------------------------------------------------------- server hardening

sshd_installed() { command -v sshd > /dev/null; }

session_sshd_pids() { # the sshd processes this run descends from
    local pid=$$ comm
    while [ "${pid:-0}" -gt 1 ]; do
        comm=$(ps -o comm= -p "$pid" 2> /dev/null) || return 0
        case $comm in sshd | sshd-session) printf '%s\n' "$pid" ;; esac
        pid=$(ps -o ppid= -p "$pid" 2> /dev/null | tr -d ' ') || return 0
    done
}

sshd_session_log() { # sshd_session_log <pid>: what sshd logged for that process
    journalctl -q --no-pager -o cat "_PID=$1" 2> /dev/null || true
    grep -h "sshd[a-z-]*\[$1\]:" /var/log/auth.log 2> /dev/null || true
}

ssh_login_used_key() { # the SSH login of this session was made with a key
    local pid
    if [[ ${SSH_AUTH_INFO_0:-} == publickey* ]]; then return 0; fi
    for pid in $(session_sshd_pids); do
        if [[ $(sshd_session_log "$pid") == *'Accepted publickey '* ]]; then return 0; fi
    done
    return 1
}

sudo_user() { # the account that ran sudo, unless it is root
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then printf '%s' "$SUDO_USER"; fi
}

sudo_user_has_keys() {
    local user home
    user=$(sudo_user)
    [ -n "$user" ] || return 1
    home=$(getent passwd "$user" | cut -d: -f6)
    [ -n "$home" ] && grep -qE '^[^#[:space:]]' "$home/.ssh/authorized_keys" 2> /dev/null
}

harden_ssh() { # sets SSH_PASSWORDS to on, off or none
    SSH_PASSWORDS=on
    if ! sshd_installed; then
        SSH_PASSWORDS=none
        ok "No SSH server is installed; nothing to change"
        return
    fi
    local previous='' root_keys=0
    if [ -f "$SSHD_DROPIN" ]; then previous=$(< "$SSHD_DROPIN"); fi
    # Password login only goes off when a key login is known to work, so the owner is never locked out.
    if ssh_login_used_key || sudo_user_has_keys || [[ $previous == *'PasswordAuthentication no'* ]]; then
        SSH_PASSWORDS=off
        root_keys=1
    elif [ -n "$(sudo_user)" ]; then
        root_keys=1
    fi
    if [ "$root_keys" = 0 ]; then
        say "      ${yellow}SSH password login stays on: this session did not log in with an SSH key. The setup guide explains how to turn it off.${reset}"
        return
    fi
    mkdir -p "$(dirname "$SSHD_DROPIN")"
    # sshd -t needs this folder, which only exists once the SSH service has started.
    install -d -m 755 /run/sshd 2> /dev/null || true
    {
        echo "# Written by the PlusEMU installer. sshd uses the first value it reads, so this file sorts before the other drop-ins."
        echo "PermitRootLogin prohibit-password"
        if [ "$SSH_PASSWORDS" = off ]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
        fi
    } > "$SSHD_DROPIN"
    if ! sshd -t; then
        if [ -n "$previous" ]; then printf '%s\n' "$previous" > "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
        SSH_PASSWORDS=on
        say "      ${yellow}SSH was left as it is: sshd did not accept the new settings (see $LOG).${reset}"
        return
    fi
    if ! systemctl try-reload-or-restart ssh.service; then
        say "      ${yellow}The SSH service did not reload; the new SSH settings apply after a restart.${reset}"
    fi
    if [ "$SSH_PASSWORDS" = off ]; then
        if [[ $(sshd -T 2> /dev/null) != *'passwordauthentication no'* ]]; then
            SSH_PASSWORDS=on
            say "      ${yellow}SSH password login stays on: another SSH setting turns it on. Check: sudo sshd -T | grep -i passwordauthentication${reset}"
            return
        fi
        ok "SSH: key login only (password login is off, root may log in with a key only)"
    else
        ok "SSH: root may log in with a key only"
        say "      ${yellow}SSH password login stays on: $(sudo_user) has no SSH key. The setup guide explains how to turn it off.${reset}"
    fi
}

protect_ssh_logins() {
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/plusemu.local <<'EOF'
# Written by the PlusEMU installer. Bans an address for 1 hour after 5 failed SSH logins in 10 minutes.
[sshd]
enabled = true
backend = systemd
banaction = ufw
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    systemctl enable fail2ban
    if systemctl restart fail2ban; then
        ok "fail2ban bans an address for 1 hour after 5 failed SSH logins"
    else
        say "      ${yellow}fail2ban did not start. See: journalctl -u fail2ban -n 50${reset}"
    fi
}

install_security_updates() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    # The emulator, client, website and the PHP packages are not from these sources:
    # plusemu-update and php-update.sh update them.
    cat > /etc/apt/apt.conf.d/52plusemu-security-updates <<'EOF'
// Written by the PlusEMU installer: security updates only, with a restart only when an update needs one.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Ubuntu,archive=${distro_codename}-security";
    "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";
    "origin=UbuntuESM,archive=${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "now";
EOF
    # The package lists refresh at 04:30, after the nightly backup, and updates install at 05:00.
    mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
    printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 04:30\nRandomizedDelaySec=0\n' > /etc/systemd/system/apt-daily.timer.d/plusemu.conf
    printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 05:00\nRandomizedDelaySec=0\n' > /etc/systemd/system/apt-daily-upgrade.timer.d/plusemu.conf
    systemctl daemon-reload
    systemctl enable apt-daily.timer apt-daily-upgrade.timer
    systemctl restart apt-daily.timer apt-daily-upgrade.timer
    ok "Security updates install every day at 05:00 server time; the server restarts only when an update needs it"
}

tune_network() {
    # Only raise the queues for new connections; a bigger server may already have more.
    local backlog somaxconn
    backlog=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2> /dev/null || true)
    somaxconn=$(sysctl -n net.core.somaxconn 2> /dev/null || true)
    if ! [[ $backlog =~ ^[0-9]+$ ]] || [ "$backlog" -lt 4096 ]; then backlog=4096; fi
    if ! [[ $somaxconn =~ ^[0-9]+$ ]] || [ "$somaxconn" -lt 4096 ]; then somaxconn=4096; fi
    cat > /etc/sysctl.d/90-plusemu.conf <<EOF
# Written by the PlusEMU installer: survive floods of new connections.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = $backlog
net.core.somaxconn = $somaxconn
net.ipv4.tcp_fin_timeout = 15
EOF
    if sysctl --system; then
        ok "Network settings for floods of new connections (/etc/sysctl.d/90-plusemu.conf)"
    else
        say "      ${yellow}Some network settings could not be applied (this happens in some containers). See $LOG.${reset}"
    fi
}

rotate_logs() {
    cat > "$LOGROTATE_CONF" <<EOF
# Written by the PlusEMU installer.
/var/log/plusemu-*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 600 root root
}

$HOTEL_ROOT/cms/storage/logs/laravel.log {
    su www-data www-data
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    # The emulator logs to the journal. A rerun leaves the journal running when nothing changed.
    local journal=$'[Journal]\nSystemMaxUse=1G\nMaxRetentionSec=14day'
    if [ "$(cat "$JOURNALD_DROPIN" 2> /dev/null)" != "$journal" ]; then
        mkdir -p "$(dirname "$JOURNALD_DROPIN")"
        printf '%s\n' "$journal" > "$JOURNALD_DROPIN"
        systemctl restart systemd-journald
    fi
    ok "Logs are kept for 14 days (the system journal uses at most 1 GB)"
}

# The plusemu-backup command. It saves what a download cannot bring back: the database,
# the settings, the website's uploads and the hotel's texts.
nightly_backup() {
    local target partial free_mb database_mb path saved=() settings=()
    exec 9> "$LOCK_FILE"
    if ! flock -w "${BACKUP_LOCK_WAIT:-3600}" 9; then
        echo "$(date) An update is still running; no backup was made."
        return 1
    fi
    install -d -m 700 "$BACKUP_ROOT" "$NIGHTLY_ROOT"
    database_mb=$(mariadb --protocol=socket -uroot -N -e "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1048576), 0) FROM information_schema.tables WHERE table_schema = 'plus'")
    free_mb=$(df -Pm "$NIGHTLY_ROOT" | awk 'NR == 2 {print $4}')
    if [ "$free_mb" -lt $((database_mb + 2048)) ]; then
        echo "$(date) Only $free_mb MB free in $NIGHTLY_ROOT; no backup was made."
        return 1
    fi
    target=$NIGHTLY_ROOT/$(date -u +%Y%m%d-%H%M%S-%N)
    partial=$target.partial
    install -d -m 700 "$partial"
    mariadb-dump --protocol=socket -uroot --single-transaction --routines --triggers --events plus | gzip > "$partial/database.sql.gz"
    for path in emulator/Config client/configuration cms/.env cms/storage/app hotel-files/gamedata; do
        if [ -e "$HOTEL_ROOT/$path" ]; then saved+=("$path"); fi
    done
    # Exit code 1 only means a file changed while it was read.
    tar -C "$HOTEL_ROOT" --warning=no-file-changed -czf "$partial/hotel.tar.gz" "${saved[@]}" || [ "$?" = 1 ]
    for path in "$STATE_FILE" "$VERSIONS_FILE" "$SSL_DIR"; do
        if [ -e "$path" ]; then settings+=("${path#/}"); fi
    done
    tar -C / -czf "$partial/settings.tar.gz" "${settings[@]}"
    mv "$partial" "$target"
    find "$NIGHTLY_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*.partial' -exec rm -rf {} +
    find "$NIGHTLY_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort | head -n -"$KEEP_NIGHTLY" | xargs -r -d '\n' rm -rf
    echo "$(date) Backup saved in $target"
}

install_backup_command() {
    mkdir -p "$(dirname "$BACKUP_COMMAND")" "$(dirname "$BACKUP_CRON")"
    {
        echo '#!/usr/bin/env bash'
        echo '# Installed by the PlusEMU installer. Cron runs it every night at 04:00; run it by hand with: sudo plusemu-backup'
        echo 'set -Eeuo pipefail'
        declare -p HOTEL_ROOT STATE_FILE VERSIONS_FILE SSL_DIR BACKUP_ROOT NIGHTLY_ROOT KEEP_NIGHTLY LOCK_FILE
        declare -f nightly_backup
        echo 'nightly_backup'
    } > "$BACKUP_COMMAND"
    chmod 700 "$BACKUP_COMMAND"
    echo "0 4 * * * root $BACKUP_COMMAND >> $BACKUP_LOG 2>&1" > "$BACKUP_CRON"
    ok "Nightly backups at 04:00 in $NIGHTLY_ROOT (the newest $KEEP_NIGHTLY are kept)"
}

secure_server() {
    step "Securing the server (SSH, failed logins, updates, logs and backups)"
    protect_ssh_logins
    harden_ssh
    install_security_updates
    tune_network
    rotate_logs
    install_backup_command
}

# ---------------------------------------------------------------- Cloudflare API setup

# Each step: the function, the token permission it needs, and its name in messages.
CLOUDFLARE_STEPS=(
    "cloudflare_dns|Zone / DNS / Edit|DNS records"
    "cloudflare_certificate|Zone / SSL and Certificates / Edit|origin certificate"
    "cloudflare_settings|Zone / Zone Settings / Edit|SSL/TLS and security settings"
    "cloudflare_bot_fight_mode|Zone / Bot Management / Edit|Bot Fight Mode"
    "cloudflare_rate_limit|Zone / Zone WAF / Edit|rate limiting rule"
    "cloudflare_firewall_rules|Zone / Zone WAF / Edit|firewall rules"
)

cf_api() { # cf_api <method> <path> [JSON body]: sets CF_STATUS, CF_BODY and CF_ERROR; fails unless Cloudflare reports success
    local out errors args=(-sS --fail-with-body --max-time 30 -X "$1" -H 'Content-Type: application/json' -w '\n%{http_code}')
    if [ -n "${3:-}" ]; then args+=(--data-binary "$3"); fi
    errors=$(mktemp)
    # The token reaches curl through a pipe, never on its command line or in a file.
    out=$(curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_TOKEN") "$CF_API$2" 2> "$errors") || true
    CF_STATUS=${out##*$'\n'}
    CF_BODY=${out%"$CF_STATUS"}
    CF_ERROR=$(jq -r '[.errors[]?.message] | join(" ")' <<< "$CF_BODY" 2> /dev/null || true)
    if [ -z "$CF_ERROR" ]; then CF_ERROR=$(head -c 300 "$errors"); fi
    rm -f "$errors"
    echo "Cloudflare: $1 $2 -> ${CF_STATUS:-no answer}"
    [[ $CF_STATUS == 2?? ]] && [ "$(jq -r '.success' <<< "$CF_BODY" 2> /dev/null)" = true ]
}

cloudflare_fail() { CF_STATUS=local CF_ERROR=$1; return 1; }

cloudflare_dns() {
    local host record names=("$DOMAIN" "www.$DOMAIN")
    if [ "$WS_HOST" != "$DOMAIN" ] && [ "$WS_HOST" != "www.$DOMAIN" ]; then names+=("$WS_HOST"); fi
    for host in "${names[@]}"; do
        cf_api GET "/zones/$CF_ZONE/dns_records?name=$host&per_page=100" || return 1
        if jq -e '.result | any(.type == "CNAME")' <<< "$CF_BODY" > /dev/null; then
            cloudflare_fail "$host has a CNAME record. Delete it in Cloudflare (DNS > Records) and run the installer again."
            return 1
        fi
        if jq -e '.result | any(.type == "AAAA")' <<< "$CF_BODY" > /dev/null; then
            say "      ${yellow}$host also has an AAAA (IPv6) record. If it does not point to this server, delete it in Cloudflare (DNS > Records).${reset}"
        fi
        case $(jq '[.result[] | select(.type == "A")] | length' <<< "$CF_BODY") in
            0) cf_api POST "/zones/$CF_ZONE/dns_records" "$(jq -nc --arg name "$host" --arg ip "$SERVER_IP" '{type: "A", name: $name, content: $ip, proxied: true, ttl: 1}')" || return 1 ;;
            1)
                record=$(jq -c '.result[] | select(.type == "A")' <<< "$CF_BODY")
                if [ "$(jq -r '"\(.content) \(.proxied)"' <<< "$record")" != "$SERVER_IP true" ]; then
                    cf_api PATCH "/zones/$CF_ZONE/dns_records/$(jq -r .id <<< "$record")" "$(jq -nc --arg ip "$SERVER_IP" '{content: $ip, proxied: true}')" || return 1
                fi
                ;;
            *)
                cloudflare_fail "$host has more than one A record. Keep only one in Cloudflare (DNS > Records) and run the installer again."
                return 1
                ;;
        esac
    done
    ok "DNS: ${names[*]} point to $SERVER_IP through Cloudflare (proxied)"
}

origin_certificate_valid() { # origin_certificate_valid <cert> <key> <Origin CA root>: signed by Cloudflare, for every hotel name, valid 30 more days
    local host
    [ -s "$1" ] && [ -s "$2" ] || return 1
    openssl x509 -in "$1" -noout -checkend 2592000 > /dev/null || return 1
    for host in "$DOMAIN" "www.$DOMAIN" "$WS_HOST"; do
        openssl verify -CAfile "$3" -purpose sslserver -verify_hostname "$host" "$1" > /dev/null 2>&1 || return 1
    done
    [ "$(openssl pkey -in "$2" -pubout 2> /dev/null)" = "$(openssl x509 -in "$1" -pubkey -noout)" ]
}

certificate_expiry() { date -u -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%Y-%m-%d; }

cloudflare_certificate() {
    local work backup hosts=("$DOMAIN" "*.$DOMAIN")
    # The wildcard covers one level below the domain only.
    if [[ $WS_HOST == *."$DOMAIN" && ${WS_HOST%."$DOMAIN"} == *.* ]]; then hosts+=("$WS_HOST"); fi
    work=$(mktemp -d)
    if ! curl -fsS --max-time 20 "$ORIGIN_CA_ROOT_URL" -o "$work/root.pem" || ! openssl x509 -in "$work/root.pem" -noout 2> /dev/null; then
        rm -rf "$work"
        cloudflare_fail "Could not download Cloudflare's Origin CA root certificate. Try again later."
        return 1
    fi
    if origin_certificate_valid "$SSL_DIR/cert.pem" "$SSL_DIR/key.pem" "$work/root.pem"; then
        rm -rf "$work"
        CLOUDFLARE_CERT_EXPIRES=$(certificate_expiry "$SSL_DIR/cert.pem")
        ok "Origin certificate: already installed, valid until $CLOUDFLARE_CERT_EXPIRES"
        return 0
    fi
    # The private key is made here and never leaves the server; Cloudflare only signs the request.
    if ! openssl req -new -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/request.csr" -subj "/CN=$DOMAIN" 2> /dev/null; then
        rm -rf "$work"
        cloudflare_fail "openssl could not create the certificate request."
        return 1
    fi
    if ! cf_api POST /certificates "$(jq -nc --rawfile csr "$work/request.csr" '{hostnames: $ARGS.positional, requested_validity: 5475, request_type: "origin-rsa", csr: $csr}' --args "${hosts[@]}")"; then
        rm -rf "$work"
        return 1
    fi
    jq -r '.result.certificate' <<< "$CF_BODY" > "$work/cert.pem"
    if ! origin_certificate_valid "$work/cert.pem" "$work/key.pem" "$work/root.pem"; then
        rm -rf "$work"
        cloudflare_fail "The certificate from Cloudflare did not pass the checks, so the current certificate stays."
        return 1
    fi
    backup=$(mktemp -d "$SSL_DIR/backup.XXXXXX")
    cp -p "$SSL_DIR/cert.pem" "$SSL_DIR/key.pem" "$backup/"
    if install -m 600 "$work/key.pem" "$SSL_DIR/key.pem" && install -m 644 "$work/cert.pem" "$SSL_DIR/cert.pem" &&
        nginx -t && systemctl reload nginx; then
        rm -rf "$work"
        CLOUDFLARE_CERT_EXPIRES=$(certificate_expiry "$SSL_DIR/cert.pem")
        ok "Origin certificate installed, valid until $CLOUDFLARE_CERT_EXPIRES (previous one saved in $backup)"
        return 0
    fi
    cp -p "$backup/cert.pem" "$backup/key.pem" "$SSL_DIR/"
    nginx -t && systemctl reload nginx
    rm -rf "$work"
    cloudflare_fail "nginx did not accept the new certificate, so the previous one is back. See $LOG."
}

cloudflare_settings() {
    local setting
    # Full (strict) comes after the certificate step, so Cloudflare never meets the self-signed one.
    for setting in ssl=strict always_use_https=on websockets=on min_tls_version=1.2 browser_check=on; do
        cf_api PATCH "/zones/$CF_ZONE/settings/${setting%%=*}" "$(jq -nc --arg value "${setting#*=}" '{value: $value}')" || return 1
    done
    # The security level also switches Under Attack mode, which the owner may have turned on.
    cf_api GET "/zones/$CF_ZONE/settings/security_level" || return 1
    if [ "$(jq -r .result.value <<< "$CF_BODY")" != under_attack ]; then
        cf_api PATCH "/zones/$CF_ZONE/settings/security_level" '{"value":"medium"}' || return 1
    fi
    ok "SSL/TLS: Full (strict), Always Use HTTPS, TLS 1.2 or newer, WebSockets, Browser Integrity Check, security level medium"
}

cloudflare_bot_fight_mode() {
    cf_api PUT "/zones/$CF_ZONE/bot_management" '{"fight_mode":true}' || return 1
    ok "Bot Fight Mode on"
}

cloudflare_rules() { # cloudflare_rules <phase> <rule JSON>...: adds each rule, or updates the rule with the same description
    local phase=$1 ruleset rule id
    shift
    if ! cf_api GET "/zones/$CF_ZONE/rulesets/phases/$phase/entrypoint"; then
        [ "$CF_STATUS" = 404 ] || return 1
        cf_api PUT "/zones/$CF_ZONE/rulesets/phases/$phase/entrypoint" "$(printf '%s\n' "$@" | jq -s '{rules: .}')"
        return
    fi
    ruleset=$(jq -r .result.id <<< "$CF_BODY")
    local rules=$CF_BODY
    for rule in "$@"; do
        id=$(jq -r --arg description "$(jq -r .description <<< "$rule")" 'first(.result.rules[]? | select(.description == $description) | .id) // empty' <<< "$rules")
        if [ -n "$id" ]; then
            cf_api PATCH "/zones/$CF_ZONE/rulesets/$ruleset/rules/$id" "$rule" || return 1
        else
            cf_api POST "/zones/$CF_ZONE/rulesets/$ruleset/rules" "$rule" || return 1
        fi
    done
}

cloudflare_rate_limit() {
    # The Free plan counts by path and IP only, over 10 seconds, so opening these pages counts too.
    local expression='(http.request.uri.path in {"/login" "/register" "/forgot-password" "/two-factor-challenge" "/housekeeping/login"} or http.request.uri.path wildcard "/reset-password/*")'
    cloudflare_rules http_ratelimit "$(jq -nc --arg expression "$expression" '{description: "PlusEMU: limit sign-in and registration", expression: $expression, action: "block", enabled: true,
        ratelimit: {characteristics: ["cf.colo.id", "ip.src"], period: 10, requests_per_period: 10, mitigation_timeout: 10}}')" || return 1
    ok "Rate limit: 10 sign-in, registration and password reset requests per 10 seconds per visitor"
}

cloudflare_firewall_rules() {
    local game housekeeping
    game="(http.host eq \"$WS_HOST\" and http.request.uri.path eq \"$WS_PATH\" and not any(http.request.headers[\"origin\"][*] eq \"https://$DOMAIN\"))"
    housekeeping="(http.host eq \"$DOMAIN\" and (http.request.uri.path eq \"/housekeeping\" or http.request.uri.path wildcard \"/housekeeping/*\"))"
    cloudflare_rules http_request_firewall_custom \
        "$(jq -nc --arg expression "$game" '{description: "PlusEMU: game connection only from the hotel website", expression: $expression, action: "block", enabled: true}')" \
        "$(jq -nc --arg expression "$housekeeping" '{description: "PlusEMU: check visitors before housekeeping", expression: $expression, action: "managed_challenge", enabled: true}')" || return 1
    ok "Firewall rules: the game connects only from https://$DOMAIN, and housekeeping visitors get a Cloudflare check first"
}

cloudflare_setup() { # runs every step with CLOUDFLARE_TOKEN; on failure CLOUDFLARE_ERROR says what failed
    local entry name permission label
    if [ "$WS_HOST" != "$DOMAIN" ] && [[ $WS_HOST != *."$DOMAIN" ]]; then
        CLOUDFLARE_ERROR="The game connection uses another domain ($WS_HOST), so the installer cannot set it up. Follow the manual steps in the guide."
        return 1
    fi
    if ! cf_api GET /user/tokens/verify; then
        CLOUDFLARE_ERROR="Cloudflare did not accept the token. Copy it again from My Profile > API Tokens. Cloudflare said: $CF_ERROR"
        return 1
    fi
    if ! cf_api GET "/zones?name=$DOMAIN"; then
        CLOUDFLARE_ERROR="Could not look up $DOMAIN. The token needs the permission Zone / Zone / Read. Cloudflare said: $CF_ERROR"
        return 1
    fi
    CF_ZONE=$(jq -r '.result[0].id // empty' <<< "$CF_BODY")
    if [ -z "$CF_ZONE" ]; then
        CLOUDFLARE_ERROR="Cloudflare has no site $DOMAIN that this token can use. Add the site to Cloudflare and change the nameservers (guide steps 1 and 2). Check that the token's Zone Resources include $DOMAIN."
        return 1
    fi
    if [ "$(jq -r '.result[0].status' <<< "$CF_BODY")" != active ]; then
        say "      ${yellow}Cloudflare still waits for the nameserver change of $DOMAIN. The settings work as soon as Cloudflare shows the site as Active.${reset}"
    fi
    for entry in "${CLOUDFLARE_STEPS[@]}"; do
        IFS='|' read -r name permission label <<< "$entry"
        if ! "$name"; then
            case $CF_STATUS in
                401 | 403) CLOUDFLARE_ERROR="The $label step failed: the token lacks the permission $permission. Add it in My Profile > API Tokens > Edit, then try again. Cloudflare said: $CF_ERROR" ;;
                local) CLOUDFLARE_ERROR="The $label step failed: $CF_ERROR" ;;
                *) CLOUDFLARE_ERROR="The $label step failed. Cloudflare said: ${CF_ERROR:-no answer}" ;;
            esac
            return 1
        fi
    done
}

read_secret() { # read_secret <variable> <question>: a hidden answer from the terminal; fails without one
    local answer
    [ "${PLUSEMU_YES:-0}" != 1 ] || return 1
    printf '  %s: ' "$2" >&3
    IFS= read -rs answer < "$TTY" 2> /dev/null || return 1
    printf '\n' >&3
    printf -v "$1" '%s' "${answer//[[:space:]]/}"
}

connect_cloudflare() {
    step "Connecting your hotel to Cloudflare"
    # A trace (bash -x) would print the token, so it stays off until the token is gone.
    local trace=${-//[^x]/} token=${PLUSEMU_CLOUDFLARE_TOKEN:-} question retry
    { set +x; } 2> /dev/null
    unset PLUSEMU_CLOUDFLARE_TOKEN
    CLOUDFLARE_ERROR=
    say "  Your setup guide: ${bold}${cyan}http://$SERVER_IP/$GUIDE_TOKEN/${reset}"
    say "  To let the installer set up Cloudflare for you, follow the guide's section \"Connect Cloudflare automatically\"."
    question="Paste your Cloudflare API token, or press Enter to skip and follow the manual steps in the guide"
    if [ "${CLOUDFLARE_SETUP:-}" = "done" ]; then
        say "  Cloudflare is already connected."
        question="Press Enter to keep it, or paste a token to run it again"
    fi
    while [ -n "$token" ] || read_secret token "$question"; do
        [ -n "$token" ] || break
        CLOUDFLARE_TOKEN=$token
        CLOUDFLARE_ERROR=
        if cloudflare_setup; then
            CLOUDFLARE_SETUP="done"
            save_state
            ok "Cloudflare is connected. Reload the setup guide to see what was set up."
            break
        fi
        say "      ${yellow}$CLOUDFLARE_ERROR${reset}"
        token=
        question="Fix it and press Enter to try again, paste a new token, or type skip"
        read_secret retry "$question" || break
        case $retry in
            skip) break ;;
            '') token=$CLOUDFLARE_TOKEN ;;
            *) token=$retry ;;
        esac
    done
    unset CLOUDFLARE_TOKEN token retry
    if [ -n "$trace" ]; then set -x; fi
    if [ -n "$CLOUDFLARE_ERROR" ] && [ "${CLOUDFLARE_SETUP:-}" = "done" ]; then
        say "      ${yellow}The earlier Cloudflare setup stays as it was.${reset}"
    elif [ -n "$CLOUDFLARE_ERROR" ]; then
        say "      ${yellow}The installer did not finish the Cloudflare setup. Follow the manual steps in the guide.${reset}"
    elif [ "${CLOUDFLARE_SETUP:-}" != "done" ]; then
        say "      Skipped. Follow the manual steps in the guide."
    fi
    render_guide
}

html_escape() { local text=${1//&/&amp;}; text=${text//</&lt;}; text=${text//>/&gt;}; printf '%s' "${text//\"/&quot;}"; }

write_guide() {
    step "Writing your setup guide"
    render_guide
    ok "Guide written"
}

# shellcheck disable=SC2034 # the {{KEY}} values are read by render() through ${!key}
render_guide() { # the guide in its manual form, or in its connected form after the Cloudflare step
    mkdir -p "$HOTEL_ROOT/setup-guide"
    CLOUDFLARE_STATUS="" MANUAL_START="" MANUAL_END="" CLOUDFLARE_ERROR_HTML="" GAME_ADDRESS_ITEM=""
    GUIDE_INTRO='Now connect <b>{{DOMAIN}}</b> through Cloudflare and install its origin certificate.'
    if [ "${CLOUDFLARE_SETUP:-}" = "done" ]; then
        GUIDE_INTRO='Cloudflare is connected. Check your hotel below.'
        CLOUDFLARE_STATUS=$(< "$TEMPLATES/cloudflare-connected.html")
        MANUAL_START='<details class="card manual"><summary>If you need to do this by hand</summary>'
        MANUAL_END='</details>'
    fi
    if [ -n "${CLOUDFLARE_ERROR:-}" ]; then
        CLOUDFLARE_STATUS+=$(< "$TEMPLATES/cloudflare-failed.html")
        CLOUDFLARE_ERROR_HTML=$(html_escape "$CLOUDFLARE_ERROR")
    fi
    CERTIFICATE_EXPIRES=${CLOUDFLARE_CERT_EXPIRES:-}
    CREDENTIALS_FILE=$STATE_FILE
    RESTART_COMMAND="sudo systemctl restart plusemu"
    LOG_COMMAND="sudo journalctl -u plusemu -f"
    GUIDE_MODE_TITLE=${GUIDE_MODE^}
    GUIDE_MODE_DETAILS=$(< "$TEMPLATES/guide-$GUIDE_MODE.html")
    if [ "$WS_HOST" != "$DOMAIN" ] && [ "$WS_HOST" != "www.$DOMAIN" ]; then
        GAME_ADDRESS_ITEM=", the game address <code>$WS_HOST</code>"
    fi
    WS_DNS_ROW=""
    if [ "$WS_HOST" != "$DOMAIN" ]; then
        WS_DNS_ROW="<tr><td>A</td><td><code>${WS_HOST%."$DOMAIN"}</code></td><td><code>$SERVER_IP</code></td><td>Proxied (orange cloud)</td></tr>"
    fi
    render "$TEMPLATES/setup-guide.html" "$HOTEL_ROOT/setup-guide/index.html" "$TEMPLATES/certificate-linux.html"
}

finish() {
    systemctl is-active --quiet plusemu || systemctl restart plusemu
    say ""
    say "${green}${bold}🎉 Your hotel is installed!${reset}"
    say ""
    if [ "${CLOUDFLARE_SETUP:-}" = "done" ]; then
        say "  Cloudflare is connected. Open https://$DOMAIN, log in and enter the hotel to check it."
        say "  The setup guide shows what the installer set up and what to check:"
    else
        say "  One last part: connect your domain and install your Cloudflare origin certificate."
        say "  Open this page in your browser for easy step-by-step instructions:"
    fi
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
    say "  Nightly backups of the database and your settings: $NIGHTLY_ROOT"
    if [ "${SSH_PASSWORDS:-}" = on ]; then
        say "  ${yellow}SSH password login is still on.${reset} To turn it off, add your SSH key, log in with it and run the installer again."
    fi
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
    local old=$1 new=$2 rendered file example
    # Hashed bundles belong to one release; the other files the release lacks are the hotel's.
    carry_over "$old" "$new" '^(src/)?assets/'
    rendered=$(mktemp -d)
    # The release ships the defaults of every setting it knows; the hotel's own files replace them below.
    mkdir -p "$rendered/shipped"
    for file in renderer-config.json:renderer-config.json.example.json ui-config.json:ui-config.example; do
        example=$new/configuration/${file#*:}
        if [ -f "$example" ] && jq empty "$example" 2> /dev/null; then cp "$example" "$rendered/shipped/${file%%:*}"; fi
    done
    if [ -d "$old/configuration" ]; then
        mkdir -p "$new/configuration"
        cp -a "$old/configuration/." "$new/configuration/"
    fi
    write_client_config "$rendered"
    for file in renderer-config.json ui-config.json client-mode.json; do
        if [ -f "$rendered/shipped/$file" ]; then
            jq -s '.[0] * .[1]' "$rendered/shipped/$file" "$rendered/$file" > "$rendered/$file.defaults"
            mv "$rendered/$file.defaults" "$rendered/$file"
        fi
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

create_snapshot() { # create_snapshot [with the hotel files: 0|1]: sets SNAPSHOT to a new backup
    SNAPSHOT=$BACKUP_ROOT/$(date -u +%Y%m%d-%H%M%S-%N)
    local partial=$SNAPSHOT.partial
    install -d -m 700 "$BACKUP_ROOT"
    install -d -m 700 "$partial"
    mariadb-dump --protocol=socket -uroot --single-transaction --routines --triggers --events plus | gzip > "$partial/database.sql.gz"
    # The emulator's own database backups stay in place and are not copied again.
    # Exit code 1 only means a file changed while it was read, for example a log of the running emulator.
    tar -C "$HOTEL_ROOT" --exclude=emulator/backups --warning=no-file-changed -czf "$partial/files.tar.gz" emulator client || [ "$?" = 1 ]
    if [ "${1:-0}" = 1 ]; then tar -C "$HOTEL_ROOT" -cf "$partial/hotel-files.tar" hotel-files; fi
    if [ -f "$VERSIONS_FILE" ]; then cp "$VERSIONS_FILE" "$partial/versions.env"; fi
    mv "$partial" "$SNAPSHOT"
}

restore_snapshot() { # restore_snapshot <backup dir> <restore the database: 0|1>
    local snapshot=$1 staging=$HOTEL_ROOT/.restore
    systemctl stop plusemu || return 1
    rm -rf "$staging" && mkdir -p "$staging" || return 1
    tar xzf "$snapshot/files.tar.gz" -C "$staging" || return 1
    if [ -f "$snapshot/hotel-files.tar" ]; then
        tar xf "$snapshot/hotel-files.tar" -C "$staging" || return 1
        rm -rf "$HOTEL_ROOT/hotel-files" && mv "$staging/hotel-files" "$HOTEL_ROOT/" || return 1
    fi
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
    # Snapshots are named by their time; the gamedata-* copies of the assets-only update are not snapshots.
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort | head -n -"$KEEP_BACKUPS" | xargs -r -d '\n' rm -rf
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

require_update_space() { # require_update_space [with the hotel files: 0|1]
    # Staged copies and the backup of the files, plus two dumps of the database: the backup's and the emulator's own.
    local files_mb database_mb hotel_files_mb=0
    files_mb=$(du -smc --exclude=emulator/backups "$HOTEL_ROOT/emulator" "$HOTEL_ROOT/client" | tail -1 | cut -f1)
    database_mb=$(sql -N -e "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1048576), 0) FROM information_schema.tables WHERE table_schema = 'plus'" < /dev/null)
    # Their backup, the downloaded pack and the files it adds.
    if [ "${1:-0}" = 1 ] && [ -d "$HOTEL_ROOT/hotel-files" ]; then hotel_files_mb=$(du -sm "$HOTEL_ROOT/hotel-files" | cut -f1); fi
    require_free_space $(((files_mb * 3 + ${database_mb:-0} * 2 + hotel_files_mb * 3) / 1024 + 1)) "$HOTEL_ROOT"
}

confirm_update() { # confirm_update <question>
    [ "${PLUSEMU_YES:-0}" != 1 ] || return 0
    local go
    ask go "$1 (y/n)" "y"
    [[ $go =~ ^[Yy] ]] || die "Cancelled. Nothing was changed."
}

add_hotel_files() { # add_hotel_files <check: 0|1>: the stock files the hotel lacks, without stopping the emulator
    local files=$HOTEL_ROOT/hotel-files latest
    latest=$(pack_version) || die "Could not find the latest hotel files. Check the server's internet connection."
    say ""
    say "${bold}PlusEMU hotel files update${reset}"
    if [ "$ASSETS_VERSION" = "$latest" ]; then
        say "  Hotel files:        $ASSETS_VERSION (up to date)"
        return
    fi
    say "  Hotel files:        $ASSETS_VERSION -> ${bold}$latest${reset} (about 550 MB)"
    if [ "$1" = 1 ]; then
        say ""
        say "  Install them with: sudo plusemu-update --assets"
        return
    fi
    say "  Stock files the hotel lacks are added; files it already has stay as they are."
    say "  The gamedata index (clothing, effects, products, texts) is replaced; the old one is kept in $BACKUP_ROOT."
    require_free_space 3 "$HOTEL_ROOT"
    WORK=$(mktemp -d "$HOTEL_ROOT/.update.XXXXXX")
    fetch_checked "${ASSET_PACK_URL%/*}" "${ASSET_PACK_URL##*/}" "$WORK/hotel-files.tar.gz" || die "Could not download the hotel files. Nothing was changed. Try again later."
    mkdir -p "$files"
    local old_gamedata=
    if [ -d "$files/gamedata" ]; then
        install -d -m 700 "$BACKUP_ROOT"
        old_gamedata=$BACKUP_ROOT/gamedata-$ASSETS_VERSION
        rm -rf "$old_gamedata"
        mv "$files/gamedata" "$old_gamedata"
    fi
    if ! tar xzf "$WORK/hotel-files.tar.gz" --no-same-owner --skip-old-files -C "$files"; then
        # The installed index goes back, so the hotel keeps working.
        if [ -n "$old_gamedata" ]; then rm -rf "$files/gamedata" && mv "$old_gamedata" "$files/gamedata"; fi
        die "Unpacking the hotel files failed. The hotel files were not changed. Try again later."
    fi
    rm -f "$files/.complete"
    ASSETS_VERSION=$latest
    save_versions
    say ""
    say "${green}${bold}✓ Hotel files $latest installed.${reset} The emulator kept running."
    say "  Your previous gamedata files: $BACKUP_ROOT/gamedata-* (copy edited texts back by hand if you need them)."
    say "  New clothing also needs the emulator's Config/figuredata.xml, which comes with the full update: sudo plusemu-update"
    say ""
}

rollback_update() {
    local target name versions="unknown versions" with_hotel_files=0
    target=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' ! -name '*.partial' 2> /dev/null | sort | tail -1)
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
    if [ -f "$target/hotel-files.tar" ]; then
        with_hotel_files=1
        say "  ${yellow}The hotel files go back to that moment as well.${reset}"
    fi
    confirm_update "Restore this backup?"

    require_update_space "$with_hotel_files"
    TOTAL_STEPS=2
    step "Backing up the current state"
    systemctl stop plusemu
    EMULATOR_STOPPED=1
    create_snapshot "$with_hotel_files"
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
    local check=0 rollback=0 assets_only=0 arg latest_emulator latest_client latest_assets
    local update_emulator=0 update_client=0 update_assets=0
    for arg in "$@"; do
        case "$arg" in
            --check) check=1 ;;
            --yes) PLUSEMU_YES=1 ;;
            --assets) assets_only=1 ;;
            --with-assets) ;; # the hotel files are always updated now; older guides still name this option
            --rollback) rollback=1 ;;
            *) die "Unknown option: $arg. Usage: plusemu-update [--check] [--yes] [--assets] [--rollback]" ;;
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
    EMULATOR_VERSION=unknown CLIENT_VERSION=unknown ASSETS_VERSION=unknown
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
    if [ "$assets_only" = 1 ]; then
        add_hotel_files "$check"
        return
    fi

    latest_emulator=$(release_version "$EMULATOR_REPO" "$EMULATOR_URL") || die "Could not find the latest PlusEMU release. Check the server's internet connection."
    latest_client=$(release_version "$CLIENT_REPO" "$CLIENT_URL") || die "Could not find the latest Volt release. Check the server's internet connection."
    if [ "$EMULATOR_VERSION" != "$latest_emulator" ]; then update_emulator=1; fi
    if [ "$CLIENT_VERSION" != "$latest_client" ]; then update_client=1; fi
    latest_assets=$(pack_version) || die "Could not find the latest hotel files. Check the server's internet connection."
    if [ "$ASSETS_VERSION" != "$latest_assets" ]; then update_assets=1; fi
    say ""
    say "${bold}PlusEMU hotel update${reset}"
    if [ "$update_emulator" = 1 ]; then
        say "  Emulator (PlusEMU): $EMULATOR_VERSION -> ${bold}$latest_emulator${reset}"
    elif [ "$update_assets" = 1 ]; then
        # The emulator release carries the clothing data (Config/figuredata.xml) that matches the stock hotel files.
        update_emulator=1
        say "  Emulator (PlusEMU): $EMULATOR_VERSION (reinstalled to load the new clothing data)"
    else
        say "  Emulator (PlusEMU): $EMULATOR_VERSION (up to date)"
    fi
    if [ "$update_client" = 1 ]; then
        say "  Client (Volt):      $CLIENT_VERSION -> ${bold}$latest_client${reset}"
    else
        say "  Client (Volt):      $CLIENT_VERSION (up to date)"
    fi
    if [ "$update_assets" = 1 ]; then
        say "  Hotel files:        $ASSETS_VERSION -> ${bold}$latest_assets${reset} (about 550 MB)"
    else
        say "  Hotel files:        $ASSETS_VERSION (up to date)"
    fi
    if [ "$update_emulator" = 0 ] && [ "$update_client" = 0 ] && [ "$update_assets" = 0 ]; then
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
    if [ "$update_assets" = 1 ]; then
        say "  Stock hotel files are replaced by the new ones. Files you added to hotel-files are kept."
    fi
    if [ "$update_emulator" = 1 ]; then say "  Players are disconnected for about a minute."; fi
    confirm_update "Update now?"

    require_update_space "$update_assets"
    WORK=$(mktemp -d "$HOTEL_ROOT/.update.XXXXXX")
    TOTAL_STEPS=4

    step "Downloading the new versions"
    if [ "$update_emulator" = 1 ]; then
        stage_emulator "$latest_emulator" "$WORK/emulator"
        if [ "$update_assets" = 1 ]; then cp "$WORK/emulator/Config/figuredata.xml" "$WORK/figuredata.xml"; fi
        keep_emulator_files "$HOTEL_ROOT/emulator" "$WORK/emulator"
        if [ "$update_assets" = 1 ]; then
            mv "$WORK/figuredata.xml" "$WORK/emulator/Config/figuredata.xml"
            chown plusemu:plusemu "$WORK/emulator/Config/figuredata.xml"
        fi
        ok "PlusEMU $latest_emulator (your settings and added files are kept)"
    fi
    if [ "$update_client" = 1 ]; then
        load_installer_files
        derive_settings
        stage_client "$latest_client" "$WORK/client"
        keep_client_files "$HOTEL_ROOT/client" "$WORK/client"
        ok "Volt $latest_client (your configuration and added files are kept)"
    fi
    if [ "$update_assets" = 1 ]; then
        fetch_checked "${ASSET_PACK_URL%/*}" "${ASSET_PACK_URL##*/}" "$WORK/hotel-files.tar.gz" || die "Could not download the hotel files. Nothing was changed. Try again later."
        ok "Hotel files $latest_assets"
    fi

    step "Backing up your hotel"
    if [ "$update_emulator" = 1 ]; then
        systemctl stop plusemu
        EMULATOR_STOPPED=1
    fi
    if [ "$update_assets" = 1 ]; then mkdir -p "$HOTEL_ROOT/hotel-files"; fi
    create_snapshot "$update_assets"
    ok "Your hotel is saved in $SNAPSHOT"
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
    if [ "$update_assets" = 1 ]; then
        tar xzf "$WORK/hotel-files.tar.gz" --no-same-owner -C "$HOTEL_ROOT/hotel-files"
        rm -f "$HOTEL_ROOT/hotel-files/.complete" # the marker of installers that never refreshed the pack
        ok "Hotel files $latest_assets installed"
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
    if [ "$update_assets" = 1 ]; then ASSETS_VERSION=$latest_assets; fi
    save_versions
    prune_snapshots
    install_update_command

    say ""
    say "${green}${bold}✓ Your hotel is up to date.${reset}"
    say "  Emulator: $EMULATOR_VERSION    Client: $CLIENT_VERSION    Hotel files: $ASSETS_VERSION"
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
    secure_server
    write_guide
    install_update_command
    connect_cloudflare
    finish
}

main "$@"

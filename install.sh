#!/usr/bin/env bash
# PlusEMU hotel installer for Debian 12/13 and Ubuntu 22.04/24.04/26.04.
#
#   curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh | sudo bash
#
# Installs and wires together: PlusEMU (emulator) and Octane (client) from their
# latest GitHub releases, Atom CMS (website), MariaDB, PHP, nginx and the hotel
# files. Everything is self-hosted on this server; Cloudflare sits in front.
# Safe to run again: settings are reused and finished steps are kept.
#
# Unattended runs can preset the answers: PLUSEMU_DOMAIN, PLUSEMU_WS_URL,
# PLUSEMU_HOTEL_NAME, PLUSEMU_ADMIN_USER, PLUSEMU_ADMIN_EMAIL, PLUSEMU_YES=1.
set -Eeuo pipefail
shopt -u patsub_replacement 2> /dev/null || true # bash 5.2 would expand "&" in template values

INSTALLER_REPO=${INSTALLER_REPO:-plus-emulator/plusemu-installer}
INSTALLER_REF=${INSTALLER_REF:-main}
ASSET_PACK_URL=${ASSET_PACK_URL:-https://github.com/plus-emulator/plusemu-installer/releases/latest/download/hotel-files.tar.gz}
EMULATOR_URL=${EMULATOR_URL:-https://github.com/plus-emulator/PlusEMU/releases/latest/download/plusemu-linux-ARCH.tar.gz}
CLIENT_URL=${CLIENT_URL:-https://github.com/plus-emulator/Octane/releases/latest/download/octane-client.zip}
ATOM_REPO=${ATOM_REPO:-https://github.com/atom-projects/atom-cms.git}
ATOM_BRANCH=${ATOM_BRANCH:-dev}

HOTEL_ROOT=/var/www/hotel
STATE_FILE=/etc/plusemu/hotel.env
LOG=/var/log/plusemu-install.log
PHP=8.5
NODE_MAJOR=22
TOTAL_STEPS=9
STEP=0

# ---------------------------------------------------------------- output

exec 3>&1
bold=$'\e[1m' green=$'\e[32m' red=$'\e[31m' yellow=$'\e[33m' cyan=$'\e[36m' reset=$'\e[0m'

say() { printf '%s\n' "$*" >&3; printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g'; }
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
    printf '%s\n' "$last" | sed 's/^/    /' >&3
    say ""
    say "  Full log: ${bold}$LOG${reset}"
    say "  Fix the problem (or ask for help on DevBest with the log), then run the installer again."
    say "  It continues where it stopped."
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

render() { # render <template> <output>: replace {{KEY}} with the shell variable KEY
    local content key
    content=$(< "$1")
    for key in DOMAIN SOCKET_URL SERVER_IP WS_HOST HOTEL_NAME ADMIN_USER ADMIN_EMAIL \
        CREDENTIALS_FILE RESTART_COMMAND LOG_COMMAND WS_DNS_ROW; do
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

clone() { # clone <repo> <branch> <dir>: fresh shallow clone, or fast-forward an existing one
    if [ -d "$3/.git" ]; then
        git -C "$3" fetch --depth 1 origin "$2" && git -C "$3" reset --hard FETCH_HEAD
    else
        rm -rf "$3"
        git clone --depth 1 --branch "$2" "$1" "$3"
    fi
}

sql() { mariadb --protocol=socket -uroot "$@"; }

save_state() {
    install -d -m 700 /etc/plusemu
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
EOF
    umask 022
}

# ---------------------------------------------------------------- steps

preflight() {
    [ "$(id -u)" -eq 0 ] || die "Please run the installer as root: curl -fsSL <url> | sudo bash"
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
    local free_gb
    free_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
    [ "$free_gb" -ge 10 ] || die "Not enough disk space: ${free_gb} GB free, at least 10 GB needed."
    : > "$LOG"
    chmod 600 "$LOG"
}

load_installer_files() {
    # Templates ship next to this script. When run through `curl | bash` there
    # is no script directory, so the matching installer release is downloaded.
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

ask_questions() {
    say ""
    say "${bold}Welcome to the PlusEMU hotel installer!${reset}"
    say "This sets up your emulator, client and website on this server in about 10 minutes."
    say ""

    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        if [ -z "${GUIDE_TOKEN:-}" ]; then GUIDE_TOKEN=$(random_secret 12) && save_state; fi
        say "Found the settings of an earlier run for ${bold}$DOMAIN${reset}; continuing that installation."
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
    ADMIN_PASSWORD=$(random_secret 16)
    DB_PASSWORD=$(random_secret 32)
    GUIDE_TOKEN=$(random_secret 12)

    say ""
    say "  Website:    ${bold}https://$DOMAIN${reset}"
    say "  WebSocket:  ${bold}$WS_URL${reset}"
    say "  Hotel name: ${bold}$HOTEL_NAME${reset}"
    say "  Admin:      ${bold}$ADMIN_USER${reset} ($ADMIN_EMAIL)"
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
    step "Downloading PlusEMU, the Octane client and Atom CMS"
    # A re-run repairs and keeps the installed releases: a newer emulator may need
    # database changes this installer does not apply.
    local out=$HOTEL_ROOT/emulator
    if [ -x "$out/Plus Emulator" ]; then
        ok "PlusEMU (already installed)"
    else
        mkdir -p "$out"
        curl -fsSL --retry 3 "${EMULATOR_URL//ARCH/$ARCH}" | tar xz --no-same-owner -C "$out"
        ok "PlusEMU (latest release)"
    fi

    local client=$HOTEL_ROOT/client zip
    if [ -f "$client/index.html" ]; then
        ok "Octane client (already installed)"
        clone "$ATOM_REPO" "$ATOM_BRANCH" "$HOTEL_ROOT/cms"
        ok "Atom CMS ($ATOM_BRANCH)"
        return
    fi
    zip=$(mktemp)
    curl -fsSL --retry 3 "$CLIENT_URL" -o "$zip"
    rm -rf "$client.new" && mkdir -p "$client.new"
    unzip -q "$zip" -d "$client.new"
    rm -f "$zip"
    render "$TEMPLATES/renderer-config.json" "$client.new/configuration/renderer-config.json"
    render "$TEMPLATES/ui-config.json" "$client.new/configuration/ui-config.json"
    render "$TEMPLATES/client-mode.json" "$client.new/configuration/client-mode.json"
    echo '[]' > "$client.new/configuration/news.json"
    cp "$client.new/configuration/adsense.example" "$client.new/configuration/adsense.json"
    rm -rf "$client.old"
    if [ -d "$client" ]; then mv "$client" "$client.old"; fi
    mv "$client.new" "$client"
    rm -rf "$client.old"
    ok "Octane client (latest release)"

    clone "$ATOM_REPO" "$ATOM_BRANCH" "$HOTEL_ROOT/cms"
    ok "Atom CMS ($ATOM_BRANCH)"
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
    jq --arg pass "$DB_PASSWORD" --arg furnidata "$HOTEL_ROOT/hotel-files/gamedata/FurnitureData.json" '
        .Database.Hostname = "127.0.0.1" | .Database.Port = 3306 | .Database.Username = "hotel"
        | .Database.Password = $pass | .Database.Name = "plus"
        | .Flash.Hostname = "127.0.0.1"
        | .Nitro.Hostname = "127.0.0.1" | .Nitro.Port = 2096 | .Nitro.Name = "Octane"
        | .Rcon.Hostname = "127.0.0.1" | .Rcon.Port = 30001 | .Rcon.AllowedAddresses = ["127.0.0.1", "localhost"]
        | .AuthApi.Enabled = false | .AuthApi.Hostname = "127.0.0.1"
        | .FurniEditor.FurnidataPath = $furnidata' "$config" > "$config.new"
    mv "$config.new" "$config"
    chmod 600 "$config"
    chown -R plusemu:plusemu "$out"
    chown plusemu "$HOTEL_ROOT/hotel-files/gamedata/FurnitureData.json"

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
    for _ in $(seq 1 60); do
        if curl -fsS http://127.0.0.1:8080/api/health > /dev/null 2>&1; then
            ok "The emulator is running (service: plusemu)"
            return
        fi
        sleep 2
    done
    journalctl -u plusemu -n 40 --no-pager
    die "The emulator didn't start. See: journalctl -u plusemu -n 100"
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
        # Cloudflare (SSL mode "Full") encrypts to this certificate; visitors see Cloudflare's.
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

    # The game client (Octane). Hashed bundles never change; config is re-read every load.
    location /client/ {
        alias $HOTEL_ROOT/client/;
        index index.html;
        location ~ ^/client/(src/)?assets/ { expires max; }
        location ~ ^/client/(index\.html|configuration/) { expires -1; }
    }
    location = /client { return 301 /client/; }
    location = /ads.txt { alias $HOTEL_ROOT/client/ads.txt; }

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
    WS_DNS_ROW=""
    if [ "$WS_HOST" != "$DOMAIN" ]; then
        WS_DNS_ROW="<tr><td>A</td><td><code>${WS_HOST%."$DOMAIN"}</code></td><td><code>$SERVER_IP</code></td><td>Proxied (orange cloud)</td></tr>"
    fi
    render "$TEMPLATES/setup-guide.html" "$HOTEL_ROOT/setup-guide/index.html"
    ok "Guide written"
}

finish() {
    systemctl is-active --quiet plusemu || systemctl restart plusemu
    say ""
    say "${green}${bold}🎉 Your hotel is installed!${reset}"
    say ""
    say "  One last part: connect your domain through Cloudflare (about 5 minutes)."
    say "  Open this page in your browser for easy step-by-step instructions:"
    say ""
    say "      ${bold}${cyan}http://$SERVER_IP/$GUIDE_TOKEN/${reset}"
    say ""
    say "  Your admin login for https://$DOMAIN (also saved in $STATE_FILE):"
    say "      Username: ${bold}$ADMIN_USER${reset}"
    say "      Password: ${bold}$ADMIN_PASSWORD${reset}"
    say ""
    say "  Write the password down somewhere safe and change it after logging in."
    say ""
}

main() {
    trap 'on_error $LINENO' ERR
    preflight
    exec >> "$LOG" 2>&1
    load_installer_files
    ask_questions
    derive_settings
    install_packages
    install_toolchains
    download_releases
    setup_database
    download_hotel_files
    start_emulator
    install_cms
    configure_web
    write_guide
    finish
}

main "$@"

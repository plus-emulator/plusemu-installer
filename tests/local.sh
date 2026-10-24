#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; the state file is sourced
# Install on this PC only (--local) against fake programs: every address is localhost and the PC's own settings stay.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/fake/calls" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

export FAKE_DIR=$TEST_DIR/fake
TEMPLATES=$ROOT/templates
STATE_FILE=$TEST_DIR/etc/hotel.env
LOG=$TEST_DIR/log
LOCK_FILE=$TEST_DIR/update.lock
TTY=/dev/null
HOTEL_ROOT=$TEST_DIR/hotel
NGINX_DIR=$TEST_DIR/nginx
REAL_IP_CONF=$NGINX_DIR/conf.d/cloudflare-real-ip.conf
SSL_DIR=$TEST_DIR/ssl
CMS_CRON=$TEST_DIR/cron.d/atom-cms
LOGROTATE_CONF=$TEST_DIR/logrotate.d/plusemu
JOURNALD_DROPIN=$TEST_DIR/journald.conf.d/90-plusemu.conf
BACKUP_ROOT=$TEST_DIR/backups
NIGHTLY_ROOT=$BACKUP_ROOT/nightly
BACKUP_COMMAND=$TEST_DIR/sbin/plusemu-backup
BACKUP_CRON=$TEST_DIR/cron.d/plusemu-backup
BACKUP_LOG=$TEST_DIR/plusemu-backup.log
HEALTH_COMMAND=$TEST_DIR/sbin/plusemu-health
HEALTH_CRON=$TEST_DIR/cron.d/plusemu-health
HEALTH_LOG=$TEST_DIR/plusemu-health.log
HEALTH_STATE=$TEST_DIR/lib/health.state
SSHD_DROPIN=$TEST_DIR/sshd_config.d/10-plusemu.conf
FAIL2BAN_JAIL=$TEST_DIR/fail2ban/plusemu.local
SITE=$NGINX_DIR/sites-available/hotel.conf
mkdir -p "$TEST_DIR/fakebin" "$FAKE_DIR/ports" "$FAKE_DIR/exe" "$HOTEL_ROOT/cms" "$TEST_DIR/cron.d" \
    "$NGINX_DIR/conf.d" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" "$(dirname "$LOGROTATE_CONF")"

# Every program that could change this PC only records its call.
for program in systemctl ufw openssl sshd sysctl fail2ban-client cscli apt-get composer npm chown chgrp swapon; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_DIR/calls"\n' "$program" > "$TEST_DIR/fakebin/$program"
done
printf '#!/usr/bin/env bash\necho "swapon $*" >> "$FAKE_DIR/calls"\necho "/swapfile file 2G 0B -2"\n' > "$TEST_DIR/fakebin/swapon"
printf '#!/usr/bin/env bash\necho "nginx $*" >> "$FAKE_DIR/calls"\nif [ "$1" = -v ]; then echo "nginx version: nginx/1.26.3" >&2; fi\n' > "$TEST_DIR/fakebin/nginx"
printf '#!/usr/bin/env bash\necho "apt-cache $*" >> "$FAKE_DIR/calls"\n' > "$TEST_DIR/fakebin/apt-cache"
printf '#!/usr/bin/env bash\necho "mariadb  Ver 15.1 Distrib 10.11.6-MariaDB"\n' > "$TEST_DIR/fakebin/mariadb"
printf '#!/usr/bin/env bash\necho "php $*" >> "$FAKE_DIR/calls"\nif [ "$1" = -r ]; then echo 8.5.0; fi\n' > "$TEST_DIR/fakebin/php"
# The emulator answers on its API, so the client loads furniture from it; every other address is a call that must not happen.
cat > "$TEST_DIR/fakebin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_DIR/calls"
[[ $* == *http://127.0.0.1:8080/api/gamedata/furnidata* ]] && exit 0
exit 7
FAKE
# ss lists what listens on a port from $FAKE_DIR/ports/<port>: "<program> <pid>".
cat > "$TEST_DIR/fakebin/ss" <<'FAKE'
#!/usr/bin/env bash
args=$*
port=${args##*:}
[ -f "$FAKE_DIR/ports/$port" ] || exit 0
read -r name pid < "$FAKE_DIR/ports/$port"
printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:* users:(("%s",pid=%s,fd=6))\n' "$port" "${name//+/ }" "$pid"
FAKE
cat > "$TEST_DIR/fakebin/readlink" <<'FAKE'
#!/usr/bin/env bash
if [[ $1 =~ ^/proc/([0-9]+)/exe$ ]] && [ -f "$FAKE_DIR/exe/${BASH_REMATCH[1]}" ]; then cat "$FAKE_DIR/exe/${BASH_REMATCH[1]}"; exit 0; fi
exec /usr/bin/readlink "$@"
FAKE
cat > "$TEST_DIR/fakebin/dpkg-query" <<'FAKE'
#!/usr/bin/env bash
case $* in
    *Status*mariadb-server*) [ -f "$FAKE_DIR/mariadb-server" ] && printf 'install ok installed' ;;
    *Conffiles*) [ -f "$FAKE_DIR/default-md5" ] && printf ' /etc/nginx/sites-available/default %s\n /etc/nginx/nginx.conf 0123\n' "$(cat "$FAKE_DIR/default-md5")" ;;
esac
exit 0
FAKE
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH
: > "$FAKE_DIR/calls"

expect_terminal() { grep -qF -- "$1" "$TEST_DIR/terminal" || { echo "expected on the terminal: $1"; exit 1; }; }
expect_call() { grep -qF -- "$1" "$FAKE_DIR/calls" || { echo "expected call: $1"; exit 1; }; }
expect_no_call() { if grep -qE -- "$1" "$FAKE_DIR/calls"; then echo "unexpected call: $(grep -E -- "$1" "$FAKE_DIR/calls")"; exit 1; fi; }
expect_site() { grep -qxF -- "$1" "$SITE" || { echo "expected in the site: $1"; cat "$SITE"; exit 1; }; }
expect_no_site() { if grep -qE -- "$1" "$SITE"; then echo "unexpected in the site: $(grep -E -- "$1" "$SITE")"; exit 1; fi; }
state() { (. "$STATE_FILE"; printf '%s' "${!1}"); }
fails() { ! ("$@") > /dev/null 2>&1; }
absent() { # absent <grep options and pattern> <file>: nothing matches
    if grep "$@"; then echo "unexpected match: $*"; exit 1; fi
}
only_localhost() { # only_localhost <file>...: every address in the files is on this PC
    local address
    while read -r address; do
        [[ $address == http://localhost || $address == http://localhost/* || $address == http://localhost:* || $address == ws://localhost/* ]] ||
            { echo "not a local address in $*: $address"; exit 1; }
    done < <(grep -ohE '[a-z]+://[^"'"'"' ]*' "$@")
    if grep -lF 'https://' "$@"; then echo "https:// in a local file"; exit 1; fi
}

# ---------------------------------------------------------------- the questions

# Enter takes every suggested answer: no domain, no WebSocket address and no Discord question.
export PLUSEMU_LOCAL=1 PLUSEMU_YES=1
ask_questions
[ "$(state LOCAL)" = yes ]
[ "$(state DOMAIN)" = localhost ] && [ "$(state WS_URL)" = ws://localhost/ws ]
[ -n "$(state HOTEL_NAME)" ] && [ "$(state ADMIN_USER)" = admin ]
[[ $(state ADMIN_EMAIL) =~ ^admin@[a-z.]+\.[a-z]+$ ]]
[ -z "$(state DISCORD_WEBHOOK)" ] && [ -z "$(state CROWDSEC)" ]
expect_terminal 'http://localhost'
if grep -qiE 'domain name|WebSocket address|Discord|CrowdSec' "$TEST_DIR/terminal"; then echo 'a server question was asked'; exit 1; fi
initial=$ADMIN_PASSWORD

# A rerun, and the update, keep the local install without being told again.
unset PLUSEMU_LOCAL
: > "$TEST_DIR/terminal"
ask_questions
[ "$LOCAL" = yes ] && [ "$(state LOCAL)" = yes ] && [ "$ADMIN_PASSWORD" = "$initial" ]
PLUSEMU_LOCAL=1 ask_questions
[ "$(state LOCAL)" = yes ]

# Switching an installed hotel is refused, and nothing changes.
before=$(sha256sum "$STATE_FILE")
: > "$TEST_DIR/terminal"
PLUSEMU_LOCAL=0 fails ask_questions
expect_terminal 'localhost'
expect_terminal 'Nothing was changed'
[ "$(sha256sum "$STATE_FILE")" = "$before" ]
PLUSEMU_LOCAL=maybe fails ask_questions
[ "$(sha256sum "$STATE_FILE")" = "$before" ]

# A server install is never turned into a local one, also one made before local installs existed.
rm "$STATE_FILE"
(
    export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws PLUSEMU_HOTEL_NAME=Example
    export PLUSEMU_ADMIN_USER=admin PLUSEMU_ADMIN_EMAIL=admin@example.com
    ask_questions
)
[ "$(state LOCAL)" != yes ]
sed -i '/^LOCAL=/d' "$STATE_FILE"
before=$(sha256sum "$STATE_FILE")
: > "$TEST_DIR/terminal"
PLUSEMU_LOCAL=1 fails ask_questions
expect_terminal 'example.com'
expect_terminal 'Nothing was changed'
[ "$(sha256sum "$STATE_FILE")" = "$before" ]
LOCAL_OPTION=1 fails ask_questions
[ "$(sha256sum "$STATE_FILE")" = "$before" ]
rm "$STATE_FILE"
PLUSEMU_LOCAL=1 ask_questions > /dev/null

# ---------------------------------------------------------------- ports already in use

ports() { rm -f "$FAKE_DIR/ports/"*; while [ "$#" -gt 0 ]; do echo "$2 $3" > "$FAKE_DIR/ports/$1"; shift 3; done; }
ports
check_local_ports
# The installer's own programs may hold their ports, so a rerun works.
echo "$HOTEL_ROOT/emulator/Plus Emulator" > "$FAKE_DIR/exe/4242"
echo /usr/sbin/mariadbd > "$FAKE_DIR/exe/300"
ports 80 nginx 812 3306 mariadbd 300 2096 Plus+Emulator 4242 8080 Plus+Emulator 4242 30001 Plus+Emulator 4242
check_local_ports
# Another program on a port stops the install and is named with its port and process.
ports 80 apache2 777
: > "$TEST_DIR/terminal"
fails check_local_ports
expect_terminal 'port 80'
expect_terminal 'apache2'
expect_terminal '777'
ports 8080 java 901 30001 node 902
: > "$TEST_DIR/terminal"
fails check_local_ports
expect_terminal 'port 8080' && expect_terminal 'java' && expect_terminal 'port 30001' && expect_terminal 'node'
# MySQL is not MariaDB: installing MariaDB would remove it.
echo /usr/sbin/mysqld > "$FAKE_DIR/exe/310"
ports 3306 mysqld 310
fails check_local_ports
touch "$FAKE_DIR/mariadb-server"
check_local_ports
ports

# ---------------------------------------------------------------- what gets installed

derive_settings
[ "$SITE_URL" = http://localhost ] && [ "$SOCKET_URL" = ws://localhost/ws ]
[ "$WS_HOST" = localhost ] && [ "$WS_PATH" = /ws ]
expect_no_call 'curl .*(ipify|icanhazip)'

: > "$FAKE_DIR/calls"
OS_ID=debian
install_packages
expect_call 'apt-get install'
expect_no_call 'apt-get install .*(ufw|fail2ban|unattended-upgrades|python3-systemd)'

# The client, the website and the game connection use http://localhost and ws://localhost only.
config=$TEST_DIR/client-configuration
mkdir -p "$config"
write_client_config "$config"
only_localhost "$config/renderer-config.json" "$config/ui-config.json" "$config/client-mode.json"
[ "$(jq -r '."socket.url"' "$config/renderer-config.json")" = ws://localhost/ws ]
[ "$(jq -r '."furnidata.url"' "$config/renderer-config.json")" = http://localhost/api/gamedata/furnidata ]
[ "$(jq -r .apiBaseUrl "$config/client-mode.json")" = http://localhost ]

printf 'APP_URL=http://example.test\n' > "$HOTEL_ROOT/cms/.env.example"
# Atom's setup already ran, and the settings the installer writes into the database are kept.
sql() { if [[ " $* " == *' -e '* ]]; then echo 1; else cat >> "$FAKE_DIR/sql"; fi; }
install_cms
unset -f sql
env=$HOTEL_ROOT/cms/.env
grep -qx 'APP_URL="http://localhost"' "$env"
grep -qx 'NITRO_CLIENT_PATH="http://localhost/client"' "$env"
grep -qx 'FORCE_HTTPS="false"' "$env"
grep -qx 'SESSION_SECURE_COOKIE="false"' "$env"
grep -qF "'http://localhost/client'" "$FAKE_DIR/sql"
grep -qF "'http://localhost/hotel-files/c_images/album1584'" "$FAKE_DIR/sql"
only_localhost "$env" "$FAKE_DIR/sql"

# nginx answers only on this PC, without HTTPS, HSTS, Cloudflare or per-visitor limits.
GUIDE_TOKEN=guidetoken12
ln -s "$NGINX_DIR/sites-available/default" "$NGINX_DIR/sites-enabled/default"
printf 'server { listen 80 default_server; }\n' > "$NGINX_DIR/sites-available/default"
md5sum "$NGINX_DIR/sites-available/default" | cut -d' ' -f1 > "$FAKE_DIR/default-md5"
: > "$FAKE_DIR/calls"
configure_web
[ "$(grep -E '^\s*listen ' "$SITE" | sed 's/^ *//' | LC_ALL=C sort -u)" = $'listen 127.0.0.1:80 default_server;\nlisten [::1]:80 default_server;' ]
expect_site '    server_name localhost;'
expect_no_site 'ssl|443|Strict-Transport-Security|limit_req|limit_conn|return 444|plusemu_from_cloudflare|https://'
expect_site '        if ($http_origin != "http://localhost") { return 403; }'
expect_site '        proxy_set_header X-Real-IP $remote_addr;'
expect_site '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
expect_site '        fastcgi_param HTTPS off;'
grep -q "location .*/guidetoken12/" "$SITE"
[ ! -e "$REAL_IP_CONF" ] && [ ! -e "$NGINX_DIR/conf.d/plusemu-limits.conf" ]
[ -L "$NGINX_DIR/sites-enabled/hotel.conf" ]
# nginx's own welcome page listens on every address, so it goes; a default site the owner changed stays.
[ ! -e "$NGINX_DIR/sites-enabled/default" ]
expect_call 'nginx -t'
expect_terminal 'nginx serves http://localhost'
expect_no_call '^(ufw|openssl)'
expect_no_call 'curl .*cloudflare'
ln -s "$NGINX_DIR/sites-available/default" "$NGINX_DIR/sites-enabled/default"
printf 'server { listen 8000; }\n' >> "$NGINX_DIR/sites-available/default"
configure_web
[ -L "$NGINX_DIR/sites-enabled/default" ]

# Only the hotel's own logs, backups and health check: SSH, fail2ban, updates, network and the journal stay as they are.
for step in protect_ssh_logins harden_ssh install_security_updates tune_network setup_crowdsec install_crowdsec; do
    eval "$step() { echo '$step' >> \"\$FAKE_DIR/calls\"; }"
done
: > "$FAKE_DIR/calls"
secure_server
expect_no_call '^(protect_ssh_logins|harden_ssh|install_security_updates|tune_network|setup_crowdsec|install_crowdsec)$'
expect_no_call '^(sshd|sysctl|ufw|fail2ban-client|cscli|systemctl .*(fail2ban|ssh|journald|apt-daily))'
[ ! -e "$SSHD_DROPIN" ] && [ ! -e "$FAIL2BAN_JAIL" ] && [ ! -e "$JOURNALD_DROPIN" ]
grep -q '/var/log/plusemu-\*.log' "$LOGROTATE_CONF"
grep -qF "$BACKUP_COMMAND" "$BACKUP_CRON" && grep -qF "$HEALTH_COMMAND" "$HEALTH_CRON"
if grep -qi discord "$TEST_DIR/terminal"; then echo 'local mode talks about Discord'; exit 1; fi

# The health check leaves out the HTTPS certificate and the Cloudflare refresh.
for entry in "${HEALTH_CHECKS[@]}"; do
    eval "health_${entry%%|*}() { echo 'health_${entry%%|*}' >> \"\$FAKE_DIR/calls\"; }"
done
: > "$FAKE_DIR/calls"
health_check > "$TEST_DIR/health"
expect_call 'health_website'
expect_call 'health_backup'
expect_no_call 'health_(certificate|cloudflare)'
grep -q 'OK: all 8 checks passed' "$TEST_DIR/health"

# ---------------------------------------------------------------- the guide and the summary

render_guide
guide=$HOTEL_ROOT/setup-guide/index.html
if grep -F '{{' "$guide"; then echo 'the local guide has an empty placeholder'; exit 1; fi
grep -qF 'http://localhost/housekeeping' "$guide"
grep -qF "$ADMIN_USER" "$guide"
grep -qF 'sudo plusemu-update' "$guide"
grep -qF "$NIGHTLY_ROOT" "$guide"
grep -qF 'sudo systemctl stop plusemu' "$guide"
grep -qF 'journalctl -u plusemu' "$guide"
grep -qF -- '--local' "$guide"
for secret in "$ADMIN_PASSWORD" "$DB_PASSWORD"; do absent -qF "$secret" "$guide"; done
if grep -qi 'cloudflare' "$guide" && ! grep -qi 'no cloudflare\|without cloudflare' "$guide"; then echo 'the local guide explains Cloudflare'; exit 1; fi

: > "$TEST_DIR/terminal"
finish
expect_terminal 'http://localhost'
expect_terminal "http://localhost/$GUIDE_TOKEN/"
grep -qF "$ADMIN_PASSWORD" "$TEST_DIR/terminal"
absent -qF "$ADMIN_PASSWORD" "$TEST_DIR/log"
if grep -qi 'cloudflare\|ssh' "$TEST_DIR/terminal"; then echo 'the local summary talks about the server setup'; exit 1; fi
# The installed health command ran at the end, without the server's certificate and Cloudflare checks.
grep -q 'checks' "$HEALTH_LOG"
if grep -qi 'certificate\|cloudflare' "$HEALTH_LOG"; then echo 'the local health check looks at the server setup'; exit 1; fi

# ---------------------------------------------------------------- the whole run

for step in preflight load_installer_files derive_settings install_packages install_toolchains download_releases setup_database \
    download_hotel_files start_emulator write_client_config install_cms configure_web secure_server write_guide install_update_command \
    connect_cloudflare check_local_ports; do
    eval "$step() { echo '$step' >> \"\$FAKE_DIR/steps\"; }"
done
eval 'finish() { echo "finish $TOTAL_STEPS" >> "$FAKE_DIR/steps"; }'
LOG=$TEST_DIR/install.log
rm "$STATE_FILE"
: > "$FAKE_DIR/steps"
(main --local)
grep -qx 'check_local_ports' "$FAKE_DIR/steps"
grep -qx 'configure_web' "$FAKE_DIR/steps"
absent -qx 'connect_cloudflare' "$FAKE_DIR/steps"
grep -qx 'finish 10' "$FAKE_DIR/steps"
[ "$(state LOCAL)" = yes ]
# The port check comes before anything is installed.
[ "$(grep -nx check_local_ports "$FAKE_DIR/steps" | cut -d: -f1)" -lt "$(grep -nx install_packages "$FAKE_DIR/steps" | cut -d: -f1)" ]

# A server install runs the Cloudflare step and leaves the ports alone.
rm "$STATE_FILE"
: > "$FAKE_DIR/steps"
(
    export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws PLUSEMU_HOTEL_NAME=Example
    export PLUSEMU_ADMIN_USER=admin PLUSEMU_ADMIN_EMAIL=admin@example.com
    main
)
grep -qx 'connect_cloudflare' "$FAKE_DIR/steps"
absent -qx 'check_local_ports' "$FAKE_DIR/steps"
grep -qx 'finish 11' "$FAKE_DIR/steps"

printf 'Bash local install checks passed\n' >&4

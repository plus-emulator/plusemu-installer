#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; the state file is sourced
# Exercise the CrowdSec question and setup against fake apt, cscli, nginx and systemctl.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$FAKE_DIR/calls" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

export FAKE_DIR=$TEST_DIR/fake
STATE_FILE=$TEST_DIR/etc/hotel.env
TTY=$TEST_DIR/no-terminal
CROWDSEC_DIR=$TEST_DIR/etc/crowdsec
CROWDSEC_KEYRING=$TEST_DIR/keyrings/crowdsec.gpg
CROWDSEC_SOURCES=$TEST_DIR/sources.list.d/crowdsec_crowdsec.list
CROWDSEC_PIN=$TEST_DIR/preferences.d/crowdsec
CROWDSEC_WHITELIST=$CROWDSEC_DIR/parsers/s02-enrich/plusemu-whitelist.yaml
CROWDSEC_NGINX_CONF=$TEST_DIR/nginx/conf.d/crowdsec_nginx.conf
REAL_IP_CONF=$TEST_DIR/nginx/conf.d/cloudflare-real-ip.conf
FAIL2BAN_JAIL=$TEST_DIR/fail2ban/jail.d/plusemu.local
LOG=$TEST_DIR/log
mkdir -p "$FAKE_DIR" "$TEST_DIR/fakebin" "$(dirname "$CROWDSEC_SOURCES")" "$(dirname "$CROWDSEC_PIN")" "$(dirname "$REAL_IP_CONF")"
export CROWDSEC_DIR CROWDSEC_NGINX_CONF

expect_terminal() { grep -qF -- "$1" "$TEST_DIR/terminal" || { echo "expected on the terminal: $1"; exit 1; }; }
expect_call() { grep -qxF -- "$1" "$FAKE_DIR/calls" || { echo "expected call: $1"; exit 1; }; }
expect_no_call() { if grep -qF -- "$1" "$FAKE_DIR/calls"; then echo "unexpected call: $1"; exit 1; fi; }
state() { (. "$STATE_FILE"; printf '%s' "${!1}"); }

# ---------------------------------------------------------------- the question

export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws PLUSEMU_HOTEL_NAME=Example
export PLUSEMU_ADMIN_USER=admin PLUSEMU_ADMIN_EMAIL=admin@example.com PLUSEMU_YES=1

# The simple guide never asks and never installs CrowdSec.
PLUSEMU_GUIDE_MODE=simple ask_questions
[ -z "$(state CROWDSEC)" ]
if grep -q CrowdSec "$TEST_DIR/terminal"; then echo 'the simple guide mentioned CrowdSec'; exit 1; fi
PLUSEMU_GUIDE_MODE=simple PLUSEMU_CROWDSEC=1 ask_questions
[ -z "$(state CROWDSEC)" ]
expect_terminal 'CrowdSec is offered with the advanced guide only'
rm "$STATE_FILE"

# The terminal questions answer with $ANSWER, or with their default.
ask() { printf '  %s: \n' "$2" >&3; printf -v "$1" '%s' "${ANSWER:-${3:-}}"; }
asked() { grep -c 'Install CrowdSec to detect and block attackers (shared blocklist)? (y/n)' "$TEST_DIR/terminal" || true; }

# An unattended run with the advanced guide takes the default, no, without asking.
: > "$TEST_DIR/terminal"
PLUSEMU_GUIDE_MODE=advanced ask_questions
[ "$(state CROWDSEC)" = no ] && [ "$(asked)" = 0 ]
expect_terminal 'CrowdSec:    no'
rm "$STATE_FILE"

# In a terminal, the advanced guide asks.
: > "$TEST_DIR/terminal"
(unset PLUSEMU_YES; ANSWER=y PLUSEMU_GUIDE_MODE=advanced ask_questions)
[ "$(state CROWDSEC)" = yes ] && [ "$(asked)" = 1 ]
rm "$STATE_FILE"

# PLUSEMU_CROWDSEC=1 says yes without the question; reruns keep the answer without asking.
: > "$TEST_DIR/terminal"
PLUSEMU_GUIDE_MODE=advanced PLUSEMU_CROWDSEC=1 ask_questions
[ "$(state CROWDSEC)" = yes ] && [ "$(asked)" = 0 ]
: > "$TEST_DIR/terminal"
ask_questions
[ "$CROWDSEC" = yes ] && [ "$GUIDE_MODE" = advanced ] && [ "$(asked)" = 0 ]
PLUSEMU_CROWDSEC=0 ask_questions
[ "$(state CROWDSEC)" = no ]
PLUSEMU_CROWDSEC=1 ask_questions
[ "$(state CROWDSEC)" = yes ]

# Switching an existing simple hotel to the advanced guide asks once.
PLUSEMU_GUIDE_MODE=simple PLUSEMU_CROWDSEC=0 ask_questions
sed -i "s/^CROWDSEC=.*/CROWDSEC=''/" "$STATE_FILE"
: > "$TEST_DIR/terminal"
(unset PLUSEMU_YES; PLUSEMU_GUIDE_MODE=advanced ask_questions)
[ "$(asked)" = 1 ] && [ "$(state CROWDSEC)" = no ]
: > "$TEST_DIR/terminal"
(unset PLUSEMU_YES; ask_questions)
[ "$(asked)" = 0 ]

# ---------------------------------------------------------------- fake packages and services

# apt-get "installs" a package by creating $FAKE_DIR/installed/<name>, the way its own scripts would.
cat > "$TEST_DIR/fakebin/apt-get" <<'FAKE'
#!/usr/bin/env bash
echo "apt-get $*" >> "$FAKE_DIR/calls"
mkdir -p "$FAKE_DIR/installed"
case "$1 $3" in
    'install crowdsec')
        [ ! -e "$FAKE_DIR/broken-apt" ] || exit 100
        # The package reads its port from config.yaml.local when it starts.
        grep -q 'listen_uri: 127.0.0.1:8085' "$CROWDSEC_DIR/config.yaml.local" && echo 'apt-get saw the CrowdSec port' >> "$FAKE_DIR/calls"
        mkdir -p "$CROWDSEC_DIR/bouncers"
        [ -f "$CROWDSEC_DIR/bouncers/crowdsec-firewall-bouncer.yaml" ] || echo 'api_url: http://127.0.0.1:8080/' > "$CROWDSEC_DIR/bouncers/crowdsec-firewall-bouncer.yaml"
        touch "$FAKE_DIR/installed/crowdsec" "$FAKE_DIR/installed/crowdsec-firewall-bouncer"
        ;;
    'install crowdsec-nginx-bouncer')
        mkdir -p "$(dirname "$CROWDSEC_NGINX_CONF")"
        echo 'access_by_lua_block {}' > "$CROWDSEC_NGINX_CONF"
        ;;
esac
FAKE
cat > "$TEST_DIR/fakebin/apt-cache" <<'FAKE'
#!/usr/bin/env bash
[ ! -e "$FAKE_DIR/no-lua" ]
FAKE
cat > "$TEST_DIR/fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_DIR/calls"
if [ "$1" = is-active ]; then [ -e "$FAKE_DIR/installed/${*: -1}" ]; fi
FAKE
cat > "$TEST_DIR/fakebin/nginx" <<'FAKE'
#!/usr/bin/env bash
echo "nginx $*" >> "$FAKE_DIR/calls"
! { [ -e "$FAKE_DIR/nginx-refuses-lua" ] && [ -e "$CROWDSEC_NGINX_CONF" ]; }
FAKE
cat > "$TEST_DIR/fakebin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_DIR/calls"
echo 'PUBLIC KEY'
FAKE
cat > "$TEST_DIR/fakebin/gpg" <<'FAKE'
#!/usr/bin/env bash
sed 's/^/dearmored /'
FAKE
printf '#!/usr/bin/env bash\necho "cscli $*" >> "$FAKE_DIR/calls"\n' > "$TEST_DIR/fakebin/cscli"
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH

real_ip_conf $'173.245.48.0/20\n2400:cb00::/32\n198.51.100.7' > "$REAL_IP_CONF"
run() { : > "$FAKE_DIR/calls"; : > "$TEST_DIR/terminal"; setup_crowdsec; protect_ssh_logins; }
snapshot() { cat "$CROWDSEC_SOURCES" "$CROWDSEC_PIN" "$CROWDSEC_DIR/config.yaml.local" "$CROWDSEC_DIR"/acquis.d/* "$CROWDSEC_WHITELIST" "$CROWDSEC_DIR/bouncers/"* "$FAIL2BAN_JAIL"; }

# ---------------------------------------------------------------- setup

# Simple guide: nothing is installed, and fail2ban keeps SSH.
GUIDE_MODE=simple CROWDSEC=yes
run
expect_no_call 'apt-get'
expect_call 'systemctl enable fail2ban'
grep -qx 'enabled = true' "$FAIL2BAN_JAIL"

# Advanced guide with CrowdSec: the repository, the port, the collections, the logs and the whitelist.
GUIDE_MODE=advanced CROWDSEC=yes
run
[ "$(< "$CROWDSEC_SOURCES")" = "deb [signed-by=$CROWDSEC_KEYRING] https://packagecloud.io/crowdsec/crowdsec/any any main" ]
[ "$(< "$CROWDSEC_KEYRING")" = 'dearmored PUBLIC KEY' ]
expect_call 'curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey'
grep -qx 'Pin: release o=packagecloud.io/crowdsec/crowdsec,a=any,n=any,c=main' "$CROWDSEC_PIN"
expect_call 'apt-get saw the CrowdSec port'
expect_call 'apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables'
expect_call 'cscli collections install crowdsecurity/sshd crowdsecurity/nginx crowdsecurity/base-http-scenarios crowdsecurity/http-cve'
expect_call 'cscli hub upgrade'
grep -qx 'api_url: http://127.0.0.1:8085/' "$CROWDSEC_DIR/bouncers/crowdsec-firewall-bouncer.yaml"
grep -qx '  - /var/log/nginx/access.log' "$CROWDSEC_DIR/acquis.d/nginx.yaml"
grep -qx '  - /var/log/nginx/error.log' "$CROWDSEC_DIR/acquis.d/nginx.yaml"
grep -qx '  - "_SYSTEMD_UNIT=ssh.service"' "$CROWDSEC_DIR/acquis.d/sshd.yaml"
grep -qx 'source: journalctl' "$CROWDSEC_DIR/acquis.d/sshd.yaml"
[ "$(ls "$CROWDSEC_DIR/acquis.d")" = "nginx.yaml
sshd.yaml" ]
for entry in '    - "127.0.0.1"' '    - "::1"' '    - "198.51.100.7"' '  cidr:' '    - "173.245.48.0/20"' '    - "2400:cb00::/32"'; do
    grep -qxF -- "$entry" "$CROWDSEC_WHITELIST" || { echo "missing from the whitelist: $entry"; exit 1; }
done
expect_call 'systemctl restart crowdsec-firewall-bouncer'
expect_call 'apt-get install -y crowdsec-nginx-bouncer'
expect_call 'systemctl reload nginx'
expect_terminal 'CrowdSec blocks banned visitors on the website'
expect_terminal 'sudo cscli decisions list'
# One tool bans SSH attackers: fail2ban goes off.
grep -qx 'enabled = false' "$FAIL2BAN_JAIL"
expect_call 'systemctl disable --now fail2ban'
expect_no_call 'systemctl restart fail2ban'
expect_terminal 'CrowdSec bans SSH attackers, so fail2ban is off'

# A rerun updates CrowdSec and leaves every file as it was.
before=$(snapshot)
run
[ "$(snapshot)" = "$before" ]
expect_call 'apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables'
expect_call 'cscli hub upgrade'

# The whitelist follows Cloudflare's ranges and reports when it changed.
if crowdsec_whitelist; then echo 'an unchanged whitelist was written again'; exit 1; fi
real_ip_conf $'173.245.48.0/20\n104.16.0.0/13' > "$REAL_IP_CONF"
crowdsec_whitelist
grep -qxF '    - "104.16.0.0/13"' "$CROWDSEC_WHITELIST"
if grep -qF '2400:cb00::/32' "$CROWDSEC_WHITELIST"; then echo 'an old range stayed in the whitelist'; exit 1; fi

# Turning CrowdSec off brings fail2ban back and says how to remove CrowdSec.
CROWDSEC=no
run
expect_no_call 'apt-get'
grep -qx 'enabled = true' "$FAIL2BAN_JAIL"
expect_call 'systemctl enable fail2ban'
expect_terminal 'sudo apt purge crowdsec crowdsec-firewall-bouncer-iptables crowdsec-nginx-bouncer'

# ---------------------------------------------------------------- failures

# Without nginx's Lua module, the nginx bouncer is left out and the firewall bouncer still bans.
rm -rf "$FAKE_DIR/installed" "$CROWDSEC_NGINX_CONF"
touch "$FAKE_DIR/no-lua"
CROWDSEC=yes
run
expect_no_call 'apt-get install -y crowdsec-nginx-bouncer'
expect_terminal 'This nginx has no Lua module'
grep -qx 'enabled = false' "$FAIL2BAN_JAIL"
rm "$FAKE_DIR/no-lua"

# nginx refuses the bouncer: it is removed, so the website keeps working.
touch "$FAKE_DIR/nginx-refuses-lua"
run
expect_call 'apt-get purge -y crowdsec-nginx-bouncer'
[ ! -e "$CROWDSEC_NGINX_CONF" ]
expect_terminal 'nginx did not accept the CrowdSec nginx bouncer'
rm "$FAKE_DIR/nginx-refuses-lua"

# CrowdSec does not install: the installer goes on, and fail2ban keeps SSH.
rm -rf "$FAKE_DIR/installed"
touch "$FAKE_DIR/broken-apt"
run
expect_terminal 'CrowdSec could not be installed'
grep -qx 'enabled = true' "$FAIL2BAN_JAIL"
expect_call 'systemctl restart fail2ban'
expect_no_call 'cscli collections install'

printf 'Bash CrowdSec checks passed\n' >&4

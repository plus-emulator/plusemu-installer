#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; the state file is sourced
# Open the database to chosen addresses (--remote-database) against fake ufw, MariaDB and systemctl programs.
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
MARIADB_REMOTE_CONF=$TEST_DIR/mariadb.conf.d/60-plusemu-remote.cnf
mkdir -p "$TEST_DIR/fakebin" "$FAKE_DIR" "$(dirname "$MARIADB_REMOTE_CONF")"
: > "$FAKE_DIR/rules"
: > "$FAKE_DIR/calls"
: > "$FAKE_DIR/users"

# The fake ufw keeps its rules the way "ufw show added" prints them.
cat > "$TEST_DIR/fakebin/ufw" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
rules=$FAKE_DIR/rules
echo "ufw $*" >> "$FAKE_DIR/calls"
action=add
if [ "$1" = delete ]; then action=delete; shift; fi
if [ "$1" = show ]; then
    echo "Added user rules (see 'ufw status' for running firewall):"
    sed 's/^/ufw /' "$rules"
    exit 0
fi
[ "$#" = 11 ] && [ "$1 $2 $3 $4 $6 $7 $8 $9 ${10}" = 'allow proto tcp from to any port 3306 comment' ] || { echo "fake ufw: unsupported: $*" >&2; exit 2; }
rule="allow from $5 to any port 3306 proto tcp comment '${11}'"
if [ "$action" = delete ]; then
    grep -vxF -- "$rule" "$rules" > "$rules.new" || true
    mv "$rules.new" "$rules"
elif ! grep -qxF -- "$rule" "$rules"; then
    echo "$rule" >> "$rules"
fi
FAKE
cat > "$TEST_DIR/fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_DIR/calls"
FAKE
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH

# The fake database keeps the hotel accounts, one host per line.
sql() {
    local statements
    if [ "${1:-}" = -N ]; then statements=$3; else statements=$(cat); fi
    if [[ $statements == "SELECT Host FROM mysql.user WHERE User = 'hotel'"* ]]; then cat "$FAKE_DIR/users"; return; fi
    printf '%s\n' "$statements" >> "$FAKE_DIR/sql"
    while read -r statement; do
        if [[ $statement =~ ^CREATE\ USER\ IF\ NOT\ EXISTS\ \'hotel\'@\'([^\']+)\' ]]; then
            grep -qxF "${BASH_REMATCH[1]}" "$FAKE_DIR/users" || echo "${BASH_REMATCH[1]}" >> "$FAKE_DIR/users"
        elif [[ $statement =~ ^DROP\ USER\ IF\ EXISTS\ \'hotel\'@\'([^\']+)\' ]]; then
            grep -vxF "${BASH_REMATCH[1]}" "$FAKE_DIR/users" > "$FAKE_DIR/users.new" || true
            mv "$FAKE_DIR/users.new" "$FAKE_DIR/users"
        fi
    done <<< "$statements"
}
wait_for_emulator() { echo 'wait_for_emulator' >> "$FAKE_DIR/calls"; }

rules() { cat "$FAKE_DIR/rules"; }
users() { sort "$FAKE_DIR/users" | paste -sd' '; }
db_rule() { printf "allow from %s to any port 3306 proto tcp comment 'plusemu-database'" "$1"; }
expect_rule() { grep -qxF -- "$(db_rule "$1")" "$FAKE_DIR/rules" || { echo "expected rule for $1"; rules; exit 1; }; }
expect_no_rule() { if grep -qxF -- "$(db_rule "$1")" "$FAKE_DIR/rules"; then echo "unexpected rule for $1"; rules; exit 1; fi; }
expect_call() { grep -qxF -- "$1" "$FAKE_DIR/calls" || { echo "expected call: $1"; cat "$FAKE_DIR/calls"; exit 1; }; }
expect_no_call() { if grep -qxF -- "$1" "$FAKE_DIR/calls"; then echo "unexpected call: $1"; exit 1; fi; }
fails() { if (exec 3> /dev/null; "$@") > /dev/null 2>&1; then echo "expected a failure: $*"; exit 1; fi; }
select_with() { REMOTE_DATABASE_OPTION=$1 select_remote_database "${2:-}"; }
run_remote() { : > "$FAKE_DIR/calls"; : > "$TEST_DIR/terminal"; configure_remote_database; }

# The addresses are IPv4 addresses or networks, written the way ufw shows them.
LOCAL=no
select_with ' 203.0.113.7, 198.51.100.77/24 ,192.0.2.9/32'
[ "$REMOTE_DATABASE" = '203.0.113.7,198.51.100.0/24,192.0.2.9' ]
select_with 010.0.0.1
[ "$REMOTE_DATABASE" = 10.0.0.1 ]
for wrong in any '0.0.0.0/0' '10.0.0.0/7' '300.1.1.1' '1.2.3' '2001:db8::1' ',' '1.2.3.4/33' '1.2.3.4/'; do fails select_with "$wrong"; done
# A rerun without the option keeps the saved addresses; "off" closes the database again.
REMOTE_DATABASE_OPTION='' PLUSEMU_REMOTE_DATABASE='' select_remote_database '203.0.113.7'
[ "$REMOTE_DATABASE" = 203.0.113.7 ]
select_with off 203.0.113.7
[ -z "$REMOTE_DATABASE" ]
PLUSEMU_REMOTE_DATABASE=198.51.100.4 select_remote_database
[ "$REMOTE_DATABASE" = 198.51.100.4 ]
# A local hotel already has the database on this PC.
LOCAL=yes
fails select_with 203.0.113.7
select_with off
[ -z "$REMOTE_DATABASE" ]
LOCAL=no

[ "$(mariadb_host 203.0.113.7)" = 203.0.113.7 ]
[ "$(mariadb_host 198.51.100.0/24)" = 198.51.100.0/255.255.255.0 ]
[ "$(mariadb_host 10.0.0.0/8)" = 10.0.0.0/255.0.0.0 ]
[ "$(mariadb_host 172.16.0.0/12)" = 172.16.0.0/255.240.0.0 ]

# Opening: MariaDB listens on every address, but only the chosen addresses get through the firewall and have an account.
DB_PASSWORD=Secret123 SERVER_IP=192.0.2.1
REMOTE_DATABASE=203.0.113.7,198.51.100.0/24
run_remote
expect_rule 203.0.113.7
expect_rule 198.51.100.0/24
[ "$(users)" = '198.51.100.0/255.255.255.0 203.0.113.7' ]
grep -qx 'bind-address = 0.0.0.0' "$MARIADB_REMOTE_CONF"
grep -qF "GRANT ALL PRIVILEGES ON plus.* TO 'hotel'@'203.0.113.7';" "$FAKE_DIR/sql"
grep -qF "IDENTIFIED BY 'Secret123'" "$FAKE_DIR/sql"
expect_call 'systemctl restart mariadb'
expect_call 'systemctl restart plusemu'
grep -q '203.0.113.7, 198.51.100.0/24' "$TEST_DIR/terminal"

# A rerun changes nothing and restarts nothing.
before=$(rules)
run_remote
[ "$(rules)" = "$before" ]
expect_no_call 'systemctl restart mariadb'
expect_no_call 'systemctl restart plusemu'

# Accounts the owner made by hand stay; accounts and rules for removed addresses go.
echo '%' >> "$FAKE_DIR/users"
echo "allow from 192.0.2.50 to any port 3306 proto tcp" >> "$FAKE_DIR/rules"
REMOTE_DATABASE=198.51.100.0/24,192.0.2.20
run_remote
expect_no_rule 203.0.113.7
expect_rule 198.51.100.0/24
expect_rule 192.0.2.20
[ "$(users)" = '% 192.0.2.20 198.51.100.0/255.255.255.0' ]
grep -qxF 'allow from 192.0.2.50 to any port 3306 proto tcp' "$FAKE_DIR/rules"
expect_no_call 'systemctl restart mariadb'

# Off: the database listens on this server only again, and its rules and accounts are gone.
REMOTE_DATABASE=
run_remote
expect_no_rule 198.51.100.0/24
expect_no_rule 192.0.2.20
[ "$(users)" = '%' ]
[ ! -e "$MARIADB_REMOTE_CONF" ]
expect_call 'systemctl restart mariadb'
expect_call 'systemctl restart plusemu'
run_remote
expect_no_call 'systemctl restart mariadb'

# The choice is saved and a rerun of the questions keeps it.
export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws PLUSEMU_HOTEL_NAME=Example
export PLUSEMU_ADMIN_USER=johndoe PLUSEMU_ADMIN_EMAIL=johndoe@example.com PLUSEMU_YES=1
REMOTE_DATABASE_OPTION=203.0.113.7
ask_questions
REMOTE_DATABASE_OPTION=''
(source "$STATE_FILE"; [ "$REMOTE_DATABASE" = 203.0.113.7 ])
REMOTE_DATABASE=
ask_questions
[ "$REMOTE_DATABASE" = 203.0.113.7 ]
# A state file from an older installer has no remote addresses.
sed -i '/^REMOTE_DATABASE=/d' "$STATE_FILE"
REMOTE_DATABASE=203.0.113.7
ask_questions
[ -z "$REMOTE_DATABASE" ]

# The end of the install says what to fill in on the PC; the password goes to the terminal only.
run_health_check() { :; }
REMOTE_DATABASE=203.0.113.7 SERVER_IP=192.0.2.1 DB_PASSWORD=Secret123 ADMIN_PASSWORD=Admin123! HOTEL_ROOT=$TEST_DIR/hotel
: > "$TEST_DIR/terminal"
finish
grep -q 'Hostname / IP: 192.0.2.1    Port: 3306' "$TEST_DIR/terminal"
grep -q 'User: hotel    Database: plus' "$TEST_DIR/terminal"
[ "$(grep -c 'Password: Secret123' "$TEST_DIR/terminal")" = 2 ]
grep -q 'Only 203.0.113.7 can connect' "$TEST_DIR/terminal"
if grep -q Secret123 "$TEST_DIR/log"; then echo 'the database password is in the log'; exit 1; fi

# On a hotel that is already installed, --remote-database changes only the database access.
# The website, emulator and client stay as they are.
LOG=$TEST_DIR/install.log LOCK_FILE=$TEST_DIR/update.lock
preflight() { :; }
derive_settings() { SERVER_IP=192.0.2.1; }
for step in load_installer_files ask_questions install_packages install_toolchains download_releases setup_database \
    download_hotel_files start_emulator write_client_config install_camera install_cms configure_web secure_server \
    write_guide install_update_command connect_cloudflare finish; do
    eval "$step() { echo $step >> \"\$FAKE_DIR/steps\"; }"
done
: > "$FAKE_DIR/steps"
: > "$FAKE_DIR/rules"
: > "$FAKE_DIR/users"
rm -f "$MARIADB_REMOTE_CONF"
unset PLUSEMU_DOMAIN PLUSEMU_WS_URL PLUSEMU_HOTEL_NAME PLUSEMU_ADMIN_USER PLUSEMU_ADMIN_EMAIL
REMOTE_DATABASE_OPTION='' LOCAL=no DB_PASSWORD=Secret123 REMOTE_DATABASE=
save_state
: > "$TEST_DIR/terminal"
(main --remote-database 203.0.113.7,198.51.100.4)
[ ! -s "$FAKE_DIR/steps" ] || { echo 'the hotel was reinstalled:'; cat "$FAKE_DIR/steps"; exit 1; }
expect_rule 203.0.113.7
expect_rule 198.51.100.4
[ "$(users)" = '198.51.100.4 203.0.113.7' ]
grep -qx 'bind-address = 0.0.0.0' "$MARIADB_REMOTE_CONF"
(source "$STATE_FILE"; [ "$REMOTE_DATABASE" = 203.0.113.7,198.51.100.4 ] && [ "$DB_PASSWORD" = Secret123 ])
grep -q 'Hostname / IP: 192.0.2.1    Port: 3306' "$TEST_DIR/terminal"
grep -q 'Password: Secret123' "$TEST_DIR/terminal"
if grep -q Secret123 "$LOG"; then echo 'the database password is in the log'; exit 1; fi
# A later run replaces the list, and "off" closes the database again.
(main --remote-database 198.51.100.4)
expect_no_rule 203.0.113.7
[ "$(users)" = 198.51.100.4 ]
(main --remote-database off)
[ ! -s "$FAKE_DIR/rules" ]
[ ! -e "$MARIADB_REMOTE_CONF" ]
(source "$STATE_FILE"; [ -z "$REMOTE_DATABASE" ])
[ ! -s "$FAKE_DIR/steps" ]
# A wrong address changes nothing.
fails main --remote-database 2001:db8::1
(source "$STATE_FILE"; [ -z "$REMOTE_DATABASE" ])
# A local hotel has no remote database.
sed -i "s/^LOCAL=.*/LOCAL='yes'/" "$STATE_FILE"
fails main --remote-database 203.0.113.7
sed -i "s/^LOCAL=.*/LOCAL='no'/" "$STATE_FILE"
# Without an installed hotel, the option belongs to a full install.
rm "$STATE_FILE"
(SETUP_SSH=no; main --remote-database 203.0.113.7)
grep -qx install_cms "$FAKE_DIR/steps"

printf 'Bash remote database checks passed\n' >&4

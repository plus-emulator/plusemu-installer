#!/usr/bin/env bash
# Exercise the real installer functions without installing services or packages.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" >&4; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# Load definitions, excluding the entry point.
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

valid_password() {
    [[ ${#1} -ge 12 && $1 == *[A-Z]* && $1 == *[a-z]* &&
        $1 == *[0-9]* && $1 == *[^a-zA-Z0-9[:space:]]* ]]
}

for ((i = 0; i < 500; i++)); do
    password=$(admin_password)
    [[ ${#password} == 20 ]]
    valid_password "$password"
done
! valid_password 'OriginalAlpha123'
# A short entropy read must not silently yield a predictable password.
( random_secret() { :; }; ! admin_password )
[[ $(random_secret 32) =~ ^[A-Za-z0-9]{32}$ ]]
[[ $(random_secret 12) =~ ^[A-Za-z0-9]{12}$ ]]

STATE_FILE=$TEST_DIR/state/hotel.env
export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws
export PLUSEMU_HOTEL_NAME=Example PLUSEMU_ADMIN_USER=Ruiz
export PLUSEMU_ADMIN_EMAIL=ruiz@example.com PLUSEMU_YES=1
ask_questions
valid_password "$ADMIN_PASSWORD"
[[ $(stat -c %a "$STATE_FILE") == 600 ]]
[[ $(stat -c %a "$(dirname "$STATE_FILE")") == 700 ]]
initial=$ADMIN_PASSWORD
database=$DB_PASSWORD
token=$GUIDE_TOKEN
ask_questions
[[ $ADMIN_PASSWORD == "$initial" && $DB_PASSWORD == "$database" && $GUIDE_TOKEN == "$token" ]]

# Use the real CMS orchestration and stop at setup/optimize, before OS changes.
HOTEL_ROOT=$TEST_DIR/hotel
mkdir -p "$HOTEL_ROOT/cms"
touch "$HOTEL_ROOT/cms/.env"
composer() { :; }
npm() { :; }
sql() { printf '%s\n' "$COMPLETED"; }
php() {
    if [[ ${2:-} == atom:setup ]]; then
        valid_password "$ATOM_ADMIN_PASSWORD"
        [[ $ATOM_ADMIN_PASSWORD == "$ADMIN_PASSWORD" ]]
        printf '%s' "$ATOM_ADMIN_PASSWORD" > "$TEST_DIR/used-password"
        exit 0
    elif [[ ${2:-} == optimize:clear ]]; then
        exit 0
    fi
}
ADMIN_PASSWORD=OriginalAlpha123
save_state
COMPLETED=0
(install_cms)
source "$STATE_FILE"
valid_password "$ADMIN_PASSWORD"
[[ $ADMIN_PASSWORD == "$(cat "$TEST_DIR/used-password")" ]]
[[ $DB_PASSWORD == "$database" && $GUIDE_TOKEN == "$token" ]]
repaired=$ADMIN_PASSWORD
(install_cms)
source "$STATE_FILE"
[[ $ADMIN_PASSWORD == "$repaired" ]]

# Completed installations must keep even a legacy password unchanged.
ADMIN_PASSWORD=OriginalAlpha123
save_state
rm "$TEST_DIR/used-password"
COMPLETED=1
(install_cms)
source "$STATE_FILE"
[[ $ADMIN_PASSWORD == OriginalAlpha123 && ! -e "$TEST_DIR/used-password" ]]

systemctl() { :; }
SERVER_IP=192.0.2.1
finish
for secret in "$ADMIN_PASSWORD" "$DB_PASSWORD"; do
    grep -Fq "$secret" "$TEST_DIR/terminal"
    ! grep -Fq "$secret" "$TEST_DIR/log"
done
grep -Fq 'Host: 127.0.0.1    Port: 3306    Database: plus    Username: hotel' "$TEST_DIR/terminal"
grep -Fq "sudo cat $STATE_FILE" "$TEST_DIR/terminal"
TEMPLATES=$ROOT/templates
WS_HOST=$DOMAIN
write_guide
for secret in "$ADMIN_PASSWORD" "$DB_PASSWORD"; do
    ! grep -Fq "$secret" "$HOTEL_ROOT/setup-guide/index.html"
done
grep -Fq "$STATE_FILE" "$HOTEL_ROOT/setup-guide/index.html"
# Failure guidance must point to saved credentials without printing them.
sed '/^main "\$@"$/d' "$ROOT/install.sh" > "$TEST_DIR/installer-definitions.sh"
export TEST_DIR
bash >> "$TEST_DIR/log" 2>&1 <<'CHILD' && exit 1
    source "$TEST_DIR/installer-definitions.sh"
    STATE_FILE=$TEST_DIR/state/hotel.env
    LOG=$TEST_DIR/log
    exec 3>> "$TEST_DIR/terminal"
    set +e
    false
    on_error 123
CHILD
grep -Fq "Saved passwords: sudo cat $STATE_FILE" "$TEST_DIR/terminal"
! grep -Fq "$DB_PASSWORD" "$TEST_DIR/log"
printf 'Bash credential regression checks passed\n' >&4

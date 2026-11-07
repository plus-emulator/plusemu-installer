#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; install.sh is sourced
# Create and keep the hotel database (setup_database) against a throwaway MariaDB server.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
cleanup() {
    local code=$?
    if [ -f "$TEST_DIR/mariadb.pid" ]; then kill "$(< "$TEST_DIR/mariadb.pid")" 2> /dev/null || true; fi
    if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" >&4 2> /dev/null; fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
command -v mariadbd > /dev/null || PATH=$PATH:/usr/sbin
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

SOCKET=$TEST_DIR/mariadb.sock
mariadb-install-db --no-defaults --datadir="$TEST_DIR/data" --auth-root-authentication-method=normal > /dev/null
mariadbd --no-defaults --datadir="$TEST_DIR/data" --socket="$SOCKET" --skip-networking \
    --pid-file="$TEST_DIR/mariadb.pid" --log-error="$TEST_DIR/mariadb.err" &
for _ in $(seq 100); do
    if mariadb --socket="$SOCKET" -uroot -e 'SELECT 1' > /dev/null 2>&1; then break; fi
    sleep 0.1
done
sql() { mariadb --socket="$SOCKET" -uroot "$@"; }
systemctl() { :; }

HOTEL_ROOT=$TEST_DIR/hotel DB_PASSWORD=Secret123
mkdir -p "$HOTEL_ROOT/emulator/Database"
# Like the real fresh install: game content, no accounts and no server_status table.
cat > "$HOTEL_ROOT/emulator/Database/FreshInstall.sql" <<'SQL'
CREATE TABLE furniture (id INT PRIMARY KEY);
INSERT INTO furniture VALUES (1), (2), (3);
CREATE TABLE users (id INT PRIMARY KEY, username VARCHAR(25), `rank` INT);
SQL
count() { sql -N plus -e "SELECT COUNT(*) FROM $1"; }

# A first run imports the hotel database.
setup_database
[ "$(count furniture)" = 3 ]
[ "$(count users)" = 0 ]

# A rerun keeps the players, their ranks and every change the owner made.
sql plus -e "INSERT INTO users VALUES (1, 'johndoe', 7); DELETE FROM furniture WHERE id = 3"
setup_database
[ "$(sql -N plus -e "SELECT \`rank\` FROM users WHERE username = 'johndoe'")" = 7 ]
[ "$(count furniture)" = 2 ]
grep -q 'kept it as it is' "$TEST_DIR/terminal"

# An import that stopped halfway has no accounts yet, so a rerun imports it again.
sql -e 'DROP DATABASE plus; CREATE DATABASE plus'
sql plus -e 'CREATE TABLE furniture (id INT PRIMARY KEY)'
setup_database
[ "$(count furniture)" = 3 ]

printf 'Bash database checks passed\n' >&4

#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced install.sh functions
# Exercise the server hardening steps against fake sshd and session logs, without services or packages.
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

# ---------------------------------------------------------------- SSH

SSHD_DROPIN=$TEST_DIR/sshd_config.d/10-plusemu.conf
SESSION_LOG=''     # what the log says about the sshd process this run descends from
SSHD_VALID=1
HOMES=$TEST_DIR/home
sshd() {
    printf 'sshd %s\n' "$*" >> "$TEST_DIR/calls"
    if [ "$1" = -t ]; then [ "$SSHD_VALID" = 1 ]; return; fi
    if [ -f "$SSHD_DROPIN" ] && grep -q 'PasswordAuthentication no' "$SSHD_DROPIN"; then echo 'passwordauthentication no'; else echo 'passwordauthentication yes'; fi
}
systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_DIR/calls"; }
session_sshd_pids() { echo 4242; }
sshd_session_log() { [ "$1" = 4242 ] && printf '%s\n' "$SESSION_LOG"; }
getent() { [ "$1" = passwd ] && printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "$HOMES/$2"; }

run_ssh() { : > "$TEST_DIR/calls"; : > "$TEST_DIR/terminal"; harden_ssh; }
expect_setting() { grep -qx "$1" "$SSHD_DROPIN" || { echo "expected setting: $1"; cat "$SSHD_DROPIN"; exit 1; }; }
expect_no_setting() { if [ -f "$SSHD_DROPIN" ] && grep -q "$1" "$SSHD_DROPIN"; then echo "unexpected setting: $1"; exit 1; fi; }
expect_call() { grep -qx -- "$1" "$TEST_DIR/calls" || { echo "expected call: $1"; cat "$TEST_DIR/calls"; exit 1; }; }
expect_no_call() { if grep -qx -- "$1" "$TEST_DIR/calls"; then echo "unexpected call: $1"; exit 1; fi; }

# This session logged in with a key: password login goes off.
unset SUDO_USER SSH_AUTH_INFO_0
SESSION_LOG='Accepted publickey for root from 192.0.2.7 port 51000 ssh2: ED25519 SHA256:abc'
run_ssh
expect_setting 'PermitRootLogin prohibit-password'
expect_setting 'PasswordAuthentication no'
expect_setting 'KbdInteractiveAuthentication no'
expect_call 'sshd -t'
expect_call 'systemctl try-reload-or-restart ssh.service'
[ "$SSH_PASSWORDS" = off ]

# A rerun from a session that used a password keeps password login off.
SESSION_LOG='Accepted password for root from 192.0.2.7 port 51000 ssh2'
run_ssh
expect_setting 'PasswordAuthentication no'

# Root logged in with a password and has no other way in: nothing changes.
rm -f "$SSHD_DROPIN"
run_ssh
[ ! -e "$SSHD_DROPIN" ]
expect_no_call 'systemctl try-reload-or-restart ssh.service'
[ "$SSH_PASSWORDS" = on ]
grep -q 'password login stays on' "$TEST_DIR/terminal"

# A sudo user without SSH keys logs in as itself: root may only use a key, passwords stay on.
SUDO_USER=alice
mkdir -p "$HOMES/alice/.ssh"
printf '# no keys yet\n\n' > "$HOMES/alice/.ssh/authorized_keys"
run_ssh
expect_setting 'PermitRootLogin prohibit-password'
expect_no_setting 'PasswordAuthentication'
[ "$SSH_PASSWORDS" = on ]
grep -q 'password login stays on' "$TEST_DIR/terminal"

# The sudo user has an SSH key: password login goes off, even when this session used a password.
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample alice@laptop\n' >> "$HOMES/alice/.ssh/authorized_keys"
run_ssh
expect_setting 'PasswordAuthentication no'
[ "$SSH_PASSWORDS" = off ]

# A key login exposed by sshd (ExposeAuthInfo) counts as well.
unset SUDO_USER
rm -f "$SSHD_DROPIN"
SESSION_LOG=''
SSH_AUTH_INFO_0='publickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample'
run_ssh
expect_setting 'PasswordAuthentication no'
unset SSH_AUTH_INFO_0

# sshd rejects the settings: the previous file comes back and sshd is not reloaded.
before=$(< "$SSHD_DROPIN")
SESSION_LOG='Accepted publickey for root from 192.0.2.7 port 51000 ssh2: ED25519 SHA256:abc'
SSHD_VALID=0
run_ssh
[ "$(< "$SSHD_DROPIN")" = "$before" ]
expect_no_call 'systemctl try-reload-or-restart ssh.service'
SSHD_VALID=1

# No SSH server: nothing is written.
rm -f "$SSHD_DROPIN"
(
    sshd_installed() { false; }
    run_ssh
    [ ! -e "$SSHD_DROPIN" ] && [ "$SSH_PASSWORDS" = none ]
)

# ---------------------------------------------------------------- logs

LOGROTATE_CONF=$TEST_DIR/logrotate.d/plusemu
JOURNALD_DROPIN=$TEST_DIR/journald.conf.d/90-plusemu.conf
HOTEL_ROOT=$TEST_DIR/hotel
mkdir -p "$(dirname "$LOGROTATE_CONF")"

# The first run writes the journal limits and restarts the journal.
: > "$TEST_DIR/calls"
rotate_logs
grep -qx 'SystemMaxUse=1G' "$JOURNALD_DROPIN"
grep -q '/var/log/plusemu-\*.log' "$LOGROTATE_CONF"
expect_call 'systemctl restart systemd-journald'

# A rerun leaves the journal running under the emulator.
: > "$TEST_DIR/calls"
rotate_logs
expect_no_call 'systemctl restart systemd-journald'

# Changed limits are written again and the journal restarts.
echo 'SystemMaxUse=4G' >> "$JOURNALD_DROPIN"
rotate_logs
expect_call 'systemctl restart systemd-journald'
[ "$(grep -c SystemMaxUse "$JOURNALD_DROPIN")" = 1 ]

# ---------------------------------------------------------------- nightly backups

HOTEL_ROOT=$TEST_DIR/hotel
STATE_FILE=$TEST_DIR/etc/plusemu/hotel.env
VERSIONS_FILE=$TEST_DIR/etc/plusemu/versions.env
SSL_DIR=$TEST_DIR/etc/ssl/plusemu
BACKUP_ROOT=$TEST_DIR/backups
NIGHTLY_ROOT=$BACKUP_ROOT/nightly
BACKUP_COMMAND=$TEST_DIR/sbin/plusemu-backup
BACKUP_CRON=$TEST_DIR/cron.d/plusemu-backup
BACKUP_LOG=$TEST_DIR/plusemu-backup.log
LOCK_FILE=$TEST_DIR/update.lock
KEEP_BACKUPS=3
mkdir -p "$HOTEL_ROOT"/{emulator/Config,emulator/backups,client/configuration,client/assets,cms/storage/app/public,cms/storage/logs,hotel-files/gamedata,hotel-files/assets} \
    "$(dirname "$STATE_FILE")" "$SSL_DIR" "$TEST_DIR/fakebin"
echo '{"Database": {}}' > "$HOTEL_ROOT/emulator/Config/config.json"
echo 'binary' > "$HOTEL_ROOT/emulator/Plus Emulator"
echo 'old dump' > "$HOTEL_ROOT/emulator/backups/old.sql"
echo '{}' > "$HOTEL_ROOT/client/configuration/ui-config.json"
echo 'bundle' > "$HOTEL_ROOT/client/assets/index.js"
echo 'APP_KEY=secret' > "$HOTEL_ROOT/cms/.env"
echo 'avatar' > "$HOTEL_ROOT/cms/storage/app/public/avatar.png"
echo 'log' > "$HOTEL_ROOT/cms/storage/logs/laravel.log"
echo 'texts' > "$HOTEL_ROOT/hotel-files/gamedata/ExternalTexts.json"
echo 'furni' > "$HOTEL_ROOT/hotel-files/assets/chair.hab"
echo "DB_PASSWORD='x'" > "$STATE_FILE"
echo "EMULATOR_VERSION='v1'" > "$VERSIONS_FILE"
echo 'certificate' > "$SSL_DIR/cert.pem"
# The update's own snapshots and gamedata copies share the backup folder.
mkdir -p "$BACKUP_ROOT/20260101-000000-000000000" "$BACKUP_ROOT/gamedata-abc"
cat > "$TEST_DIR/fakebin/mariadb-dump" <<'FAKE'
#!/usr/bin/env bash
echo 'CREATE TABLE users (id INT);'
FAKE
cat > "$TEST_DIR/fakebin/mariadb" <<'FAKE'
#!/usr/bin/env bash
echo 1
FAKE
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH

backups() { find "$NIGHTLY_ROOT" -mindepth 1 -maxdepth 1 -type d | sort; }

# The installed command runs on its own, as cron runs it.
install_backup_command
[ -x "$BACKUP_COMMAND" ]
grep -Fq "0 4 * * * root $BACKUP_COMMAND" "$BACKUP_CRON"
for ((i = 0; i < 9; i++)); do "$BACKUP_COMMAND" >> "$BACKUP_LOG" 2>&1; done
[ "$(backups | wc -l)" = 7 ]
latest=$(backups | tail -1)
[[ ${latest##*/} =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]]
[ "$(gunzip -c "$latest/database.sql.gz")" = 'CREATE TABLE users (id INT);' ]
files=$(tar -tzf "$latest/hotel.tar.gz")
for kept in emulator/Config/config.json client/configuration/ui-config.json cms/.env cms/storage/app/public/avatar.png hotel-files/gamedata/ExternalTexts.json; do
    grep -qx "$kept" <<< "$files" || { echo "missing from the backup: $kept"; exit 1; }
done
# Files that come back with a download or an update are left out.
for left in 'emulator/Plus Emulator' emulator/backups/old.sql client/assets/index.js hotel-files/assets/chair.hab cms/storage/logs/laravel.log; do
    if grep -qx "$left" <<< "$files"; then echo "backed up a downloadable file: $left"; exit 1; fi
done
settings=$(tar -tzf "$latest/settings.tar.gz")
for kept in "${STATE_FILE#/}" "${VERSIONS_FILE#/}" "${SSL_DIR#/}/cert.pem"; do
    grep -qx "$kept" <<< "$settings" || { echo "missing from the settings backup: $kept"; exit 1; }
done
[ "$(stat -c %a "$NIGHTLY_ROOT")" = 700 ]

# Pruning keeps the update's snapshots, and the update's pruning keeps the nightly backups.
[ -d "$BACKUP_ROOT/20260101-000000-000000000" ] && [ -d "$BACKUP_ROOT/gamedata-abc" ]
prune_snapshots
[ "$(backups | wc -l)" = 7 ]

# An unfinished backup is removed by the next one.
mkdir "$NIGHTLY_ROOT/20260102-000000-000000000.partial"
"$BACKUP_COMMAND" >> "$BACKUP_LOG" 2>&1
[ ! -e "$NIGHTLY_ROOT/20260102-000000-000000000.partial" ]
[ "$(backups | wc -l)" = 7 ]

# A failed database dump keeps the previous backups and reports the failure.
printf '#!/usr/bin/env bash\nexit 2\n' > "$TEST_DIR/fakebin/mariadb-dump"
before=$(backups)
if "$BACKUP_COMMAND" >> "$BACKUP_LOG" 2>&1; then echo 'a failed dump was reported as a backup'; exit 1; fi
[ "$(backups | grep -v '\.partial$')" = "$before" ]

# A running update holds the lock: the backup waits, then gives up without a new backup.
printf '#!/usr/bin/env bash\necho dump\n' > "$TEST_DIR/fakebin/mariadb-dump"
flock "$LOCK_FILE" sleep 3 &
sleep 0.5
before=$(backups | grep -v '\.partial$')
if BACKUP_LOCK_WAIT=1 "$BACKUP_COMMAND" >> "$BACKUP_LOG" 2>&1; then echo 'backed up during an update'; exit 1; fi
[ "$(backups | grep -v '\.partial$')" = "$before" ]
wait

printf 'Bash hardening checks passed\n' >&4

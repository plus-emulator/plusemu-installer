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

printf 'Bash hardening checks passed\n' >&4

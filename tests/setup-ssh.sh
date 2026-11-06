#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced install.sh functions
# Set up key-only SSH login (--setup-ssh) against a fake sshd, without services or real accounts.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/calls" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

SSHD_DROPIN=$TEST_DIR/sshd_config.d/10-plusemu.conf
HOMES=$TEST_DIR/home
SSHD_VALID=1
SERVER_IP=192.0.2.1
: > "$TEST_DIR/calls"
sshd() {
    printf 'sshd %s\n' "$*" >> "$TEST_DIR/calls"
    if [ "$1" = -t ]; then [ "$SSHD_VALID" = 1 ]; return; fi
    if [ -f "$SSHD_DROPIN" ] && grep -q 'PasswordAuthentication no' "$SSHD_DROPIN"; then echo 'passwordauthentication no'; else echo 'passwordauthentication yes'; fi
}
sshd_installed() { true; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_DIR/calls"; }
chown() { printf 'chown %s\n' "$*" >> "$TEST_DIR/calls"; }
getent() { [ "$1" = passwd ] && printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "$HOMES/$2"; }
id() { echo staff; }

ssh-keygen -q -t ed25519 -N '' -C 'johndoe@laptop' -f "$TEST_DIR/id_ed25519"
KEY=$(< "$TEST_DIR/id_ed25519.pub")
keys() { cat "$HOMES/$1/.ssh/authorized_keys"; }
expect_call() { grep -qx -- "$1" "$TEST_DIR/calls" || { echo "expected call: $1"; cat "$TEST_DIR/calls"; exit 1; }; }
fails() { if (exec 3> /dev/null; "$@") > /dev/null 2>&1; then echo "expected a failure: $*"; exit 1; fi; }
answers() { printf '%s\n' "$@" > "$TEST_DIR/answers"; }
TTY=$TEST_DIR/answers

# The flag is for servers; a local install leaves the PC's SSH alone.
LOCAL=yes SETUP_SSH_OPTION=1
fails select_setup_ssh
LOCAL=no
select_setup_ssh
[ "$SETUP_SSH" = yes ]
SETUP_SSH_OPTION='' PLUSEMU_SETUP_SSH=''
select_setup_ssh
[ "$SETUP_SSH" = no ]

# The question explains how to make a key on Windows and Linux, then takes the pasted public key.
unset PLUSEMU_SSH_KEY
SUDO_USER=johndoe
TTY=/dev/stdin ask_ssh_key < <(printf '%s\n' 'not a key' '-----BEGIN OPENSSH PRIVATE KEY-----' 'ssh-ed25519 AAAAbroken' "  $KEY  ")
[ "$SSH_KEY" = "$KEY" ]
grep -q 'Windows' "$TEST_DIR/terminal"
grep -qF 'ssh-keygen -t ed25519' "$TEST_DIR/terminal"
grep -qF 'Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub' "$TEST_DIR/terminal"
grep -qF 'cat ~/.ssh/id_ed25519.pub' "$TEST_DIR/terminal"
grep -q 'private key' "$TEST_DIR/terminal"
grep -q 'johndoe' "$TEST_DIR/terminal"
# An unattended run takes the key from PLUSEMU_SSH_KEY, and fails on a wrong one.
PLUSEMU_SSH_KEY=$KEY ask_ssh_key < /dev/null
[ "$SSH_KEY" = "$KEY" ]
PLUSEMU_SSH_KEY='ssh-rsa nope'
fails ask_ssh_key < /dev/null
unset PLUSEMU_SSH_KEY

# The owner logs in with the key: the key is added once, and password login is off.
mkdir -p "$HOMES/johndoe"
SSH_KEY=$KEY
answers y
setup_ssh_key
[ "$(keys johndoe)" = "$KEY" ]
[ "$(stat -c %a "$HOMES/johndoe/.ssh")" = 700 ]
[ "$(stat -c %a "$HOMES/johndoe/.ssh/authorized_keys")" = 600 ]
expect_call "chown johndoe:staff $HOMES/johndoe/.ssh $HOMES/johndoe/.ssh/authorized_keys"
grep -qx 'PasswordAuthentication no' "$SSHD_DROPIN"
grep -qx 'KbdInteractiveAuthentication no' "$SSHD_DROPIN"
grep -qx 'PermitRootLogin prohibit-password' "$SSHD_DROPIN"
expect_call 'systemctl try-reload-or-restart ssh.service'
grep -qF "ssh johndoe@192.0.2.1" "$TEST_DIR/terminal"
grep -q 'password login is off' "$TEST_DIR/terminal"
# The later hardening step keeps it that way, and a second run adds no second copy of the key.
harden_ssh
grep -qx 'PasswordAuthentication no' "$SSHD_DROPIN"
setup_ssh_key
[ "$(keys johndoe)" = "$KEY" ]

# The key login does not work: password login comes back and the new key goes, so nobody is locked out.
rm -f "$SSHD_DROPIN"
: > "$HOMES/johndoe/.ssh/authorized_keys"
: > "$TEST_DIR/terminal"
answers n
setup_ssh_key
[ -z "$(keys johndoe)" ]
[ ! -e "$SSHD_DROPIN" ]
grep -q 'Password login stays on' "$TEST_DIR/terminal"
harden_ssh
if grep -q 'PasswordAuthentication no' "$SSHD_DROPIN"; then echo 'password login went off after a failed key login'; exit 1; fi
# Keys that were there before stay; a file without a final newline still gets the key on its own line.
rm -f "$SSHD_DROPIN"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld old@pc' > "$HOMES/johndoe/.ssh/authorized_keys"
answers n
setup_ssh_key
[ "$(keys johndoe)" = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld old@pc' ]
answers y
setup_ssh_key
[ "$(keys johndoe)" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld old@pc
$KEY" ]

# sshd does not accept the settings: SSH stays as it was.
rm -f "$SSHD_DROPIN"
SSHD_VALID=0
answers y
setup_ssh_key
[ ! -e "$SSHD_DROPIN" ]
SSHD_VALID=1

# An unattended run with PLUSEMU_YES=1 cannot ask, so it trusts the key it was given.
rm -f "$SSHD_DROPIN"
: > "$HOMES/johndoe/.ssh/authorized_keys"
PLUSEMU_YES=1 TTY=/dev/null setup_ssh_key
[ "$(keys johndoe)" = "$KEY" ]
grep -qx 'PasswordAuthentication no' "$SSHD_DROPIN"

# Without sudo, the key goes to root.
unset SUDO_USER
mkdir -p "$HOMES/root"
answers y
setup_ssh_key
[ "$(keys root)" = "$KEY" ]
grep -qF "ssh root@192.0.2.1" "$TEST_DIR/terminal"

printf 'Bash SSH setup checks passed\n' >&4

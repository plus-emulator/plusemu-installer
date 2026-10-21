#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced php-update.sh functions
# Exercise php-update.sh against fake dpkg/apt/php.net answers, without packages, services or network.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$ROOT/php-update.sh")

CALLS=$TEST_DIR/calls
INSTALLED=8.2.29-1~deb12u1   # the version dpkg reports
CANDIDATE=8.2.29-1~deb12u1   # the version apt offers
LATEST=8.2.35                # the version php.net reports
REPO_PRESENT=0

installed_branches() { printf '%s' "$BRANCHES"; }
installed_version() { printf '%s' "$INSTALLED"; }
candidate_version() { printf '%s' "$CANDIDATE"; }
latest_version() { printf '%s' "$LATEST"; }
third_party_repo_present() { [ "$REPO_PRESENT" = 1 ]; }
add_third_party_repo() { echo "add-repo" >> "$CALLS"; REPO_PRESENT=1; CANDIDATE=8.2.35-1+0~20261021; }
apt-get() { echo "apt-get $*" >> "$CALLS"; [ "$1" != install ] || INSTALLED=$CANDIDATE; }
systemctl() { echo "systemctl $*" >> "$CALLS"; }
php-fpm8.2() { :; }
id() { echo 0; }
dpkg-query() { printf 'php8.2-fpm installed\nphp8.2-cli installed\n'; }

run() { : > "$CALLS"; CHECK=0; ( main "$@" ) > "$TEST_DIR/out" 2>&1; }   # subshell: die exits
expect_call() { grep -qx -- "$1" "$CALLS" || { echo "expected call: $1"; cat "$CALLS"; exit 1; }; }
expect_no_call() { ! grep -qx -- "$1" "$CALLS" || { echo "unexpected call: $1"; exit 1; }; }
expect_out() { grep -q -- "$1" "$TEST_DIR/out" || { echo "expected output: $1"; cat "$TEST_DIR/out"; exit 1; }; }

# Debian package behind php.net: add the Sury packages, upgrade, restart fpm.
BRANCHES="8.2"; run
expect_call "add-repo"
expect_call "apt-get install -y --only-upgrade php8.2-fpm php8.2-cli"
expect_call "systemctl restart php8.2-fpm"
expect_out "PHP 8.2 is now 8.2.35"

# Already current: no changes.
INSTALLED=8.2.35-1+0~20261021; run
expect_no_call "apt-get install -y --only-upgrade php8.2-fpm php8.2-cli"
expect_out "Already up to date"

# --check reports and changes nothing.
INSTALLED=8.2.29-1~deb12u1; CANDIDATE=8.2.29-1~deb12u1; REPO_PRESENT=0; run --check
expect_no_call "add-repo"
expect_no_call "apt-get install -y --only-upgrade php8.2-fpm php8.2-cli"
expect_out "Would add the Sury"

# Release exists on php.net but the packages are not built yet: say so and fail.
REPO_PRESENT=1; CANDIDATE=8.2.34-1+0~20260924
if run; then echo "expected a failure when no package exists yet"; exit 1; fi
expect_no_call "apt-get install -y --only-upgrade php8.2-fpm php8.2-cli"
expect_out "no package for it exists yet"

# PHP 8.1 is out of support: refuse and tell the user.
BRANCHES="8.1"; INSTALLED=8.1.34; LATEST=8.1.34
if run; then echo "expected a failure for PHP 8.1"; exit 1; fi
expect_out "gets no security fixes any more"
expect_no_call "add-repo"

# version_lt handles patch numbers above 9.
version_lt 8.2.9 8.2.35 && ! version_lt 8.2.35 8.2.9 && ! version_lt 8.5.12 8.5.12

echo "php-update tests passed"

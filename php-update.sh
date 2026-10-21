#!/usr/bin/env bash
# Updates PHP to the newest patch release of the PHP version that is installed.
# For Debian 12/13 and Ubuntu 22.04/24.04/26.04 with php-fpm (any hotel, not only
# ones made by install.sh).
#
#   curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/php-update.sh | sudo bash
#   sudo bash php-update.sh [--check]
#
# What it does:
#   - Finds every installed PHP 8.x (php8.x-fpm or php8.x-cli packages).
#   - PHP older than 8.2 gets no security fixes any more: the script says so and
#     stops. Update that server by hand (see README.md).
#   - Reads the newest release of that PHP version from php.net.
#   - If your Linux packages are behind php.net, it adds the Sury (Debian) or
#     Ondřej (Ubuntu) PHP packages. install.sh uses the same packages.
#   - Upgrades the php8.x packages, restarts php8.x-fpm and checks the version.
#   --check only reports. It changes nothing.
set -Eeuo pipefail

PHP_RELEASES_URL=https://www.php.net/releases/index.php
OLDEST_SUPPORTED=8.2
CHECK=0

bold=$'\e[1m' green=$'\e[32m' red=$'\e[31m' yellow=$'\e[33m' reset=$'\e[0m'
say() { printf '%s\n' "$*"; }
ok() { say "  ${green}✓${reset} $*"; }
warn() { say "  ${yellow}!${reset} $*"; }
die() { say "${red}${bold}✗ $*${reset}" >&2; exit 1; }

# version_lt <a> <b>: true when a is older than b (dotted numbers only).
version_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

# installed_branches: the major.minor of every PHP that has fpm or cli packages, e.g. "8.2 8.5".
installed_branches() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' 'php[0-9]*.[0-9]*-fpm' 'php[0-9]*.[0-9]*-cli' 2> /dev/null \
        | awk '$2 == "installed" { sub(/^php/, "", $1); sub(/-(fpm|cli)$/, "", $1); print $1 }' | sort -uV | tr '\n' ' '
}

# installed_version <branch>: the upstream version of php<branch>-cli, e.g. 8.2.29.
installed_version() { dpkg-query -W -f='${Version}' "php$1-cli" 2> /dev/null || dpkg-query -W -f='${Version}' "php$1-fpm"; }
# candidate_version <branch>: the newest php<branch>-cli apt can install, after apt-get update.
candidate_version() { apt-cache policy "php$1-cli" | awk '/Candidate:/ { print $2 }'; }
# upstream <debian version>: "8.2.29-1~deb12u1" -> "8.2.29".
upstream() { printf '%s' "$1" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true; }

# latest_version <branch>: the newest release of that branch on php.net, e.g. 8.2.35.
latest_version() {
    curl -fsS --max-time 20 "$PHP_RELEASES_URL?json&version=$1" \
        | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4
}

third_party_repo_present() {
    grep -rqsE 'packages\.sury\.org/php|ppa\.launchpadcontent\.net/ondrej/php|ppa\.launchpad\.net/ondrej/php' /etc/apt/sources.list /etc/apt/sources.list.d/
}

add_third_party_repo() {
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" = ubuntu ]; then
        apt-get install -y software-properties-common
        add-apt-repository -y ppa:ondrej/php
    elif [ "${ID:-}" = debian ]; then
        apt-get install -y ca-certificates curl gnupg
        curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME:?} main" > /etc/apt/sources.list.d/sury-php.list
    else
        die "This script supports Debian and Ubuntu only (found ${PRETTY_NAME:-unknown})."
    fi
    apt-get update
}

# update_branch <branch>: brings php<branch> to the newest php.net release. Returns 1 when that is not possible yet.
update_branch() {
    local branch=$1 installed latest candidate packages
    installed=$(upstream "$(installed_version "$branch")")
    latest=$(latest_version "$branch")
    [ -n "$latest" ] || die "Could not read the newest PHP $branch release from php.net. Check the internet connection and run again."
    say ""
    say "${bold}PHP $branch${reset}: installed $installed, newest release $latest"

    if version_lt "$branch" "$OLDEST_SUPPORTED"; then
        warn "PHP $branch gets no security fixes any more. Update to PHP $OLDEST_SUPPORTED or newer by hand."
        warn "A newer PHP needs a check of your website code first, so this script does not do it."
        return 1
    fi
    if ! version_lt "$installed" "$latest"; then
        ok "Already up to date."
        return 0
    fi

    candidate=$(upstream "$(candidate_version "$branch")")
    if version_lt "${candidate:-0}" "$latest" && ! third_party_repo_present; then
        say "  Your Linux packages offer PHP ${candidate:-none}. Adding the Sury/Ondřej PHP packages for $latest."
        if [ "$CHECK" = 1 ]; then
            warn "Would add the Sury/Ondřej PHP packages and upgrade to PHP $latest (--check: nothing changed)."
            return 0
        fi
        add_third_party_repo
        candidate=$(upstream "$(candidate_version "$branch")")
    fi
    if version_lt "${candidate:-0}" "$latest"; then
        warn "PHP $latest is released, but no package for it exists yet (packages offer ${candidate:-none})."
        warn "Packages usually follow within a day. Run this script again later."
        return 1
    fi
    if [ "$CHECK" = 1 ]; then
        warn "Would upgrade PHP $installed to $latest (--check: nothing changed)."
        return 0
    fi

    packages=$(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' "php$branch-*" | awk '$2 == "installed" { print $1 }')
    # shellcheck disable=SC2086 # one package per word
    apt-get install -y --only-upgrade $packages
    installed=$(upstream "$(installed_version "$branch")")
    [ "$installed" = "$latest" ] || die "PHP $branch is $installed after the upgrade, expected $latest. Check 'apt-cache policy php$branch-cli'."
    if systemctl list-unit-files "php$branch-fpm.service" > /dev/null 2>&1; then
        "php-fpm$branch" -t > /dev/null 2>&1 || die "php-fpm$branch -t failed. The service was not restarted; check the FPM configuration."
        systemctl restart "php$branch-fpm"
        ok "php$branch-fpm restarted."
    fi
    ok "PHP $branch is now $installed."
}

main() {
    [ "${1:-}" != --check ] || CHECK=1
    [ "$(id -u)" = 0 ] || die "Run this script as root: sudo bash php-update.sh"
    { command -v dpkg-query && command -v apt-get; } > /dev/null || die "This script supports Debian and Ubuntu only."
    export DEBIAN_FRONTEND=noninteractive

    local branches branch failed=0
    branches=$(installed_branches)
    [ -n "$branches" ] || die "No PHP packages found (php8.x-fpm or php8.x-cli). Nothing to update."
    say "Checking package lists..."
    apt-get update > /dev/null
    for branch in $branches; do
        update_branch "$branch" || failed=1
    done
    say ""
    [ "$failed" = 0 ] || die "Not every PHP version is up to date. See the messages above."
    ok "Done."
}

main "$@"

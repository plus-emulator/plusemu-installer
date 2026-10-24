#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; the state file is sourced
# A local install that stops at the port check keeps no settings, so the PC can still get a server install.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

export FAKE_DIR=$TEST_DIR/fake
STATE_FILE=$TEST_DIR/etc/hotel.env
LOG=$TEST_DIR/install.log
LOCK_FILE=$TEST_DIR/update.lock
TTY=/dev/null
NGINX_DIR=$TEST_DIR/nginx
mkdir -p "$TEST_DIR/fakebin" "$FAKE_DIR" "$NGINX_DIR/sites-enabled"
# Apache holds port 80.
printf '#!/usr/bin/env bash\necho "LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:((\\"apache2\\",pid=777,fd=4))"\n' > "$TEST_DIR/fakebin/ss"
chmod +x "$TEST_DIR/fakebin/ss"
export PATH=$TEST_DIR/fakebin:$PATH
for step in preflight load_installer_files derive_settings install_packages install_toolchains download_releases setup_database \
    download_hotel_files start_emulator write_client_config install_cms configure_web secure_server write_guide install_update_command \
    connect_cloudflare finish; do
    eval "$step() { echo '$step' >> \"\$FAKE_DIR/steps\"; }"
done
export PLUSEMU_YES=1

# The first run stops before anything is installed and leaves no saved choice behind.
if (main --local); then echo 'the install went on with port 80 in use'; exit 1; fi
grep -qF 'apache2' "$TEST_DIR/terminal"
[ ! -e "$STATE_FILE" ] || { echo 'a stopped first run saved its settings'; exit 1; }
if grep -qsx install_packages "$FAKE_DIR/steps"; then echo 'the install started before the port check'; exit 1; fi

# A server install still works on this PC afterwards.
rm -f "$FAKE_DIR/steps"
(
    export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws PLUSEMU_HOTEL_NAME=Example
    export PLUSEMU_ADMIN_USER=admin PLUSEMU_ADMIN_EMAIL=admin@example.com
    main
)
grep -qx connect_cloudflare "$FAKE_DIR/steps"

# A rerun of an installed local hotel keeps its settings when a port is taken.
rm "$STATE_FILE"
PLUSEMU_LOCAL=1 ask_questions > /dev/null
before=$(sha256sum "$STATE_FILE")
if (main); then echo 'the rerun went on with port 80 in use'; exit 1; fi
[ "$(sha256sum "$STATE_FILE")" = "$before" ]

printf 'Bash local first run checks passed\n' >&4

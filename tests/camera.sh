#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced install.sh functions
# Set up the camera service against fake npm, npx, runuser and systemctl programs, and check what it writes.
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

HOTEL_ROOT=$TEST_DIR/hotel
CAMERA_ENV=$TEST_DIR/etc/camera.env
CAMERA_BROWSERS=$TEST_DIR/browsers
CAMERA_APPARMOR=$TEST_DIR/apparmor
mkdir -p "$TEST_DIR/fakebin" "$HOTEL_ROOT/emulator/Config" "$HOTEL_ROOT/emulator/CameraRenderer"
for program in npm npx systemctl apparmor_parser; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$program" "$TEST_DIR" > "$TEST_DIR/fakebin/$program"
done
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH
SANDBOX=works
runuser() { echo "runuser $*" >> "$TEST_DIR/calls"; [ "$SANDBOX" = works ]; }
chown() { :; }
install() { if [ "$1" = -d ]; then mkdir -p "${@: -1}"; fi; }
port_answers() { [ "$1" = 3921 ]; }
# The service unit goes into the test folder instead of /etc.
eval "$(declare -f camera_service | sed "s#/etc/systemd/system/plusemu-camera.service#$TEST_DIR/unit#")"
config=$HOTEL_ROOT/emulator/Config/config.json
env_value() { sed -n "s/^$1=//p" "$CAMERA_ENV"; }

# A new hotel gets a camera password and a photo folder that nginx serves.
echo '{"Camera":{"RendererUrl":"http://127.0.0.1:3921/render","Bearer":"","OutputDirectory":"camera"}}' > "$config"
chmod 600 "$config"
camera_settings "$config"
bearer=$(jq -r .Camera.Bearer "$config")
[ "${#bearer}" = 48 ]
[ "$(jq -r .Camera.OutputDirectory "$config")" = "$HOTEL_ROOT/camera" ]
[ "$(jq -r .Camera.RendererUrl "$config")" = http://127.0.0.1:3921/render ]
[ "$(stat -c %a "$config")" = 600 ]

# A rerun or an update keeps them, and the owner's own settings too.
camera_settings "$config"
[ "$(jq -r .Camera.Bearer "$config")" = "$bearer" ]
jq '.Camera.OutputDirectory = "/srv/photos"' "$config" > "$config.new" && mv "$config.new" "$config"
camera_settings "$config"
[ "$(jq -r .Camera.OutputDirectory "$config")" = /srv/photos ]
jq '.Camera.OutputDirectory = "camera"' "$config" > "$config.new" && mv "$config.new" "$config"

# An emulator release without the camera service skips the step.
install_camera
grep -q 'Skipped: this PlusEMU release has no camera service yet' "$TEST_DIR/terminal"
[ ! -e "$CAMERA_ENV" ]

# The service reads the installer's hotel files and the installed client, with the emulator's password.
: > "$TEST_DIR/terminal"
touch "$HOTEL_ROOT/emulator/CameraRenderer/server.mjs"
install_camera
grep -q 'Players can take photos (service plusemu-camera)' "$TEST_DIR/terminal"
[ "$(env_value CAMERA_RENDERER_SECRET)" = "$bearer" ]
[ "$(env_value CAMERA_ASSET_LAYOUT)" = hotel-files ]
[ "$(env_value CAMERA_ASSET_ROOT)" = "$HOTEL_ROOT/hotel-files" ]
[ "$(env_value CAMERA_IMAGES_ROOT)" = "$HOTEL_ROOT/hotel-files/c_images" ]
[ "$(env_value CAMERA_MEDIA_ROOT)" = "$HOTEL_ROOT/camera" ]
[ "$(env_value CAMERA_PAGE_ROOT)" = "$HOTEL_ROOT/client" ]
[ "$(env_value CAMERA_UI_CONFIG)" = "$HOTEL_ROOT/client/configuration/ui-config.json" ]
[ "$(env_value CAMERA_CHROMIUM_SANDBOX)" = 1 ]
[ "$(stat -c %a "$CAMERA_ENV")" = 600 ]
grep -qx "WorkingDirectory=$HOTEL_ROOT/emulator/CameraRenderer" "$TEST_DIR/unit"
grep -qx "EnvironmentFile=$CAMERA_ENV" "$TEST_DIR/unit"
grep -qx 'User=plusemu' "$TEST_DIR/unit"
grep -q 'npm ci --omit=dev' "$TEST_DIR/calls"
grep -q 'npx playwright install --with-deps --only-shell chromium' "$TEST_DIR/calls"
grep -q 'systemctl restart plusemu-camera' "$TEST_DIR/calls"

# Where Chromium cannot use its sandbox, the service runs without it.
SANDBOX=fails
install_camera
[ "$(env_value CAMERA_CHROMIUM_SANDBOX)" = 0 ]

# A failed setup warns and lets the rest of the install go on.
: > "$TEST_DIR/terminal"
port_answers() { return 1; }
sleep() { :; }
install_camera
grep -q 'The camera could not be set up, so photos do not work yet' "$TEST_DIR/terminal"

# An update to an emulator without the camera service turns the service off.
rm "$HOTEL_ROOT/emulator/CameraRenderer/server.mjs"
: > "$TEST_DIR/calls"
refresh_camera
grep -q 'systemctl disable --now plusemu-camera' "$TEST_DIR/calls"

printf 'Bash camera checks passed\n' >&4

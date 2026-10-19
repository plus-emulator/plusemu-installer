#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 3>/dev/null
STATE_FILE=$TEST_DIR/hotel.env
export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws
export PLUSEMU_HOTEL_NAME=Example PLUSEMU_ADMIN_USER=Admin
export PLUSEMU_ADMIN_EMAIL=admin@example.com PLUSEMU_YES=1
export PLUSEMU_GUIDE_MODE=advanced
ask_questions >/dev/null
if [[ ${GUIDE_MODE:-missing} != advanced ]]; then
    echo 'Guide mode: explicit advanced choice was ignored' >&2
    exit 1
fi
initial=$ADMIN_PASSWORD
unset PLUSEMU_GUIDE_MODE
GUIDE_MODE=
ask_questions >/dev/null
[[ $GUIDE_MODE == advanced && $ADMIN_PASSWORD == "$initial" ]]
export PLUSEMU_GUIDE_MODE=simple
ask_questions >/dev/null
[[ $GUIDE_MODE == simple && $ADMIN_PASSWORD == "$initial" ]]
unset PLUSEMU_GUIDE_MODE
GUIDE_MODE=
ask_questions >/dev/null
[[ $GUIDE_MODE == simple ]]

sed -i '/^GUIDE_MODE=/d' "$STATE_FILE"
GUIDE_MODE=
ask_questions >/dev/null
[[ $GUIDE_MODE == simple && $ADMIN_PASSWORD == "$initial" ]]
before=$(sha256sum "$STATE_FILE")
if (PLUSEMU_GUIDE_MODE=typo ask_questions >/dev/null 2>&1); then
    echo 'Guide mode: invalid choice was accepted' >&2
    exit 1
fi
[[ $(sha256sum "$STATE_FILE") == "$before" ]]
printf 'Bash guide mode checks passed\n'

#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; the state file is sourced
# Exercise the webhook question and the health check against fake services and a fake Discord.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/health.log" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

WEBHOOK=https://discord.com/api/webhooks/1234567890/secret-webhook-token_42
OTHER_WEBHOOK=https://discordapp.com/api/webhooks/987/other-token
STATE_FILE=$TEST_DIR/etc/hotel.env
HOTEL_ROOT=$TEST_DIR/hotel
NIGHTLY_ROOT=$TEST_DIR/backups/nightly
BACKUP_COMMAND=$TEST_DIR/sbin/plusemu-backup
SSL_DIR=$TEST_DIR/ssl
CLOUDFLARE_LOG=$TEST_DIR/plusemu-cloudflare-ips.log
LOCK_FILE=$TEST_DIR/update.lock
HEALTH_COMMAND=$TEST_DIR/sbin/plusemu-health
HEALTH_CRON=$TEST_DIR/cron.d/plusemu-health
HEALTH_LOG=$TEST_DIR/health.log
HEALTH_STATE=$TEST_DIR/lib/health.state
TTY=$TEST_DIR/no-terminal
export FAKE_DIR=$TEST_DIR/fake
mkdir -p "$FAKE_DIR/down" "$TEST_DIR/fakebin" "$HOTEL_ROOT" "$NIGHTLY_ROOT" "$SSL_DIR" "$(dirname "$BACKUP_COMMAND")"

expect_terminal() { grep -qF -- "$1" "$TEST_DIR/terminal" || { echo "expected on the terminal: $1"; exit 1; }; }
nowhere() { # nowhere <text>: the text is in no log, guide, health file or Discord request line
    local found
    found=$(grep -lsF -- "$1" "$TEST_DIR/log" "$TEST_DIR/terminal" "$HEALTH_LOG" "$FAKE_DIR/curl-args" || true)
    if [ -n "$found" ]; then echo "written to $found: $1"; exit 1; fi
}
state() { (. "$STATE_FILE"; printf '%s' "${!1}"); }

# ---------------------------------------------------------------- the webhook question

export PLUSEMU_DOMAIN=example.com PLUSEMU_WS_URL=wss://example.com/ws PLUSEMU_HOTEL_NAME=Example
export PLUSEMU_ADMIN_USER=admin PLUSEMU_ADMIN_EMAIL=admin@example.com PLUSEMU_YES=1

# Unattended without a webhook: no question, alerts stay off.
ask_questions
[ -z "$(state DISCORD_WEBHOOK)" ] && grep -q "^DISCORD_WEBHOOK=''$" "$STATE_FILE"
expect_terminal 'Health alerts: log only'
rm "$STATE_FILE"

# A preset webhook is checked and saved; a trace never prints it.
(
    export PLUSEMU_DISCORD_WEBHOOK=$WEBHOOK
    set -x
    ask_questions
    unset PLUSEMU_DISCORD_WEBHOOK
    ask_questions
) 2>> "$TEST_DIR/log"
grep -q 'choose_options' "$TEST_DIR/log"
[ "$(state DISCORD_WEBHOOK)" = "$WEBHOOK" ]
[ "$(stat -c %a "$STATE_FILE")" = 600 ]
expect_terminal 'Health alerts: Discord'
initial=$(state ADMIN_PASSWORD)

# A rerun reuses it and says where to change it.
: > "$TEST_DIR/terminal"
ask_questions
[ "$DISCORD_WEBHOOK" = "$WEBHOOK" ] && [ "$DISCORD_WEBHOOK_NEW" = 0 ] && [ "$(state ADMIN_PASSWORD)" = "$initial" ]
expect_terminal 'Health alerts are on'
expect_terminal 'PLUSEMU_DISCORD_WEBHOOK=<new URL>'

# A new webhook replaces it and counts as new; off removes it.
PLUSEMU_DISCORD_WEBHOOK=$OTHER_WEBHOOK ask_questions
[ "$(state DISCORD_WEBHOOK)" = "$OTHER_WEBHOOK" ] && [ "$DISCORD_WEBHOOK_NEW" = 1 ]
PLUSEMU_DISCORD_WEBHOOK=off ask_questions
[ -z "$(state DISCORD_WEBHOOK)" ]

# A preset that is not a Discord webhook stops an unattended run and changes nothing.
before=$(sha256sum "$STATE_FILE")
for wrong in https://example.com/api/webhooks/1/x http://discord.com/api/webhooks/1/x "https://discord.com/api/webhooks/1/x'y" https://discord.com.example.net/api/webhooks/1/x; do
    if (PLUSEMU_DISCORD_WEBHOOK=$wrong ask_questions); then echo "accepted a wrong webhook: $wrong"; exit 1; fi
done
[ "$(sha256sum "$STATE_FILE")" = "$before" ]

# In a terminal, a wrong answer asks again and Enter skips. The other questions take their defaults.
unset PLUSEMU_YES
rm "$STATE_FILE"
: > "$TEST_DIR/terminal"
(
    ask() { printf -v "$1" '%s' "${3:-}"; }
    exec 5< <(printf 'not a webhook\n%s\n' "$WEBHOOK")
    TTY=/dev/fd/5
    ask_questions
)
[ "$(state DISCORD_WEBHOOK)" = "$WEBHOOK" ]
expect_terminal 'Discord webhook URL for alerts when something is wrong with your hotel (optional, press Enter to skip)'
expect_terminal 'That is not a Discord webhook URL'

# A state file from before this question asks it once; Enter keeps alerts off.
sed -i '/^DISCORD_WEBHOOK=/d' "$STATE_FILE"
: > "$TEST_DIR/terminal"
(
    ask() { printf -v "$1" '%s' "${3:-}"; }
    exec 5< <(printf '\n')
    TTY=/dev/fd/5
    ask_questions
)
expect_terminal 'Discord webhook URL for alerts'
grep -q "^DISCORD_WEBHOOK=''$" "$STATE_FILE"
: > "$TEST_DIR/terminal"
ask_questions
if grep -qF 'Discord webhook URL for alerts' "$TEST_DIR/terminal"; then echo 'asked the webhook question twice'; exit 1; fi
export PLUSEMU_YES=1
nowhere "$WEBHOOK"
nowhere "$OTHER_WEBHOOK"

# ---------------------------------------------------------------- fake services and Discord

# Every service answers unless $FAKE_DIR/down names it. Discord answers with $FAKE_DIR/discord-status.
cat > "$TEST_DIR/fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_DIR/calls"
if [ "$1" = is-active ]; then [ ! -e "$FAKE_DIR/down/${*: -1}" ]; fi
FAKE
cat > "$TEST_DIR/fakebin/curl" <<'FAKE'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "$FAKE_DIR/curl-args"
data='' config='' url=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --data-binary) data=$2; shift 2 ;;
        -K) config=$(cat); shift 2 ;;
        -o | -w | -H | --max-time) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
if [ -n "$config" ]; then
    printf '%s\n' "$config" > "$FAKE_DIR/discord-url"
    printf '%s\n' "$data" >> "$FAKE_DIR/discord"
    printf '\n%s' "$(cat "$FAKE_DIR/discord-status" 2> /dev/null || echo 204)"
    exit 0
fi
if [ "$url" = http://127.0.0.1/ ]; then cat "$FAKE_DIR/website" 2> /dev/null || printf 200; fi
FAKE
# The port check connects with bash's /dev/tcp under timeout; the fake answers for the port it names.
cat > "$TEST_DIR/fakebin/timeout" <<'FAKE'
#!/usr/bin/env bash
port=${*: -1}
[ ! -e "$FAKE_DIR/down/${port##*/}" ]
FAKE
cat > "$TEST_DIR/fakebin/mariadb" <<'FAKE'
#!/usr/bin/env bash
if [ -e "$FAKE_DIR/down/mariadb" ]; then exit 1; fi
echo 1
FAKE
cat > "$TEST_DIR/fakebin/df" <<'FAKE'
#!/usr/bin/env bash
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/sda1 100000 50000 %s 50%% /\n' "$(cat "$FAKE_DIR/free-mb" 2> /dev/null || echo 40000)"
FAKE
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$SSL_DIR/key.pem" -out "$SSL_DIR/cert.pem" -subj /CN=example.com 2> /dev/null
mkdir "$NIGHTLY_ROOT/20261023-040000-000000000"
echo "$(date) HTTPS is accepted only from Cloudflare's 22 address ranges." > "$CLOUDFLARE_LOG"
touch "$BACKUP_COMMAND"

messages() { if [ -f "$FAKE_DIR/discord" ]; then wc -l < "$FAKE_DIR/discord"; else echo 0; fi; }
last_message() { tail -n 1 "$FAKE_DIR/discord" | jq -r .content; }
health() { "$HEALTH_COMMAND" > "$TEST_DIR/health.out" 2>&1; }
expect_ok() { health || { echo "a check failed:"; cat "$TEST_DIR/health.out"; exit 1; }; }
expect_problem() { # expect_problem <text>: the health check fails and names the problem
    if health; then echo "expected a failed check: $1"; exit 1; fi
    grep -qF -- "$1" "$TEST_DIR/health.out" || { echo "expected in the health check: $1"; cat "$TEST_DIR/health.out"; exit 1; }
}

# ---------------------------------------------------------------- the installed command

PLUSEMU_DISCORD_WEBHOOK=$WEBHOOK ask_questions
: > "$TEST_DIR/terminal"
(set -x; install_health_check) 2>> "$TEST_DIR/log"
[ -x "$HEALTH_COMMAND" ] && [ "$(stat -c %a "$HEALTH_COMMAND")" = 700 ]
grep -qxF "*/5 * * * * root $HEALTH_COMMAND > /dev/null 2>&1" "$HEALTH_CRON"
# The webhook was just saved: one message tells the owner that alerts work.
[ "$(messages)" = 1 ]
[[ $(last_message) == *'Health alerts for **Example** are on'* ]]
grep -qx "url = \"$WEBHOOK\"" "$FAKE_DIR/discord-url"
expect_terminal 'Discord alerts are on'
grep -q 'plusemu-health' "$TEST_DIR/terminal"
# A rerun with the same webhook sends nothing.
ask_questions
install_health_check
[ "$(messages)" = 1 ]

# Everything works: no message, a log line.
expect_ok
grep -q 'OK: all 10 checks passed.' "$HEALTH_LOG"
[ "$(messages)" = 1 ]
[ ! -s "$HEALTH_STATE" ]

# One failure sends one message, and a repeat of the same failure sends nothing.
touch "$FAKE_DIR/down/plusemu"
expect_problem 'The emulator service: The plusemu service is not running.'
[ "$(messages)" = 2 ]
[[ $(last_message) == *'❌ The emulator service does not work. The plusemu service is not running. Look at it with: `sudo journalctl -u plusemu -n 100`'* ]]
[ "$(< "$HEALTH_STATE")" = emulator ]
expect_problem 'The emulator service'
expect_problem 'The emulator service'
[ "$(messages)" = 2 ]
grep -q '1 of 10 checks failed.' "$HEALTH_LOG"

# The recovery sends one more message, then nothing.
rm "$FAKE_DIR/down/plusemu"
expect_ok
[ "$(messages)" = 3 ]
[[ $(last_message) == *'✅ The emulator service works again.'* ]]
expect_ok
[ "$(messages)" = 3 ]
[ ! -s "$HEALTH_STATE" ]

# Two failures in one run share one message.
touch "$FAKE_DIR/down/2096" "$FAKE_DIR/down/mariadb"
expect_problem 'Nothing answers on port 2096.'
grep -qF 'The database (MariaDB): MariaDB does not answer.' "$TEST_DIR/health.out"
[ "$(messages)" = 4 ]
[[ $(last_message) == *'The game connection (port 2096) does not work'*'The database (MariaDB) does not work'* ]]
[ "$(sort "$HEALTH_STATE" | tr '\n' ' ')" = 'database game_port ' ]
rm "$FAKE_DIR/down/2096" "$FAKE_DIR/down/mariadb"
expect_ok
[ "$(messages)" = 5 ]

# Many failures at once still fit in one Discord message.
touch "$FAKE_DIR/down/plusemu" "$FAKE_DIR/down/2096" "$FAKE_DIR/down/8080" "$FAKE_DIR/down/nginx" "$FAKE_DIR/down/mariadb" "$FAKE_DIR/free-mb"
printf 000 > "$FAKE_DIR/website"
echo 100 > "$FAKE_DIR/free-mb"
mv "$CLOUDFLARE_LOG" "$CLOUDFLARE_LOG.saved"
expect_problem '8 of 10 checks failed.'
[ "$(messages)" = 6 ]
[ "$(last_message | wc -c)" -lt 2000 ]
for label in 'The emulator service' 'The game connection (port 2096)' 'The emulator API (port 8080)' 'The web server (nginx)' 'The website' 'The database (MariaDB)' 'Free disk space' 'The Cloudflare address refresh'; do
    [[ $(last_message) == *"❌ $label does not work."* ]] || { echo "the message misses: $label"; exit 1; }
done
rm "$FAKE_DIR"/down/* "$FAKE_DIR/free-mb" "$FAKE_DIR/website"
mv "$CLOUDFLARE_LOG.saved" "$CLOUDFLARE_LOG"
expect_ok
[ "$(messages)" = 7 ]

# Discord does not take the message: the next run sends it, once.
nginx_messages() { grep -c 'The web server (nginx) does not work' "$FAKE_DIR/discord" || true; }
earlier=$(nginx_messages)
echo 500 > "$FAKE_DIR/discord-status"
touch "$FAKE_DIR/down/nginx"
expect_problem 'The web server (nginx)'
grep -q 'Could not tell Discord what changed: Discord answered with HTTP status 500' "$HEALTH_LOG"
[ ! -s "$HEALTH_STATE" ]
rm "$FAKE_DIR/discord-status"
before=$(messages)
expect_problem 'The web server (nginx)'
# The fake Discord records the refused message too.
[ "$(nginx_messages)" = $((earlier + 2)) ]
[ "$(< "$HEALTH_STATE")" = web_server ]
expect_problem 'The web server (nginx)'
[ "$(messages)" = $((before + 1)) ]
rm "$FAKE_DIR/down/nginx"
expect_ok

# Each check finds its own problem.
touch "$FAKE_DIR/down/8080"
expect_problem 'The emulator API (port 8080): Nothing answers on port 8080.'
rm "$FAKE_DIR/down/8080"
printf 502 > "$FAKE_DIR/website"
expect_problem 'The website: https://example.com answers with error 502 on this server.'
printf 000 > "$FAKE_DIR/website"
expect_problem 'https://example.com does not answer on this server.'
grep -q -- '-H Host: example.com http://127.0.0.1/' "$FAKE_DIR/curl-args"
printf 302 > "$FAKE_DIR/website"
expect_ok
echo 1500 > "$FAKE_DIR/free-mb"
expect_problem 'Only 1500 MB is free'
rm "$FAKE_DIR/free-mb"
expect_ok

# The newest backup must be younger than 36 hours; a new hotel waits for its first night.
touch -d '37 hours ago' "$NIGHTLY_ROOT/20261023-040000-000000000"
expect_problem 'The nightly backup: The newest nightly backup'
mkdir "$NIGHTLY_ROOT/20261024-040000-000000000.partial"
expect_problem 'The nightly backup'
mkdir "$NIGHTLY_ROOT/20261024-040000-000000001"
expect_ok
rm -r "${NIGHTLY_ROOT:?}"/*
expect_ok
touch -d '37 hours ago' "$BACKUP_COMMAND"
expect_problem 'The nightly backup'
mkdir "$NIGHTLY_ROOT/20261024-040000-000000001"
expect_ok

# The certificate must be valid for 30 more days.
mv "$SSL_DIR/cert.pem" "$SSL_DIR/good.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 10 -keyout "$SSL_DIR/key.pem" -out "$SSL_DIR/cert.pem" -subj /CN=example.com 2> /dev/null
expect_problem 'The HTTPS certificate: The certificate in'
mv "$SSL_DIR/good.pem" "$SSL_DIR/cert.pem"
expect_ok

# The last Cloudflare refresh must have worked within 8 days, also after the log rotated.
echo "$(date) Could not download Cloudflare's address ranges. The firewall and nginx were left as they are." >> "$CLOUDFLARE_LOG"
expect_problem "The Cloudflare address refresh: The last refresh did not work: "
grep -qF 'Could not download' "$TEST_DIR/health.out"
echo "$(date) HTTPS is accepted only from Cloudflare's 22 address ranges." >> "$CLOUDFLARE_LOG"
expect_ok
mv "$CLOUDFLARE_LOG" "$CLOUDFLARE_LOG.1"
: > "$CLOUDFLARE_LOG"
expect_ok
touch -d '9 days ago' "$CLOUDFLARE_LOG.1"
expect_problem 'older than 8 days'
rm "$CLOUDFLARE_LOG" "$CLOUDFLARE_LOG.1"
expect_problem 'The refresh never ran.'
echo "$(date) HTTPS is accepted only from Cloudflare's 22 address ranges." > "$CLOUDFLARE_LOG"
expect_ok

# An update holds the lock: the run is skipped and remembers nothing.
touch "$FAKE_DIR/down/plusemu"
before=$(messages)
flock "$LOCK_FILE" "$HEALTH_COMMAND" > "$TEST_DIR/health.out"
grep -q 'Skipped: an update' "$TEST_DIR/health.out"
[ "$(messages)" = "$before" ] && [ ! -s "$HEALTH_STATE" ]
rm "$FAKE_DIR/down/plusemu"

# The messages and the log hold no passwords, and the webhook never reaches a command line or the log.
for secret in "$(state ADMIN_PASSWORD)" "$(state DB_PASSWORD)" "$(state GUIDE_TOKEN)"; do
    if grep -qF -- "$secret" "$FAKE_DIR/discord" "$HEALTH_LOG"; then echo 'a message or the log holds a password'; exit 1; fi
done
nowhere "$WEBHOOK"
jq -e '.allowed_mentions.parse == [] and .username == "PlusEMU"' <<< "$(tail -n 1 "$FAKE_DIR/discord")" > /dev/null

# ---------------------------------------------------------------- without a webhook

PLUSEMU_DISCORD_WEBHOOK=off ask_questions
: > "$TEST_DIR/terminal"
install_health_check
expect_terminal 'Discord alerts are off'
before=$(messages)
touch "$FAKE_DIR/down/plusemu"
expect_problem 'The emulator service'
grep -q 'PROBLEM: The emulator service' "$HEALTH_LOG"
[ "$(< "$HEALTH_STATE")" = emulator ]
rm "$FAKE_DIR/down/plusemu"
expect_ok
[ "$(messages)" = "$before" ]

# The first message fails: the installer warns and goes on.
echo 404 > "$FAKE_DIR/discord-status"
PLUSEMU_DISCORD_WEBHOOK=$WEBHOOK ask_questions
: > "$TEST_DIR/terminal"
install_health_check
expect_terminal 'Could not send the first message to Discord: Discord answered with HTTP status 404'
[ -x "$HEALTH_COMMAND" ]
rm "$FAKE_DIR/discord-status"

printf 'Bash health check checks passed\n' >&4

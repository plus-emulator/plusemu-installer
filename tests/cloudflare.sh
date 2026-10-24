#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090 # the overrides are read by the sourced install.sh functions; the state file is sourced
# Exercise the Cloudflare API setup against a fake Cloudflare API, nginx and systemctl.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/fake/calls" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

TOKEN=cf-test-token-6f1d0c9e
export FAKE_DIR=$TEST_DIR/fake FAKE_TOKEN=$TOKEN
CF_API=https://api.cloudflare.test/client/v4
TEMPLATES=$ROOT/templates
HOTEL_ROOT=$TEST_DIR/hotel
STATE_FILE=$TEST_DIR/etc/hotel.env
SSL_DIR=$TEST_DIR/ssl
LOG=$TEST_DIR/log
TTY=$TEST_DIR/tty
GUIDE=$HOTEL_ROOT/setup-guide/index.html
DOMAIN=example.com WS_URL=wss://example.com/ws HOTEL_NAME=Example ADMIN_USER=admin ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=initial-admin-password DB_PASSWORD=database-password GUIDE_TOKEN=guidetoken12 GUIDE_MODE=simple
SERVER_IP=192.0.2.10
derive_settings() { WS_HOST=${WS_URL#wss://}; WS_PATH=/${WS_HOST#*/}; WS_HOST=${WS_HOST%%/*}; [[ $WS_URL == wss://*/* ]] || WS_PATH=/; }
derive_settings
mkdir -p "$TEST_DIR/fakebin" "$SSL_DIR"
save_state
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$SSL_DIR/key.pem" -out "$SSL_DIR/cert.pem" -subj "/CN=$DOMAIN" 2> /dev/null
SELF_SIGNED=$(< "$SSL_DIR/cert.pem")

# The fake API keeps its records, settings and rulesets as JSON files, the way Cloudflare answers.
cat > "$TEST_DIR/fakebin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
method=GET data='' out='' auth='' url=''
while [ "$#" -gt 0 ]; do
    case $1 in
        -X) method=$2; shift 2 ;;
        --data-binary) data=$2; shift 2 ;;
        -o) out=$2; shift 2 ;;
        -H) if [[ $2 == @* ]]; then auth=$(< "${2#@}"); fi; shift 2 ;;
        -w | --max-time) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
if [[ $url == *origin_ca_rsa_root.pem ]]; then
    if [ -f "$FAKE_DIR/other-root.pem" ]; then cp "$FAKE_DIR/other-root.pem" "$out"; else cp "$FAKE_DIR/ca.pem" "$out"; fi
    exit 0
fi
path=${url#https://api.cloudflare.test/client/v4}
echo "$method $path" >> "$FAKE_DIR/calls"
if [ -n "$data" ]; then printf '%s %s %s\n' "$method" "$path" "$data" >> "$FAKE_DIR/bodies"; fi
reply() { printf '%s\n%s' "$2" "$1"; if [ "$1" -ge 400 ]; then exit 22; fi; exit 0; }
ok() { reply 200 "$(jq -nc --argjson result "$1" '{success: true, errors: [], messages: [], result: $result}')"; }
fail() { reply "$1" "$(jq -nc --arg message "$2" --argjson code "$3" '{success: false, errors: [{code: $code, message: $message}], result: null}')"; }
store() { jq "$2" "${@:3}" "$FAKE_DIR/$1" > "$FAKE_DIR/$1.new"; mv "$FAKE_DIR/$1.new" "$FAKE_DIR/$1"; }
[ "$auth" = "Authorization: Bearer $FAKE_TOKEN" ] || fail 401 'Invalid API Token' 1000
# shellcheck disable=SC2053 # the deny file holds a glob
if [ -f "$FAKE_DIR/deny" ] && [[ "$method $path" == $(< "$FAKE_DIR/deny") ]]; then fail 403 'Authentication error' 10000; fi
case "$method $path" in
    'GET /user/tokens/verify') ok '{"status": "active"}' ;;
    'GET /zones?name=example.com')
        if [ -f "$FAKE_DIR/zone" ]; then ok '[{"id": "zone1", "name": "example.com", "status": "active"}]'; fi
        # The owner adds the site while the installer waits.
        if [ -f "$FAKE_DIR/zone-later" ]; then rm "$FAKE_DIR/zone-later"; touch "$FAKE_DIR/zone"; fi
        ok '[]'
        ;;
    'GET /zones/zone1/dns_records?name='*)
        name=${path#*name=}
        ok "$(jq -c --arg name "${name%%&*}" 'map(select(.name == $name))' "$FAKE_DIR/dns.json")"
        ;;
    'POST /zones/zone1/dns_records')
        record=$(jq -c --arg id "record$(jq length "$FAKE_DIR/dns.json")" '. + {id: $id}' <<< "$data")
        store dns.json '. + [$record]' --argjson record "$record"
        ok "$record"
        ;;
    'PATCH /zones/zone1/dns_records/'*)
        store dns.json 'map(if .id == $id then . + $change else . end)' --arg id "${path##*/}" --argjson change "$data"
        ok "$data"
        ;;
    'POST /certificates')
        jq -r .csr <<< "$data" > "$FAKE_DIR/request.csr"
        names=$(jq -r '.hostnames | map("DNS:" + .) | join(",")' <<< "$data")
        [ "$(jq -r '"\(.requested_validity) \(.request_type)"' <<< "$data")" = '5475 origin-rsa' ] || fail 400 'bad request' 1101
        openssl x509 -req -in "$FAKE_DIR/request.csr" -CA "$FAKE_DIR/ca.pem" -CAkey "$FAKE_DIR/ca.key" -set_serial "$RANDOM" -days 5475 \
            -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$names") -out "$FAKE_DIR/issued.pem" 2> /dev/null
        ok "$(jq -n --rawfile certificate "$FAKE_DIR/issued.pem" '{id: "1", certificate: $certificate}')"
        ;;
    'GET /zones/zone1/settings/security_level') ok "$(jq -c '{id: "security_level", value: (.security_level // "medium")}' "$FAKE_DIR/settings.json")" ;;
    'PATCH /zones/zone1/settings/'*)
        store settings.json '.[$name] = $change.value' --arg name "${path##*/}" --argjson change "$data"
        ok "$(jq -c --arg name "${path##*/}" '{id: $name, value: .[$name]}' "$FAKE_DIR/settings.json")"
        ;;
    'PUT /zones/zone1/bot_management')
        store settings.json '.bot_management = $change' --argjson change "$data"
        ok "$data"
        ;;
    'GET /zones/zone1/rulesets/phases/'*'/entrypoint')
        phase=${path#*/phases/}
        phase=${phase%/entrypoint}
        [ -f "$FAKE_DIR/$phase.json" ] || fail 404 "could not find entrypoint ruleset in the $phase phase" 10003
        ok "$(< "$FAKE_DIR/$phase.json")"
        ;;
    'PUT /zones/zone1/rulesets/phases/'*'/entrypoint')
        phase=${path#*/phases/}
        phase=${phase%/entrypoint}
        jq --arg phase "$phase" '{id: ("rs-" + $phase), phase: $phase, rules: [.rules | to_entries[] | .value + {id: "rule\(.key)"}]}' <<< "$data" > "$FAKE_DIR/$phase.json"
        ok "$(< "$FAKE_DIR/$phase.json")"
        ;;
    'POST /zones/zone1/rulesets/rs-'*'/rules')
        phase=${path#*/rulesets/rs-}
        phase=${phase%/rules}
        store "$phase.json" '.rules += [$rule + {id: "rule\(.rules | length)"}]' --argjson rule "$data"
        ok "$(< "$FAKE_DIR/$phase.json")"
        ;;
    'PATCH /zones/zone1/rulesets/rs-'*'/rules/'*)
        phase=${path#*/rulesets/rs-}
        phase=${phase%%/*}
        store "$phase.json" '.rules |= map(if .id == $id then $rule + {id: $id} else . end)' --arg id "${path##*/}" --argjson rule "$data"
        ok "$(< "$FAKE_DIR/$phase.json")"
        ;;
esac
fail 404 "fake Cloudflare has no $method $path" 7003
FAKE
cat > "$TEST_DIR/fakebin/nginx" <<'FAKE'
#!/usr/bin/env bash
echo "nginx $*" >> "$FAKE_DIR/calls"
if [ "$1" = -t ] && [ -f "$FAKE_DIR/nginx-rejects" ]; then exit 1; fi
FAKE
cat > "$TEST_DIR/fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_DIR/calls"
FAKE
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH

fresh_cloudflare() { # an empty Cloudflare account with the site added
    rm -rf "$FAKE_DIR"
    mkdir -p "$FAKE_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -keyout "$FAKE_DIR/ca.key" -out "$FAKE_DIR/ca.pem" \
        -subj '/O=CloudFlare, Inc./CN=Fake Origin CA' 2> /dev/null
    echo '[]' > "$FAKE_DIR/dns.json"
    echo '{}' > "$FAKE_DIR/settings.json"
    touch "$FAKE_DIR/zone"
}
run() { # run [terminal answer]: one Cloudflare step, as the installer runs it
    : > "$FAKE_DIR/calls"
    : > "$TEST_DIR/terminal"
    printf '%s\n' "${1-}" > "$TTY"
    connect_cloudflare
}
calls() { grep -v -e '^nginx' -e '^systemctl' "$FAKE_DIR/calls" || true; }
expect_calls() { [ "$(calls)" = "$1" ] || { printf 'expected calls:\n%s\ngot:\n%s\n' "$1" "$(calls)"; exit 1; }; }
expect_terminal() { grep -qF -- "$1" "$TEST_DIR/terminal" || { echo "expected on the terminal: $1"; cat "$TEST_DIR/terminal"; exit 1; }; }
expect_guide() { grep -qF -- "$1" "$GUIDE" || { echo "expected in the guide: $1"; exit 1; }; }
expect_no_guide() { if grep -qF -- "$1" "$GUIDE"; then echo "unexpected in the guide: $1"; exit 1; fi; }
state() { (. "$STATE_FILE"; printf '%s' "${!1}"); }
token_nowhere() { # the token is in no log, state file, guide or terminal output
    if grep -rlF -- "$TOKEN" "$TEST_DIR" --exclude=tty; then echo 'the token was written to a file'; exit 1; fi
}
dns() { jq -r 'map("\(.type) \(.name) \(.content) \(.proxied)") | sort | .[]' "$FAKE_DIR/dns.json"; }
rule_count() { jq '.rules | length' "$FAKE_DIR/$1.json"; }

SUCCESS="GET /user/tokens/verify
GET /zones?name=example.com
GET /zones/zone1/dns_records?name=example.com&per_page=100
POST /zones/zone1/dns_records
GET /zones/zone1/dns_records?name=www.example.com&per_page=100
POST /zones/zone1/dns_records
POST /certificates
PATCH /zones/zone1/settings/ssl
PATCH /zones/zone1/settings/always_use_https
PATCH /zones/zone1/settings/websockets
PATCH /zones/zone1/settings/min_tls_version
PATCH /zones/zone1/settings/browser_check
GET /zones/zone1/settings/security_level
PATCH /zones/zone1/settings/security_level
PUT /zones/zone1/bot_management
GET /zones/zone1/rulesets/phases/http_ratelimit/entrypoint
PUT /zones/zone1/rulesets/phases/http_ratelimit/entrypoint
GET /zones/zone1/rulesets/phases/http_request_firewall_custom/entrypoint
PUT /zones/zone1/rulesets/phases/http_request_firewall_custom/entrypoint"

# ---------------------------------------------------------------- skipped

# Unattended without a token: nothing reaches Cloudflare and the guide keeps the manual steps.
fresh_cloudflare
PLUSEMU_YES=1 run
expect_calls ''
expect_terminal 'Skipped. Follow the manual steps in the guide.'
expect_terminal "http://$SERVER_IP/$GUIDE_TOKEN/"
expect_terminal 'Connect Cloudflare automatically'
expect_guide 'id="connect-cloudflare-automatically"'
expect_no_guide 'class="card connected"'
expect_no_guide '{{'
expect_guide 'Now connect <b>example.com</b> through Cloudflare and install its origin certificate.'
# The game connection uses the website's own address, so the guide names no separate game address.
expect_guide 'the <b>A</b> records for <code>example.com</code> and <code>www.example.com</code>, pointing to'
expect_no_guide 'the game address'
[ "$(< "$SSL_DIR/cert.pem")" = "$SELF_SIGNED" ]

# Enter at the question skips as well.
run ''
expect_calls ''
expect_terminal 'Paste your Cloudflare API token, or press Enter to skip and follow the manual steps in the guide'

# ---------------------------------------------------------------- the site is missing

# The site is not in Cloudflare yet: the owner is told, chooses to skip, and nothing changes.
rm "$FAKE_DIR/zone"
PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run skip
expect_calls 'GET /user/tokens/verify
GET /zones?name=example.com'
expect_terminal 'Cloudflare has no site example.com that this token can use'
expect_terminal 'press Enter to try again, paste a new token, or type skip'
expect_guide 'The installer could not finish the Cloudflare setup.'
expect_guide 'Cloudflare has no site example.com that this token can use'
[ -z "$(state CLOUDFLARE_SETUP)" ]
[ "$(< "$SSL_DIR/cert.pem")" = "$SELF_SIGNED" ]
[ -z "${PLUSEMU_CLOUDFLARE_TOKEN:-}" ] && [ -z "${CLOUDFLARE_TOKEN:-}" ]

# A wrong token is named as such.
FAKE_TOKEN=another-token PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
expect_calls 'GET /user/tokens/verify'
expect_terminal 'Cloudflare did not accept the token'
expect_terminal 'Invalid API Token'

# ---------------------------------------------------------------- success

# The owner adds the site while the installer waits, presses Enter, and every step runs.
touch "$FAKE_DIR/zone-later"
: > "$FAKE_DIR/calls"
: > "$TEST_DIR/terminal"
(
    # A first answer pastes the token, a second presses Enter to try again.
    exec 5< <(printf '%s\n\n' "$TOKEN")
    TTY=/dev/fd/5
    set -x
    connect_cloudflare
) 2>> "$TEST_DIR/trace"
. "$STATE_FILE"
expect_terminal 'Cloudflare has no site example.com'
expect_calls "GET /user/tokens/verify
GET /zones?name=example.com
$SUCCESS"
expect_terminal 'Cloudflare is connected.'
[ "$(dns)" = "A example.com 192.0.2.10 true
A www.example.com 192.0.2.10 true" ]
jq -e '.ssl == "strict" and .always_use_https == "on" and .websockets == "on" and .min_tls_version == "1.2" and .browser_check == "on" and .security_level == "medium" and .bot_management.fight_mode == true' "$FAKE_DIR/settings.json" > /dev/null
# The certificate is Cloudflare's, covers every hotel name, uses the server's own key and replaced the self-signed one.
openssl verify -CAfile "$FAKE_DIR/ca.pem" -verify_hostname www.example.com "$SSL_DIR/cert.pem"
[ "$(openssl pkey -in "$SSL_DIR/key.pem" -pubout)" = "$(openssl x509 -in "$SSL_DIR/cert.pem" -pubkey -noout)" ]
[ "$(stat -c %a "$SSL_DIR/key.pem")" = 600 ]
grep -q '"hostnames":\["example.com","\*.example.com"\]' "$FAKE_DIR/bodies"
grep -qx 'nginx -t' "$FAKE_DIR/calls" && grep -qx 'systemctl reload nginx' "$FAKE_DIR/calls"
[ "$(cat "$SSL_DIR"/backup.*/cert.pem)" = "$SELF_SIGNED" ]
# Full (strict) is switched on only after the new certificate is in nginx.
[ "$(grep -nx 'systemctl reload nginx' "$FAKE_DIR/calls" | cut -d: -f1)" -lt "$(grep -n 'settings/ssl$' "$FAKE_DIR/calls" | cut -d: -f1)" ]
jq -e '.rules[0] | .description == "PlusEMU: limit sign-in and registration" and .action == "block" and
    .ratelimit == {characteristics: ["cf.colo.id", "ip.src"], period: 10, requests_per_period: 10, mitigation_timeout: 10} and
    (.expression | contains("\"/login\"") and contains("\"/register\"") and contains("\"/forgot-password\"") and contains("\"/two-factor-challenge\"") and contains("\"/housekeeping/login\"") and contains("/reset-password/*"))' \
    "$FAKE_DIR/http_ratelimit.json" > /dev/null
jq -e '.rules[0].expression == "(http.host eq \"example.com\" and http.request.uri.path eq \"/ws\" and not any(http.request.headers[\"origin\"][*] eq \"https://example.com\"))" and .rules[0].action == "block"' \
    "$FAKE_DIR/http_request_firewall_custom.json" > /dev/null
jq -e '.rules[1].action == "managed_challenge" and (.rules[1].expression | contains("\"/housekeeping\"") and contains("/housekeeping/*"))' "$FAKE_DIR/http_request_firewall_custom.json" > /dev/null
# Only the result is saved, never the token.
[ "$(state CLOUDFLARE_SETUP)" = "done" ]
[[ $(state CLOUDFLARE_CERT_EXPIRES) =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]
[ "$(state CLOUDFLARE_CERT_EXPIRES)" = "$(date -u -d "$(openssl x509 -in "$SSL_DIR/cert.pem" -noout -enddate | cut -d= -f2)" +%Y-%m-%d)" ]
expect_guide 'class="card connected"'
expect_guide "valid until <b>$(state CLOUDFLARE_CERT_EXPIRES)</b>"
expect_guide '<details class="card manual"><summary>If you need to do this by hand</summary>'
expect_no_guide 'could not finish'
expect_no_guide '{{'
expect_guide 'Cloudflare is connected. Check your hotel below.'
expect_no_guide 'Now connect'
expect_guide '<b>DNS:</b> <code>example.com</code> and <code>www.example.com</code> point to'
expect_no_guide 'the game address'
token_nowhere
grep -q 'connect_cloudflare' "$TEST_DIR/trace"
if grep -qF -- "$TOKEN" "$TEST_DIR/trace"; then echo 'a trace printed the token'; exit 1; fi
[ -z "${CLOUDFLARE_TOKEN:-}" ]

# The final summary says Cloudflare is connected.
systemctl() { :; }
finish
unset -f systemctl
expect_terminal 'Cloudflare is connected. Open https://example.com'

# ---------------------------------------------------------------- reruns

# A rerun asks only whether to keep the setup; Enter keeps it without calling Cloudflare.
write_guide
expect_guide 'class="card connected"'
run ''
expect_calls ''
expect_terminal 'Cloudflare is already connected.'
expect_terminal 'Press Enter to keep it, or paste a token to run it again'
expect_guide 'class="card connected"'

# Running it again updates the installer's own records and rules and keeps the valid certificate.
certificate=$(< "$SSL_DIR/cert.pem")
records=$(dns)
run "$TOKEN"
expect_calls 'GET /user/tokens/verify
GET /zones?name=example.com
GET /zones/zone1/dns_records?name=example.com&per_page=100
GET /zones/zone1/dns_records?name=www.example.com&per_page=100
PATCH /zones/zone1/settings/ssl
PATCH /zones/zone1/settings/always_use_https
PATCH /zones/zone1/settings/websockets
PATCH /zones/zone1/settings/min_tls_version
PATCH /zones/zone1/settings/browser_check
GET /zones/zone1/settings/security_level
PATCH /zones/zone1/settings/security_level
PUT /zones/zone1/bot_management
GET /zones/zone1/rulesets/phases/http_ratelimit/entrypoint
PATCH /zones/zone1/rulesets/rs-http_ratelimit/rules/rule0
GET /zones/zone1/rulesets/phases/http_request_firewall_custom/entrypoint
PATCH /zones/zone1/rulesets/rs-http_request_firewall_custom/rules/rule0
PATCH /zones/zone1/rulesets/rs-http_request_firewall_custom/rules/rule1'
[ "$(< "$SSL_DIR/cert.pem")" = "$certificate" ]
[ "$(dns)" = "$records" ]
[ "$(rule_count http_ratelimit)" = 1 ] && [ "$(rule_count http_request_firewall_custom)" = 2 ]
expect_terminal 'Origin certificate: already installed'

# The owner's own rules stay, and Under Attack mode stays on.
store_rule() { jq '.rules += [{id: "owner", description: "My own rule", expression: "true", action: "block"}]' "$FAKE_DIR/$1.json" > "$FAKE_DIR/x" && mv "$FAKE_DIR/x" "$FAKE_DIR/$1.json"; }
store_rule http_request_firewall_custom
jq '.security_level = "under_attack"' "$FAKE_DIR/settings.json" > "$FAKE_DIR/x" && mv "$FAKE_DIR/x" "$FAKE_DIR/settings.json"
PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
[ "$(rule_count http_request_firewall_custom)" = 3 ]
jq -e '.rules[2].description == "My own rule"' "$FAKE_DIR/http_request_firewall_custom.json" > /dev/null
if calls | grep -qx 'PATCH /zones/zone1/settings/security_level'; then echo 'Under Attack mode was turned off'; exit 1; fi
[ "$(jq -r .security_level "$FAKE_DIR/settings.json")" = under_attack ]
token_nowhere

# ---------------------------------------------------------------- failures

# A token without one permission stops at that step, names the permission and keeps the manual guide.
fresh_cloudflare
cp "$SSL_DIR/backup."*/cert.pem "$SSL_DIR/cert.pem"
cp "$SSL_DIR/backup."*/key.pem "$SSL_DIR/key.pem"
rm -rf "$SSL_DIR/backup."*
CLOUDFLARE_SETUP='' CLOUDFLARE_CERT_EXPIRES=''
save_state
echo 'PUT /zones/zone1/bot_management' > "$FAKE_DIR/deny"
PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
expect_calls "$(sed '/bot_management/q' <<< "$SUCCESS")"
expect_terminal 'The Bot Fight Mode step failed: the token lacks the permission Zone / Bot Management / Edit.'
expect_terminal 'Authentication error'
expect_terminal 'The installer did not finish the Cloudflare setup.'
expect_guide 'the token lacks the permission Zone / Bot Management / Edit'
expect_no_guide 'class="card connected"'
[ -z "$(state CLOUDFLARE_SETUP)" ]
token_nowhere

# nginx rejects the new certificate: the self-signed one comes back and Full (strict) stays off.
fresh_cloudflare
cp "$SSL_DIR/backup."*/cert.pem "$SSL_DIR/cert.pem"
cp "$SSL_DIR/backup."*/key.pem "$SSL_DIR/key.pem"
touch "$FAKE_DIR/nginx-rejects"
PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
[ "$(< "$SSL_DIR/cert.pem")" = "$SELF_SIGNED" ]
[ "$(openssl pkey -in "$SSL_DIR/key.pem" -pubout)" = "$(openssl x509 -in "$SSL_DIR/cert.pem" -pubkey -noout)" ]
if calls | grep -q 'settings/ssl$'; then echo 'Full (strict) was turned on without a working certificate'; exit 1; fi
expect_terminal 'The origin certificate step failed: nginx did not accept the new certificate, so the previous one is back.'

# A certificate that is not Cloudflare's is not installed.
fresh_cloudflare
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$FAKE_DIR/other-root.key" -out "$FAKE_DIR/other-root.pem" -subj '/CN=Someone else' 2> /dev/null
PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
[ "$(< "$SSL_DIR/cert.pem")" = "$SELF_SIGNED" ]
expect_terminal 'The certificate from Cloudflare did not pass the checks'

# DNS: a wrong or grey record is corrected, a CNAME stops the setup, and other records stay.
fresh_cloudflare
echo '[{"id": "a1", "type": "A", "name": "example.com", "content": "198.51.100.7", "proxied": false},
      {"id": "m1", "type": "MX", "name": "example.com", "content": "mail.example.com"},
      {"id": "c1", "type": "CNAME", "name": "www.example.com", "content": "elsewhere.example.net", "proxied": false}]' > "$FAKE_DIR/dns.json"
PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
[ "$(dns)" = "A example.com 192.0.2.10 true
CNAME www.example.com elsewhere.example.net false
MX example.com mail.example.com null" ]
expect_terminal 'www.example.com has a CNAME record. Delete it in Cloudflare (DNS > Records)'
if calls | grep -q '^POST /certificates'; then echo 'continued after a DNS failure'; exit 1; fi

# A separate game address gets its own record, certificate name check and firewall rule.
fresh_cloudflare
WS_URL=wss://ws.example.com
derive_settings
PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
[ "$(dns)" = "A example.com 192.0.2.10 true
A ws.example.com 192.0.2.10 true
A www.example.com 192.0.2.10 true" ]
jq -e '.rules[0].expression | startswith("(http.host eq \"ws.example.com\" and http.request.uri.path eq \"/\" and")' "$FAKE_DIR/http_request_firewall_custom.json" > /dev/null
openssl verify -CAfile "$FAKE_DIR/ca.pem" -verify_hostname ws.example.com "$SSL_DIR/cert.pem"
expect_guide '<b>DNS:</b> <code>example.com</code>, the game address <code>ws.example.com</code> and <code>www.example.com</code> point to'
expect_guide 'the <b>A</b> records for <code>example.com</code>, the game address <code>ws.example.com</code> and <code>www.example.com</code>, pointing to'

# A game address on another domain is left to the manual steps before anything changes.
fresh_cloudflare
WS_URL=wss://game.example.net/ws
derive_settings
PLUSEMU_YES=1 PLUSEMU_CLOUDFLARE_TOKEN=$TOKEN run
expect_calls ''
expect_terminal 'The game connection uses another domain (game.example.net)'
token_nowhere

printf 'Bash Cloudflare checks passed\n' >&4

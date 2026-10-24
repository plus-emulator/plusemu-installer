#!/usr/bin/env bash
# shellcheck disable=SC2034 # the overrides are read by the sourced install.sh functions
# Exercise the Cloudflare-only HTTPS firewall against fake ufw, curl, nginx and systemctl programs.
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

CLOUDFLARE_COMMAND=$TEST_DIR/sbin/plusemu-cloudflare-ips
CLOUDFLARE_CRON=$TEST_DIR/cron.d/plusemu-cloudflare-ips
CLOUDFLARE_LOG=$TEST_DIR/plusemu-cloudflare-ips.log
REAL_IP_CONF=$TEST_DIR/nginx/cloudflare-real-ip.conf
UFW_DEFAULTS=$TEST_DIR/default-ufw
CROWDSEC_WHITELIST=$TEST_DIR/crowdsec/parsers/s02-enrich/plusemu-whitelist.yaml
export FAKE_DIR=$TEST_DIR/fake
mkdir -p "$TEST_DIR/fakebin" "$FAKE_DIR" "$(dirname "$REAL_IP_CONF")"
: > "$FAKE_DIR/rules"
echo 'IPV6=yes' > "$UFW_DEFAULTS"

# The fake ufw keeps its rules the way "ufw show added" prints them.
cat > "$TEST_DIR/fakebin/ufw" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
rules=$FAKE_DIR/rules
echo "ufw $*" >> "$FAKE_DIR/calls"
rule_of() { # the "show added" form of an allow or delete command
    local action=$1 proto='' from='' port='' comment='' short='' rule
    shift
    while [ "$#" -gt 0 ]; do
        case $1 in
            proto) proto=$2; shift 2 ;;
            from) from=$2; shift 2 ;;
            to) [ "$2" = any ] || exit 2; shift 2 ;;
            port) port=$2; shift 2 ;;
            comment) comment=$2; shift 2 ;;
            *) short=$1; shift ;;
        esac
    done
    if [[ $short == *' '* ]]; then short="'$short'"; fi
    if [ -n "$short" ]; then rule="$action $short"; else rule="$action from $from to any port $port proto $proto"; fi
    if [ -n "$comment" ]; then rule+=" comment '$comment'"; fi
    printf '%s\n' "$rule"
}
without_comment() { sed "s/ comment '[^']*'\$//"; }
case $1 in
    show)
        echo "Added user rules (see 'ufw status' for running firewall):"
        sed 's/^/ufw /' "$rules"
        ;;
    status)
        echo 'Status: active'
        while read -r line; do
            if [[ $line =~ ^allow\ ([0-9]+/tcp)$ ]]; then echo "${BASH_REMATCH[1]} ALLOW IN Anywhere"
            elif [[ $line =~ ^allow\ from\ ([^ ]+)\ to\ any\ port\ ([0-9]+)\ proto\ tcp\ comment\ \'(.*)\'$ ]]; then echo "${BASH_REMATCH[2]}/tcp ALLOW IN ${BASH_REMATCH[1]} # ${BASH_REMATCH[3]}"
            else echo "$line"; fi
        done < "$rules"
        ;;
    --force) ;;
    insert)
        shift 2
        { echo "$*"; cat "$rules"; } > "$rules.new"
        mv "$rules.new" "$rules"
        ;;
    allow)
        rule=$(rule_of "$@")
        bare=$(without_comment <<< "$rule")
        if grep -qxF -- "$rule" "$rules"; then echo 'Skipping adding existing rule'; exit 0; fi
        if without_comment < "$rules" | grep -qxF -- "$bare"; then
            while read -r line; do
                if [ "$(without_comment <<< "$line")" = "$bare" ]; then echo "$rule"; else echo "$line"; fi
            done < "$rules" > "$rules.new"
            mv "$rules.new" "$rules"
        else
            echo "$rule" >> "$rules"
        fi
        ;;
    delete)
        # Only a rule written exactly as it was added, comment included, is deleted.
        shift
        rule=$(rule_of "$@")
        if ! grep -qxF -- "$rule" "$rules"; then echo 'Could not delete non-existent rule'; exit 0; fi
        grep -vxF -- "$rule" "$rules" > "$rules.new" || true
        mv "$rules.new" "$rules"
        ;;
    *) echo "fake ufw: unsupported command: $*" >&2; exit 2 ;;
esac
FAKE
cat > "$TEST_DIR/fakebin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_DIR/calls"
case $* in
    *ips-v4) list=$FAKE_DIR/ips-v4 ;;
    *ips-v6) list=$FAKE_DIR/ips-v6 ;;
    *) exit 2 ;;
esac
[ -f "$list" ] || exit 22
cat "$list"
FAKE
cat > "$TEST_DIR/fakebin/nginx" <<'FAKE'
#!/usr/bin/env bash
echo "nginx $*" >> "$FAKE_DIR/calls"
FAKE
cat > "$TEST_DIR/fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_DIR/calls"
FAKE
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH
[ "$(command -v ufw)" = "$TEST_DIR/fakebin/ufw" ]
sshd() { echo 'port 2222'; }

# Cloudflare publishes the lists without a final newline.
cloudflare_lists() { printf '%s' "$1" > "$FAKE_DIR/ips-v4"; printf '%s' "$2" > "$FAKE_DIR/ips-v6"; }
rules() { cat "$FAKE_DIR/rules"; }
tagged() { grep -c "comment 'plusemu-cloudflare'" "$FAKE_DIR/rules" || true; }
expect_rule() { grep -qxF -- "$1" "$FAKE_DIR/rules" || { echo "expected rule: $1"; rules; exit 1; }; }
expect_no_rule() { if grep -qxF -- "$1" "$FAKE_DIR/rules"; then echo "unexpected rule: $1"; rules; exit 1; fi; }
expect_call() { grep -qxF -- "$1" "$FAKE_DIR/calls" || { echo "expected call: $1"; cat "$FAKE_DIR/calls"; exit 1; }; }
expect_no_call() { if grep -qxF -- "$1" "$FAKE_DIR/calls"; then echo "unexpected call: $1"; exit 1; fi; }
https_from() { printf "allow from %s to any port 443 proto tcp comment 'plusemu-cloudflare'" "$1"; }
run_firewall() { : > "$FAKE_DIR/calls"; : > "$TEST_DIR/terminal"; configure_firewall; }

# Fresh install: HTTPS opens to every address, then only Cloudflare's ranges keep it.
cloudflare_lists $'173.245.48.0/20\n103.21.244.0/22\n104.16.0.0/13' $'2400:cb00::/32\n2606:4700::/32'
run_firewall
expect_rule 'allow 22/tcp'
expect_rule 'allow 2222/tcp'
expect_rule 'allow 80/tcp'
expect_no_rule 'allow 443/tcp'
for range in 173.245.48.0/20 103.21.244.0/22 104.16.0.0/13 2400:cb00::/32 2606:4700::/32; do expect_rule "$(https_from "$range")"; done
[ "$(tagged)" = 5 ]
status=$(ufw status)
grep -q '^443/tcp ALLOW IN 173.245.48.0/20 # plusemu-cloudflare$' <<< "$status"
if grep -q '^443/tcp ALLOW IN Anywhere' <<< "$status"; then echo 'HTTPS is still open to every address'; exit 1; fi
grep -qx 'set_real_ip_from 2606:4700::/32;' "$REAL_IP_CONF"
grep -qx 'real_ip_header CF-Connecting-IP;' "$REAL_IP_CONF"
grep -qx '    default 0;' "$REAL_IP_CONF"
grep -qx '    104.16.0.0/13 1;' "$REAL_IP_CONF"
grep -qx '    127.0.0.0/8 1;' "$REAL_IP_CONF"
expect_call 'systemctl try-reload-or-restart nginx'
[ -x "$CLOUDFLARE_COMMAND" ]
grep -qxF "0 3 * * 0 root $CLOUDFLARE_COMMAND >> $CLOUDFLARE_LOG 2>&1" "$CLOUDFLARE_CRON"
grep -q 'HTTPS is accepted only from Cloudflare' "$TEST_DIR/terminal"
# The health check reads the result from the Cloudflare log.
grep -q "HTTPS is accepted only from Cloudflare's 5 address ranges." "$CLOUDFLARE_LOG"
# Without CrowdSec, the refresh writes no CrowdSec whitelist.
[ ! -e "$(dirname "$CROWDSEC_WHITELIST")" ]

# fail2ban puts its bans first; they stay first through every refresh.
ufw insert 1 deny from 203.0.113.9 to any > /dev/null
before=$(rules)

# A rerun changes nothing: no duplicate rules, HTTPS never opens to everyone and nginx is not reloaded.
run_firewall
[ "$(rules)" = "$before" ]
expect_no_call 'ufw allow 443/tcp'
expect_no_call 'systemctl try-reload-or-restart nginx'

# The weekly run cannot download the lists: the firewall and nginx stay as they are and the run fails.
conf=$(< "$REAL_IP_CONF")
rm "$FAKE_DIR/ips-v6"
: > "$FAKE_DIR/calls"
if "$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1; then echo 'a failed download was reported as a refresh'; exit 1; fi
[ "$(rules)" = "$before" ]
[ "$(< "$REAL_IP_CONF")" = "$conf" ]
expect_no_call 'systemctl try-reload-or-restart nginx'
grep -q 'were left as they are' "$CLOUDFLARE_LOG"

# A page that is not an address list counts as a failed download.
for broken in '<html>Attention Required</html>' '' '2400:cb00::/32' '173.245.48.0/20 104.16.0.0/13' '173.245.48.1/20'; do
    cloudflare_lists "$broken" $'2400:cb00::/32\n2606:4700::/32'
    if "$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1; then echo "accepted a broken list: $broken"; exit 1; fi
    [ "$(rules)" = "$before" ]
done
[ "$(< "$REAL_IP_CONF")" = "$conf" ]

# A changed list replaces exactly the ranges that changed.
cloudflare_lists $'173.245.48.0/20\n104.16.0.0/13\n131.0.72.0/22' $'2400:cb00::/32\n2606:4700::/32'
: > "$FAKE_DIR/calls"
"$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1
expect_no_rule "$(https_from 103.21.244.0/22)"
expect_call 'ufw delete allow proto tcp from 103.21.244.0/22 to any port 443 comment plusemu-cloudflare'
expect_rule "$(https_from 131.0.72.0/22)"
[ "$(tagged)" = 5 ]
[ "$(head -1 "$FAKE_DIR/rules")" = 'deny from 203.0.113.9 to any' ]
expect_rule 'allow 80/tcp'
expect_rule 'allow 2222/tcp'
expect_no_rule 'allow 443/tcp'
for kept in 173.245.48.0/20 104.16.0.0/13 2400:cb00::/32 2606:4700::/32; do expect_no_call "ufw delete allow proto tcp from $kept to any port 443 comment plusemu-cloudflare"; done
grep -qx 'set_real_ip_from 131.0.72.0/22;' "$REAL_IP_CONF"
if grep -q '103.21.244.0/22' "$REAL_IP_CONF"; then echo 'nginx still trusts a removed range'; exit 1; fi
expect_call 'systemctl try-reload-or-restart nginx'

# With CrowdSec, the refresh gives it the new ranges, so it never bans a Cloudflare edge.
mkdir -p "$(dirname "$CROWDSEC_WHITELIST")"
cloudflare_lists $'173.245.48.0/20\n104.16.0.0/13\n198.41.128.0/17' $'2400:cb00::/32\n2606:4700::/32'
: > "$FAKE_DIR/calls"
"$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1
grep -qxF '    - "198.41.128.0/17"' "$CROWDSEC_WHITELIST"
grep -qxF '    - "127.0.0.1"' "$CROWDSEC_WHITELIST"
if grep -qF '131.0.72.0/22' "$CROWDSEC_WHITELIST"; then echo 'CrowdSec still trusts a removed range'; exit 1; fi
expect_call 'systemctl reload crowdsec'
: > "$FAKE_DIR/calls"
"$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1
expect_no_call 'systemctl reload crowdsec'
rm -r "$TEST_DIR/crowdsec"
cloudflare_lists $'173.245.48.0/20\n104.16.0.0/13\n131.0.72.0/22' $'2400:cb00::/32\n2606:4700::/32'
"$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1

# nginx rejects the new settings: the previous file comes back and the run fails.
conf=$(< "$REAL_IP_CONF")
cloudflare_lists $'173.245.48.0/20\n104.16.0.0/13' $'2400:cb00::/32'
printf '#!/usr/bin/env bash\n[ "$1" != -t ]\n' > "$TEST_DIR/fakebin/nginx"
if "$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1; then echo 'a rejected nginx file was reported as a refresh'; exit 1; fi
[ "$(< "$REAL_IP_CONF")" = "$conf" ]
printf '#!/usr/bin/env bash\necho "nginx $*" >> "$FAKE_DIR/calls"\n' > "$TEST_DIR/fakebin/nginx"

# Another rule that opens HTTPS to everyone is named, not removed.
cloudflare_lists $'173.245.48.0/20\n104.16.0.0/13\n131.0.72.0/22' $'2400:cb00::/32\n2606:4700::/32'
ufw allow 'Nginx Full' > /dev/null
"$CLOUDFLARE_COMMAND" > "$TEST_DIR/refresh" 2>&1
grep -q "ufw delete allow 'Nginx Full'" "$TEST_DIR/refresh"
expect_rule "allow 'Nginx Full'"
ufw delete allow 'Nginx Full' > /dev/null

# With IPv6 off, ufw refuses IPv6 rules, so only the IPv4 ranges are touched.
echo 'IPV6=no' > "$UFW_DEFAULTS"
cloudflare_lists $'173.245.48.0/20\n104.16.0.0/13\n131.0.72.0/22' $'2606:4700::/32'
: > "$FAKE_DIR/calls"
"$CLOUDFLARE_COMMAND" >> "$CLOUDFLARE_LOG" 2>&1
if grep -q '^ufw .*:.* port 443' "$FAKE_DIR/calls"; then echo 'an IPv6 rule was changed with IPv6 off'; exit 1; fi
expect_call 'ufw allow proto tcp from 131.0.72.0/22 to any port 443 comment plusemu-cloudflare'
echo 'IPV6=yes' > "$UFW_DEFAULTS"

# A fresh install that cannot download the lists keeps HTTPS open and says so.
: > "$FAKE_DIR/rules"
rm -f "$FAKE_DIR/ips-v4" "$REAL_IP_CONF"
cloudflare_real_ip
grep -qx 'set_real_ip_from 173.245.48.0/20;' "$REAL_IP_CONF"
# Ranges that were not downloaded may be out of date, so nginx blocks nobody with them.
grep -qx '    default 1;' "$REAL_IP_CONF"
run_firewall
expect_rule 'allow 443/tcp'
[ "$(tagged)" = 0 ]
grep -q 'HTTPS stays open to every address' "$TEST_DIR/terminal"

# The installer keeps the current nginx ranges when the download fails on a rerun.
printf 'set_real_ip_from 198.51.100.0/24;\ngeo $realip_remote_addr $plusemu_from_cloudflare { default 0; }\n' > "$REAL_IP_CONF"
conf=$(< "$REAL_IP_CONF")
cloudflare_real_ip
[ "$(< "$REAL_IP_CONF")" = "$conf" ]

# A file from an older installer lacks the check the hotel's nginx settings use, so it is written again.
echo 'set_real_ip_from 198.51.100.0/24;' > "$REAL_IP_CONF"
cloudflare_real_ip
grep -q 'plusemu_from_cloudflare' "$REAL_IP_CONF"

printf 'Bash firewall checks passed\n' >&4

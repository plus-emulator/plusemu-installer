#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090,SC2016 # the overrides are read by the sourced install.sh functions; the state file is sourced
# Switch a hotel's language against fake curl, sql, php and systemctl programs, and check what it writes.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$FAKE_DIR/statements" "$TEST_DIR/log" "$TEST_DIR/terminal" "$TEST_DIR/calls" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

HOTEL_ROOT=$TEST_DIR/hotel
STATE_FILE=$TEST_DIR/etc/hotel.env
LOCK_FILE=$TEST_DIR/lock
LOG=$TEST_DIR/language.log
LANGUAGE_MANIFEST_URL=https://assets.test/language
export FAKE_DIR=$TEST_DIR/fake
files=$HOTEL_ROOT/hotel-files
renderer=$HOTEL_ROOT/client/configuration/renderer-config.json
config=$HOTEL_ROOT/emulator/Config/config.json
mkdir -p "$TEST_DIR/fakebin" "$FAKE_DIR/language" "$files/gamedata" "$HOTEL_ROOT/client/configuration" "$HOTEL_ROOT/emulator/Config" "$HOTEL_ROOT/cms"
for program in systemctl php; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$program" "$TEST_DIR" > "$TEST_DIR/fakebin/$program"
done
chmod +x "$TEST_DIR/fakebin/"*
export PATH=$TEST_DIR/fakebin:$PATH
sql() { printf 'sql %s\n' "$*" >> "$TEST_DIR/calls"; cat > "$FAKE_DIR/statements"; }
wait_for_emulator() { :; }
# The published files are served from the fake folder, like assets.plusemu.dev.
curl() {
    local arg url='' out='' prev=''
    for arg in "$@"; do
        if [ "$prev" = -o ]; then out=$arg; fi
        if [[ $arg == http* ]]; then url=$arg; fi
        prev=$arg
    done
    case $url in
        https://assets.test/language/*)
            [ -f "$FAKE_DIR/language/${url##*/}" ] || return 22
            cp "$FAKE_DIR/language/${url##*/}" "$out" ;;
        *) return 7 ;;
    esac
}
publish() { # publish <code> <greeting>: a pack with ExternalTexts, UITexts and names, and its manifest
    local pack=$TEST_DIR/pack-$1
    rm -rf "$pack" && mkdir -p "$pack"
    jq -n --arg greeting "$2" '{"widget.greeting": $greeting}' > "$pack/ExternalTexts.json"
    printf '{\n    // %s\n    "connection.login.name": "Name"\n}\n' "$1" > "$pack/UITexts.jsonc"
    jq -n --arg greeting "$2" --arg description "Für O'Brien \\ Bücher." \
        '{"shelves_norja": {name: ("Regal " + $greeting), description: $description}}' > "$pack/furni-names.json"
    jq -n '{"shelves_norja": {name: "Beiges Regal", description: "Für Bücher."}, "25": {name: "Schulset", description: "Blau."}}' > "$pack/product-names.json"
    tar czf "$FAKE_DIR/language/language-$1.tar.gz" -C "$pack" .
    jq -n --arg code "$1" --arg sum "$(sha256sum "$FAKE_DIR/language/language-$1.tar.gz" | cut -d' ' -f1)" '{
        language: $code, hotel: "https://www.habbo.test", version: $sum[:12],
        url: "https://assets.test/language/language-\($code).tar.gz", sha256: $sum}' > "$FAKE_DIR/language/$1.json"
}
DOMAIN=example.com WS_URL=wss://example.com/ws HOTEL_NAME=Example ADMIN_USER=admin ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=initial-admin-password DB_PASSWORD=database-password GUIDE_TOKEN=guidetoken12 GUIDE_MODE=simple LOCAL=no

# The stock hotel: English gamedata, the installer's client settings, an emulator with the AIR client and the website.
jq -n '{productdata: {product: [{code: "shelves_norja", name: "Beige Bookcase", description: "For books.", extra: 1},
    {code: "chair", name: "Chair", description: "Sit."}, {code: 25, name: "School Set", description: "Blue."}]}}' > "$files/gamedata/ProductData.json"
jq -n '{roomitemtypes: {furnitype: [{id: 13, classname: "shelves_norja", name: "Beige Bookcase", description: "For books."}]},
    wallitemtypes: {furnitype: [{id: 4001, classname: "poster", name: "Poster", description: null}]}}' > "$files/gamedata/FurnitureData.json"
cat > "$renderer" <<'EOF'
{
    "external.texts.url": [
        "${gamedata.url}/ExternalTexts.json?t=%timestamp%",
        "${gamedata.url}/UITexts.jsonc?t=%timestamp%",
        "${gamedata.url}/hotel-texts.json?t=%timestamp%"
    ],
    "productdata.url": "${gamedata.url}/ProductData.json?t=%timestamp%",
    "furni.rotation.bounce.height": 0.0625
}
EOF
stock_renderer=$(< "$renderer")
cat > "$config" <<EOF
{"AirClient": {"ExternalTextsFiles": ["air/external_flash_texts.txt", "$files/gamedata/ExternalTexts.json", "my-texts.txt"],
    "ProductDataFile": "$files/gamedata/ProductData.json"}, "Database": {"Password": "secret"}}
EOF
chmod 600 "$config"
stock_config=$(< "$config")
printf 'APP_NAME="Example"\nAPP_LOCALE="en"\n' > "$HOTEL_ROOT/cms/.env"
renderer_value() { jq -r "$1" "$renderer"; }
config_value() { jq -r "$1" "$config"; }

# ---------------------------------------------------------------- the saved choice

select_language
[ "$HOTEL_LANGUAGE" = en ]
LANGUAGE_OPTION=de select_language
[ "$HOTEL_LANGUAGE" = de ]
PLUSEMU_LANGUAGE='nl' select_language en
[ "$HOTEL_LANGUAGE" = nl ]
select_language fr
[ "$HOTEL_LANGUAGE" = fr ]
# The system's own LANGUAGE variable is not the hotel's.
LANGUAGE=en_US:en select_language
[ "$HOTEL_LANGUAGE" = en ]
(LANGUAGE_OPTION=xx select_language) && exit 1
grep -q 'Unknown language: xx' "$TEST_DIR/terminal"
HOTEL_LANGUAGE=de FURNI_LANGUAGE=en
save_state
grep -qx "HOTEL_LANGUAGE='de'" "$STATE_FILE"
grep -qx "FURNI_LANGUAGE='en'" "$STATE_FILE"

# ---------------------------------------------------------------- the published pack

publish de Hallo
fetch_language_pack
[ "$(language_active)" = de ]
[ "$(jq -r '."widget.greeting"' "$files/language/ExternalTexts.json")" = Hallo ]
# A pack that does not match its checksum changes nothing, and says why.
publish de Servus
printf 'tampered' >> "$FAKE_DIR/language/language-de.tar.gz"
fetch_language_pack && exit 1
[[ $LANGUAGE_ERROR == *German*checksum* ]]
[ "$(jq -r '."widget.greeting"' "$files/language/ExternalTexts.json")" = Hallo ]
# A list for another language is refused too.
publish de Hallo
jq '.language = "nl"' "$FAKE_DIR/language/de.json" > "$FAKE_DIR/language/de.json.new" && mv "$FAKE_DIR/language/de.json.new" "$FAKE_DIR/language/de.json"
fetch_language_pack && exit 1
[[ $LANGUAGE_ERROR == *"$LANGUAGE_MANIFEST_URL/de.json"* ]]
[ "$(language_active)" = de ]
# No leftovers next to the hotel files.
[ -z "$(find "$files" -maxdepth 1 -name '.language.*')" ]

# ---------------------------------------------------------------- switching to German

publish de Hallo
: > "$TEST_DIR/calls"
language_apply 1
grep -q 'German language pack downloaded and checked' "$TEST_DIR/terminal"
# The client loads the German texts right after the stock ones, so the hotel's own texts still win.
[ "$(renderer_value '."external.texts.url" | join(",")')" = '${gamedata.url}/ExternalTexts.json?t=%timestamp%,https://example.com/hotel-files/language/ExternalTexts.json?t=%timestamp%,${gamedata.url}/UITexts.jsonc?t=%timestamp%,https://example.com/hotel-files/language/UITexts.jsonc?t=%timestamp%,${gamedata.url}/hotel-texts.json?t=%timestamp%' ]
[ "$(renderer_value '."productdata.url"')" = 'https://example.com/hotel-files/language/ProductData.json?t=%timestamp%' ]
grep -q '"furni.rotation.bounce.height": 0.0625' "$renderer"
# The products keep every stock entry and field, with the German names where the pack has them.
[ "$(jq -c '.productdata.product' "$files/language/ProductData.json")" = '[{"code":"shelves_norja","name":"Beiges Regal","description":"Für Bücher.","extra":1},{"code":"chair","name":"Chair","description":"Sit."},{"code":25,"name":"Schulset","description":"Blau."}]' ]
# The AIR client gets the German texts last and the German products; its other settings stay.
[ "$(config_value '.AirClient.ExternalTextsFiles | join(",")')" = "air/external_flash_texts.txt,$files/gamedata/ExternalTexts.json,my-texts.txt,$files/language/ExternalTexts.json" ]
[ "$(config_value .AirClient.ProductDataFile)" = "$files/language/ProductData.json" ]
[ "$(config_value .Database.Password)" = secret ] && [ "$(stat -c %a "$config")" = 600 ]
# The website defaults to German.
grep -qx 'APP_LOCALE="de"' "$HOTEL_ROOT/cms/.env"
grep -q 'php artisan optimize' "$TEST_DIR/calls"
# The furniture names come from the pack, quoted for SQL, and are saved as German.
grep -q '^sql plus' "$TEST_DIR/calls"
# One backslash becomes two and one quote becomes two, so MariaDB reads the text back as it was.
grep -qF "('shelves_norja', 'Regal Hallo', 'Für O''Brien \\\\ Bücher.')" "$FAKE_DIR/statements"
grep -q 'UPDATE furniture f INNER JOIN language_furni_names n ON n.classname = f.item_name' "$FAKE_DIR/statements"
grep -qx "FURNI_LANGUAGE='de'" "$STATE_FILE"
grep -q 'Furniture names are now German' "$TEST_DIR/terminal"
# The running emulator restarts to read its new settings.
grep -q 'systemctl restart plusemu' "$TEST_DIR/calls"

# A second run changes nothing: no names written again, no restart, no website rebuild.
renderer_after=$(< "$renderer") config_after=$(< "$config")
: > "$TEST_DIR/calls"
language_apply 1
[ "$(< "$renderer")" = "$renderer_after" ] && [ "$(< "$config")" = "$config_after" ]
if grep -q '^sql\|restart\|optimize' "$TEST_DIR/calls"; then exit 1; fi

# The AIR settings the installer writes again keep the German products.
AIR_PORT=30000 SERVER_IP=192.0.2.10
air_game_host() { printf 192.0.2.10; }
air_settings "$config"
[ "$(config_value .AirClient.ProductDataFile)" = "$files/language/ProductData.json" ]
[ "$(config_value '[.AirClient.ExternalTextsFiles[] | select(. == "'"$files"'/language/ExternalTexts.json")] | length')" = 1 ]
echo "$stock_config" > "$config"

# ---------------------------------------------------------------- a pack that cannot be downloaded

# A hotel with German texts keeps them when the pack list is gone.
rm "$FAKE_DIR/language/de.json"
: > "$TEST_DIR/terminal"
language_apply 1
grep -q 'keeps the German texts it had' "$TEST_DIR/terminal"
[ "$(language_active)" = de ]
[ "$(config_value .AirClient.ProductDataFile)" = "$files/language/ProductData.json" ]
# A hotel without them stays English for now and says how to try again.
rm -rf "$files/language"
: > "$TEST_DIR/terminal"
language_apply 1
grep -q 'stays English for now. Try again later: sudo plusemu-update --language de' "$TEST_DIR/terminal"
[ "$(renderer_value '."productdata.url"')" = '${gamedata.url}/ProductData.json?t=%timestamp%' ]
[ "$(config_value .AirClient.ProductDataFile)" = "$files/gamedata/ProductData.json" ]
# The furniture names follow what the client shows, so they go back to English.
grep -qF "('shelves_norja', 'Beige Bookcase', 'For books.')" "$FAKE_DIR/statements"
grep -qF "('poster', 'Poster', '')" "$FAKE_DIR/statements"
grep -qx "FURNI_LANGUAGE='en'" "$STATE_FILE"

# ---------------------------------------------------------------- back to English

publish de Hallo
language_apply 1
[ "$(language_active)" = de ]
HOTEL_LANGUAGE=en
save_state
: > "$TEST_DIR/calls"
language_apply 1
[ ! -e "$files/language" ]
[ "$(jq -S . "$renderer")" = "$(jq -S . <<< "$stock_renderer")" ]
[ "$(jq -S . "$config")" = "$(jq -S . <<< "$stock_config")" ]
grep -qx 'APP_LOCALE="en"' "$HOTEL_ROOT/cms/.env"
grep -qx "FURNI_LANGUAGE='en'" "$STATE_FILE"
grep -q 'systemctl restart plusemu' "$TEST_DIR/calls"

# A client configuration that is not plain JSON is left alone, with a warning.
printf '{ // my notes\n}\n' > "$renderer"
: > "$TEST_DIR/terminal"
language_client_config "$renderer"
[ "$(< "$renderer")" = $'{ // my notes\n}' ]
grep -q 'not plain JSON' "$TEST_DIR/terminal"

# ---------------------------------------------------------------- plusemu-update --language

(update_main --language) && exit 1
grep -q 'Usage: plusemu-update --language <code>' "$TEST_DIR/terminal"
language_main() { echo "language_main $LANGUAGE_OPTION" >> "$TEST_DIR/calls"; }
update_main --language nl
update_main --language=fr
grep -qx 'language_main nl' "$TEST_DIR/calls"
grep -qx 'language_main fr' "$TEST_DIR/calls"

echo "language: all checks passed" >&4

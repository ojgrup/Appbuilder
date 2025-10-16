#!/usr/bin/env bash

# Constants for colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values for keygen
INFO="CN=appbuilder, OU=appbuilder, O=appbuilder, L=banjar, ST=kalimantan selatan, C=62"

# Helper functions for logging and error handling
log() {
    echo -e "${GREEN}INFO:${NC} $*"
}

info() {
    echo -e "${BLUE}*${NC} $*"
}

warn() {
    echo -e "${YELLOW}WARN:${NC} $*"
}

error() {
    echo -e "${RED}ERROR:${NC} $*" >&2
    exit 1
}

try() {
    echo -e "${BOLD}> $*${NC}"
    if ! eval "$@"; then
        error "Command failed: $*"
    fi
}


set_var() {
    # PERBAIKAN: Fungsi ini telah diubah untuk memiliki definisi dan skrip AWK yang dibungkus dengan benar.
    # Ini mengatasi 'syntax error near unexpected token {'.

    local var_name var_value
    # Parse the input string like "key = value"
    if ! [[ "$1" =~ ^([a-zA-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*) ]]; then
        error "Invalid variable assignment: $1"
    fi
    var_name="${BASH_REMATCH[1]}"
    var_value="${BASH_REMATCH[2]}"

    local var="$var_name"
    local val="$var_value"
    local java_file="app/src/main/java/com/$appname/webtoapk/MainActivity.java"
    local tmp_file=$(mktemp)

    # Membungkus skrip AWK dalam tanda kutip tunggal ('...')
    awk -v var="$var" -v val="$val" '
    {
        if (!found && $0 ~ var " *= *.*;" ) {
            # Сохраняем начало строки до =
            match($0, "^.*" var " *=")
            before = substr($0, RSTART, RLENGTH)
            # Заменяем значение
            print before " " val ";"
            # Делаем замену только для первого найденного
            found = 1
        } else {
            print $0
        }
    }' "$java_file" > "$tmp_file"
    
    if ! diff -q "$java_file" "$tmp_file" >/dev/null; then
        mv "$tmp_file" "$java_file"
        log "Updated $var_name to $var_value"
        # Special handling for geolocationEnabled
        if [ "$var_name" = "geolocationEnabled" ]; then
            update_geolocation_permission ${var_value//\"/}
        fi
    else
        rm "$tmp_file"
    fi
}

merge_config_with_default() {
    local default_conf="app/default.conf"
    local user_conf="$1"
    local merged_conf
    merged_conf=$(mktemp)

    # Temporary file for default lines that are missing in user config
    local temp_defaults
    temp_defaults=$(mktemp)

    # For each non-empty, non-comment line in default.conf
    while IFS= read -r line; do
        # Extract key (everything up to '=')
        key=$(echo "$line" | cut -d '=' -f1 | xargs)
        if [ -n "$key" ]; then
            # Check if the key is missing in the user config
            if ! grep -q -E "^[[:space:]]*$key[[:space:]]*=" "$user_conf"; then
                # Key is missing – add the default line
                echo "$line" >> "$temp_defaults"
            fi
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$default_conf")

    # Now combine default lines (if any) with the user configuration.
    # The defaults will be added on top, but since they are defined earlier they
    # can be overridden by any subsequent assignment (если вдруг порядок имеет значение).
    cat "$temp_defaults" "$user_conf" > "$merged_conf"

    rm -f "$temp_defaults"
    echo "$merged_conf"
}

apply_config() {
    local config_file="${1:-webapk.conf}"

    # If config file is not found in project root, try in caller's directory
    if [ ! -f "$config_file" ] && [ -f "$ORIGINAL_PWD/$config_file" ]; then
        config_file="$ORIGINAL_PWD/$config_file"
    fi

    [ ! -f "$config_file" ] && error "Config file not found: $config_file"

    export CONFIG_DIR="$(dirname "$config_file")"

    info "Using config: $config_file"

    config_file=$(merge_config_with_default "$config_file")
    
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        case "$key" in
            "id")
                chid "$value"
                ;;
            "name")
                rename "$value"
                ;;
            "deeplink")
                set_deep_link "$value"
                ;;
            "trustUserCA")
                set_network_security_config "$value"
                ;;
            "icon")
                set_icon "$value"
                ;;
            "scripts")
                set_userscripts $value
                ;;
            *)
                set_var "$key = $value"
                ;;
        esac
    done < <(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]\+#.*//' "$config_file")
}


apk() {
    if [ ! -f "app/my-release-key.jks" ]; then
        error "Keystore file not found. Run './make.sh keygen' first"
    fi

    rm -f app/build/outputs/apk/release/app-release.apk

    info "Building APK..."
    try "./gradlew assembleRelease --no-daemon --quiet"

    if [ -f "app/build/outputs/apk/release/app-release.apk" ]; then
        log "APK successfully built and signed"
        try "cp app/build/outputs/apk/release/app-release.apk '$appname.apk'"
        echo -e "${BOLD}----------------"
        echo -e "Final APK copied to: ${GREEN}$appname.apk${NC}"
        echo -e "Size: ${BLUE}$(du -h app/build/outputs/apk/release/app-release.apk | cut -f1)${NC}"
        echo -e "Package: ${BLUE}com.${appname}.webtoapk${NC}"
        echo -e "App name: ${BLUE}$(grep -o 'app_name">[^<]*' app/src/main/res/values/strings.xml | cut -d'>' -f2)${NC}"
        echo -e "URL: ${BLUE}$(grep '

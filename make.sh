#!/bin/bash
# WebToAPK Build Script

# --- Konfigurasi Default ---
# GANTI INI dengan PACKAGE NAME BAWAAN REPO ANDA. Contoh: com.ojgrup.webtoapk
DEFAULT_PACKAGE_NAME="com.ojgrup.webtoapk" 
DEFAULT_APP_NAME="Web App"
DEFAULT_MAIN_URL="https://example.com"
CONFIG_DIR=$(dirname "$0")
# ---

# Fungsi Logging
log() { echo -e "\n[*] $@"; }
info() { echo -e "[i] $@"; }
error() { echo -e "\n[!] $@" >&2; exit 1; }

# Fungsi untuk memuat konfigurasi dari webapk.conf
load_config() {
    [ ! -f "$1" ] && error "Config file not found: $1"
    info "Using config: $1"
    source "$1"
    
    [ -z "$APP_ID" ] && error "APP_ID is missing in config."
    [ -z "$APP_NAME" ] && error "APP_NAME is missing in config."
    [ -z "$MAIN_URL" ] && error "MAIN_URL is missing in config."
    
    NEW_PACKAGE_SUFFIX=${PACKAGE_SUFFIX:-code}
    NEW_PACKAGE_SUFFIX=$(echo "$NEW_PACKAGE_SUFFIX" | tr -d '\r')
    
    NEW_PACKAGE_NAME=$(echo "$DEFAULT_PACKAGE_NAME.$NEW_PACKAGE_SUFFIX" | tr -d '\r')
    
    log "New App ID: $NEW_PACKAGE_NAME"
}

# Fungsi untuk membuat file webapk.conf dari payload GitHub Actions
create_config_from_payload() {
    local payload_path="$1"
    [ ! -f "$payload_path" ] && error "Payload file not found at $payload_path"
    
    APP_ID=$(jq -r '.client_payload.app_id' "$payload_path")
    APP_NAME=$(jq -r '.client_payload.app_name' "$payload_path" | sed 's/"//g')
    MAIN_URL=$(jq -r '.client_payload.main_url' "$payload_path" | sed 's/"//g')
    ICON_URL=$(jq -r '.client_payload.icon_url' "$payload_path" | sed 's/"//g')
    PACKAGE_SUFFIX=$(jq -r '.client_payload.package_suffix' "$payload_path" | sed 's/"//g')

    [ "$APP_ID" = "null" ] && error "Payload missing app_id."
    [ "$APP_NAME" = "null" ] && APP_NAME="$DEFAULT_APP_NAME"
    [ "$MAIN_URL" = "null" ] && MAIN_URL="$DEFAULT_MAIN_URL"
    [ "$PACKAGE_SUFFIX" = "null" ] && PACKAGE_SUFFIX="code"
    
    cat << EOF > webapk.conf
APP_ID="$APP_ID"
APP_NAME="$APP_NAME"
MAIN_URL="$MAIN_URL"
ICON_URL="$ICON_URL"
PACKAGE_SUFFIX="$PACKAGE_SUFFIX"
EOF

    info "webapk.conf created from Payload."
}

# Fungsi untuk mengganti Package Name dan merename folder
change_package() {
    local old_package_name="$1"
    local new_package_name="$2"
    
    if [ "$old_package_name" = "$new_package_name" ]; then
        info "Package name remains '$new_package_name'. Skipping rename."
        return 0
    fi
    
    log "Changing old ID: $old_package_name to new ID: $new_package_name"

    # 1. build.gradle
    info "Updating build.gradle..."
    sed -i "s/applicationId \"$old_package_name\"/applicationId \"$new_package_name\"/" app/build.gradle || error "Failed to change applicationId in build.gradle"

    # 2. Manifest, Strings, dan XML files
    info "Updating Manifest, Strings, and XML files..."
    grep -rl "$old_package_name" app/src/main/ | xargs sed -i "s/$old_package_name/$new_package_name/g"
    
    # 3. Mengubah Struktur Folder Java (PENTING!)
    local old_path=$(echo $old_package_name | tr . /)
    local new_path=$(echo $new_package_name | tr . /)
    local base_path="app/src/main/java"
    
    local old_dir="$base_path/$old_path"
    local new_dir="$base_path/$new_path"
    
    if [ ! -d "$old_dir" ]; then
        error "MainActivity.java not found. Old package directory ($old_dir) does not exist. HARAP BUAT FOLDER AWAL INI DI REPO!"
    fi

    info "Renaming package folder $old_dir to $new_dir..."
    mkdir -p "$(dirname "$new_dir")"
    mv "$old_dir" "$new_dir" || error "Failed to rename package directory."
    
    log "Package name change completed."
}

# Fungsi untuk mengganti Display Name (App Name)
set_display_name() {
    local new_name="$@"
    info "Updating display name to: $new_name"
    sed -i 's|<string name="app_name">.*</string>|<string name="app_name">'"$new_name"'</string>|g' app/src/main/res/values/strings.xml
    log "Display name changed successfully."
}

# Fungsi untuk mengganti URL Utama
set_main_url() {
    local new_url="$@"
    info "Updating URL to: $new_url"
    sed -i 's|<string name="main_url">.*</string>|<string name="main_url">'"$new_url"'</string>|g' app/src/main/res/values/strings.xml
    log "Updated MAIN_URL."
}

# Fungsi untuk mengganti Ikon Aplikasi (Mendukung URL Download)
set_icon() {
    local icon_path="$@"
    local dest_file="app/src/main/res/mipmap/ic_launcher.png"
    local temp_icon=$(mktemp)

    if [ -z "$icon_path" ]; then
        error "Icon path or URL not provided"
    fi

    if [[ "$icon_path" =~ ^https?:// ]]; then
        info "Downloading icon from URL: $icon_path"
        if ! wget -q --timeout=10 -O "$temp_icon" "$icon_path"; then
            error "Failed to download icon from URL: $icon_path"
        fi
        local source_file="$temp_icon"
    else
        if [ -n "${CONFIG_DIR:-}" ] && [[ "$icon_path" != /* ]]; then
            icon_path="$CONFIG_DIR/$icon_path"
        fi
        [ ! -f "$icon_path" ] && error "Local Icon file not found: $icon_path"
        local source_file="$icon_path"
    fi

    file_type=$(file -b --mime-type "$source_file")
    if [ "$file_type" != "image/png" ]; then
        rm -f "$temp_icon"
        error "Icon must be in PNG format, got: $file_type"
    fi

    mkdir -p "$(dirname "$dest_file")"
    
    if [ -f "$dest_file" ] && cmp -s "$source_file" "$dest_file"; then
        rm -f "$temp_icon"
        return 0
    fi
    
    if ! cp "$source_file" "$dest_file"; then
        rm -f "$temp_icon"
        error "Failed to copy icon to destination."
    fi

    log "Icon updated successfully"
    rm -f "$temp_icon"
}


# --- Fungsi Utama Build ---
build_apk() {
    local build_type="$1"
    local config_file="webapk.conf"

    if [ "$GITHUB_EVENT_NAME" = "repository_dispatch" ]; then
        create_config_from_payload "$GITHUB_EVENT_PATH"
    fi

    load_config "$config_file"
    
    log "Starting project modification..."
    
    change_package "$DEFAULT_PACKAGE_NAME" "$NEW_PACKAGE_NAME"
    set_display_name "$APP_NAME"
    set_main_url "$MAIN_URL"
    
    if [ -n "$ICON_URL" ]; then
        set_icon "$ICON_URL"
    elif [ -n "$ICON_PATH" ]; then
        set_icon "$ICON_PATH"
    fi
    
    log "Project modification finished. Starting Gradle build..."
    
    chmod +x ./gradlew
    
    local gradlew_cmd="./gradlew assemble$(tr '[:lower:]' '[:upper:]' <<< ${build_type:0:1})${build_type:1}"

    if ! $gradlew_cmd; then
        error "Gradle build failed with command: $gradlew_cmd"
    fi
    
    log "Build $build_type APK completed successfully!"
}

# --- Eksekusi Script ---
case "$1" in
    release)
        log "Starting Release APK build..."
        build_apk "release"
        ;;
    debug)
        log "Starting Debug APK build..."
        build_apk "debug"
        ;;
    *)
        error "Usage: $0 [release|debug]"
        ;;
esac

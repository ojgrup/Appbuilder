#!/usr/bin/env bash
set -eu

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# Info for keystore generation
INFO="CN=ojgrup, OU=ojgrup, O=ojgrup, L=banjar, S=State, C=US"
# Variabel global untuk package suffix. Default: webtoapk
PACKAGE_SUFFIX="webtoapk"

log() {
    echo -e "${GREEN}[+]${NC} $1"
}

info() {
    echo -e "${BLUE}[*]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1" >&2
    exit 1
}

try() {
    local log_file=$(mktemp)
    
    if [ $# -eq 1 ]; then
        if ! eval "$1" &> "$log_file"; then
            echo -e "${RED}[!]${NC} Failed: $1" >&2
            cat "$log_file" >&2
            rm -f "$log_file"
            exit 1
        fi
    else
        if ! "$@" &> "$log_file"; then
            echo -e "${RED}[!]${NC} Failed: $*" >&2
            cat "$log_file" >&2
            rm -f "$log_file"
            exit 1
        fi
    fi
    rm -f "$log_file"
}


set_var() {
    # Gunakan $appname dan $PACKAGE_SUFFIX yang sudah diupdate oleh chid
    local java_file="app/src/main/java/com/$appname/$PACKAGE_SUFFIX/MainActivity.java"
    [ ! -f "$java_file" ] && error "MainActivity.java not found"
    
    local pattern="$@"
    [ -z "$pattern" ] && error "Empty pattern. Usage: set_var \"varName = value\""
    
    local var_name="${pattern%% =*}"
    local new_value="${pattern#*= }"

    if ! grep -q "$var_name *= *.*;" "$java_file"; then
        error "Variable '$var_name' not found in MainActivity.java"
    fi

    local val_to_set
    if [[ ! "$new_value" =~ ^(true|false)$ ]]; then
        val_to_set="\"$new_value\""
    else
        val_to_set="$new_value"
    fi
    
    local tmp_file=$(mktemp)
    
    awk -v var="$var_name" -v val="$val_to_set" '
    {
        if (!found && $0 ~ var " *= *.*;" ) {
            match($0, "^.*" var " *=")
            before = substr($0, RSTART, RLENGTH)
            print before " " val ";"
            found = 1
        } else {
            print $0
        }
    }' "$java_file" > "$tmp_file"
    
    if ! diff -q "$java_file" "$tmp_file" >/dev/null; then
        mv "$tmp_file" "$java_file"
        log "Updated $var_name to $val_to_set"
        if [ "$var_name" = "geolocationEnabled" ]; then
            update_geolocation_permission ${new_value//\"/}
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

    local temp_defaults
    temp_defaults=$(mktemp)

    while IFS= read -r line; do
        key=$(echo "$line" | cut -d '=' -f1 | xargs)
        if [ -n "$key" ]; then
            if ! grep -q -E "^[[:space:]]*$key[[:space:]]*=" "$user_conf"; then
                echo "$line" >> "$temp_defaults"
            fi
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$default_conf")

    cat "$temp_defaults" "$user_conf" > "$merged_conf"

    rm -f "$temp_defaults"
    echo "$merged_conf"
}

apply_config() {
    local config_file="${1:-webapk.conf}"

    if [ ! -f "$config_file" ] && [ -f "$ORIGINAL_PWD/$config_file" ]; then
        config_file="$ORIGINAL_PWD/$config_file"
    fi

    [ ! -f "$config_file" ] && error "Config file not found: $config_file"

    export CONFIG_DIR="$(dirname "$config_file")"

    info "Using config: $config_file"

    config_file=$(merge_config_with_default "$config_file")

    # Ambil packageSuffix terlebih dahulu
    local package_suffix_value=$(awk -F'=' '/^[[:space:]]*packageSuffix[[:space:]]*=/ {gsub(/[[:space:]]+/, "", $2); print $2}' "$config_file")
    if [ -n "$package_suffix_value" ]; then
        PACKAGE_SUFFIX="$package_suffix_value"
    fi
    
    while IFS='=' read -r key value || [ -n "$key" ]; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        
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
            "packageSuffix")
                # Sudah diproses di atas
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
        echo -e "Package: ${BLUE}com.${appname}.${PACKAGE_SUFFIX}${NC}"
        echo -e "App name: ${BLUE}$(grep -o 'app_name">[^<]*' app/src/main/res/values/strings.xml | cut -d'>' -f2)${NC}"
        echo -e "URL: ${BLUE}$(grep 'String mainURL' app/src/main/java/com/$appname/$PACKAGE_SUFFIX/*.java | cut -d'"' -f2)${NC}"
        echo -e "${BOLD}----------------${NC}"
    else
        error "Build failed"
    fi
}

test() {
    info "Detected app name: $appname"
    try "adb install app/build/outputs/apk/release/app-release.apk"
    try "adb logcat -c" # clean logs
    try "adb shell am start -n com.$appname.$PACKAGE_SUFFIX/.MainActivity"
    echo "=========================="
    adb logcat | grep -oP "(?<=WebToApk: ).*"
}

keygen() {
    if [ -f "app/my-release-key.jks" ]; then
        warn "Keystore already exists"
        read -p "Do you want to replace it? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Cancelled"
            return 1
        fi
        rm app/my-release-key.jks
    fi

    info "Generating keystore..."
    try "keytool -genkey -v -keystore app/my-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias my -storepass '123456' -keypass '123456' -dname '$INFO'"
    log "Keystore generated successfully"
}

clean() {
    info "Cleaning build files..."
    try rm -rf app/build .gradle
    apply_config app/default.conf
    log "Clean completed"
}


chid() {
    [ -z "$1" ] && error "Please provide an application ID"

    if ! [[ $1 =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
        error "Invalid application ID. Use only letters, numbers and underscores, start with a letter"
    fi
    
    local NEW_APP_ID="$1"
    local OLD_SUFFIX="webtoapk" # Suffix yang dikodekan secara default di proyek
    local NEW_SUFFIX="$PACKAGE_SUFFIX" # Suffix baru dari config (default-nya 'webtoapk')
    local old_package="com.$appname.$OLD_SUFFIX"
    local new_package="com.$NEW_APP_ID.$NEW_SUFFIX"


    # 1. Ganti App ID lama ke App ID baru (misal: myapp ke ojgrup)
    try "find . -type f \( -name '*.gradle' -o -name '*.java' -o -name '*.xml' \) -exec \
        sed -i 's/$old_package/com.$NEW_APP_ID.$OLD_SUFFIX/g' {} +"

    if [ "$NEW_APP_ID" != "$appname" ]; then
        info "Old App ID: com.$appname.$OLD_SUFFIX"
        info "Renaming folder to: com.$NEW_APP_ID.$OLD_SUFFIX"
        
        # Pindahkan folder App ID (misal: dari /com/myapp ke /com/ojgrup)
        try "mv app/src/main/java/com/$appname app/src/main/java/com/$NEW_APP_ID"
        appname="$NEW_APP_ID"
    fi

    # 2. Ganti Suffix lama ke Suffix baru (misal: webtoapk ke customapp)
    if [ "$NEW_SUFFIX" != "$OLD_SUFFIX" ]; then
        
        info "Old Suffix: .$OLD_SUFFIX"
        info "New Suffix: .$NEW_SUFFIX"
        
        # Pindahkan folder suffix (misal: dari /ojgrup/webtoapk ke /ojgrup/customapp)
        # Hati-hati: Asumsi folder $OLD_SUFFIX masih ada di app/src/main/java/com/$appname/
        try "find app/src/main/java/com/$appname -type d -name '$OLD_SUFFIX' -exec mv {} app/src/main/java/com/$NEW_APP_ID/$NEW_SUFFIX \;"

        # Perbarui semua file dengan nama paket baru (mengganti string .webtoapk menjadi .customapp)
        try "find . -type f \( -name '*.gradle' -o -name '*.java' -o -name '*.xml' \) -exec \
            sed -i 's/\.$OLD_SUFFIX/\.$NEW_SUFFIX/g' {} +"
        
        log "Application ID changed successfully to com.$NEW_APP_ID.$NEW_SUFFIX"
    else
        log "Application ID changed successfully to com.$NEW_APP_ID.$OLD_SUFFIX"
    fi
}


rename() {
    local new_name="$*"
    
    if [ -z "$new_name" ]; then
        error "Please provide a display name\nUsage: $0 display_name \"My App Name\""
    fi
    
    find app/src/main/res/values* -name "strings.xml" | while read xml_file; do
        current_name=$(grep -o 'app_name">[^<]*' "$xml_file" | cut -d'>' -f2)
        if [ "$current_name" = "$new_name" ]; then
            continue
        fi
        
        escaped_name=$(echo "$new_name" | sed 's/[\/&]/\\&/g')
        try sed -i "s|<string name=\"app_name\">[^<]*</string>|<string name=\"app_name\">$escaped_name</string>|" "$xml_file"
        
        lang_code=$(echo "$xml_file" | grep -o 'values-[^/]*' | cut -d'-' -f2)
        if [ -z "$lang_code" ]; then
            lang_code="default"
        fi
        
        log "Display name changed to: $new_name (${lang_code})"
    done
}


set_deep_link() {
    local manifest_file="app/src/main/AndroidManifest.xml"
    local host="$@"
    local tmp_file
    tmp_file=$(mktemp)

    awk '
        /<intent-filter>/, /<\/intent-filter>/ {
            buffer = buffer $0 ORS
            if (/<\/intent-filter>/) {
                if (buffer !~ /android.intent.action.VIEW/) {
                    printf "%s", buffer
                }
                buffer = ""
            }
            next
        }
        { print }
    ' "$manifest_file" > "$tmp_file"

    if [ -n "$host" ]; then
        local new_tmp_file
        new_tmp_file=$(mktemp)
        awk -v host="$host" '
            /<\/intent-filter>/ && !inserted {
                print
                print "            <intent-filter>"
                print "                <action android:name=\"android.intent.action.VIEW\" />"
                print "                <category android:name=\"android.intent.category.DEFAULT\" />"
                print "                <category android:name=\"android.intent.category.BROWSABLE\" />"
                print "                <data android:scheme=\"http\" />"
                print "                <data android:scheme=\"https\" />"
                print "                <data android:host=\""host"\" />"
                print "            </intent-filter>"
                inserted=1
                next
            }
            { print }
        ' "$tmp_file" > "$new_tmp_file"

        mv "$new_tmp_file" "$tmp_file"
    fi

    if ! diff -q "$manifest_file" "$tmp_file" >/dev/null; then
        if [ -z "$host" ]; then
            log "Removing deeplink"
        else
            log "Setting deeplink host to: $host"
        fi
        try mv "$tmp_file" "$manifest_file"
    else
        rm "$tmp_file"
    fi
}

set_network_security_config() {
    local manifest_file="app/src/main/AndroidManifest.xml"
    local config_attr='android:networkSecurityConfig="@xml/network_security_config"'
    local enabled="$1"

    local tmp_file
    tmp_file=$(mktemp)

    if [ "$enabled" = "true" ]; then
        if ! grep -q "networkSecurityConfig" "$manifest_file"; then
            awk -v attr=" $config_attr" '
            /<\s*application/ { in_app_tag = 1 }
            in_app_tag && />/ {
                sub(/>/, attr ">")
                in_app_tag = 0
            }
            { print }
            ' "$manifest_file" > "$tmp_file"

            log "Enabling user CA support in AndroidManifest.xml"
            try mv "$tmp_file" "$manifest_file"
        else
            rm -f "$tmp_file"
        fi
    else
        if grep -q "networkSecurityConfig" "$manifest_file"; then
            sed "s# ${config_attr}##" "$manifest_file" > "$tmp_file"
            log "Disabling user CA support in AndroidManifest.xml"
            try mv "$tmp_file" "$manifest_file"
        else
            rm -f "$tmp_file"
        fi
    fi
}


set_icon() {
    local icon_path="$@"
    local default_icon="$PWD/app/example.png"
    local dest_file="app/src/main/res/mipmap/ic_launcher.png"
    
    if [ -z "$icon_path" ]; then
        icon_path="$default_icon"
    fi

    if [ -n "${CONFIG_DIR:-}" ] && [[ "$icon_path" != /* ]]; then
        icon_path="$CONFIG_DIR/$icon_path"
    fi

    [ ! -f "$icon_path" ] && error "Icon file not found: $icon_path"
    
    file_type=$(file -b --mime-type "$icon_path")
    if [ "$file_type" != "image/png" ]; then
        error "Icon must be in PNG format, got: $file_type"
    fi

    mkdir -p "$(dirname "$dest_file")"
    
    if [ -f "$dest_file" ] && cmp -s "$icon_path" "$dest_file"; then
        return 0
    fi

    if [ -z "$@" ]; then
        warn "Using example.png for icon"
    fi
    
    try "cp \"$icon_path\" \"$dest_file\""
    log "Icon updated successfully"
}


set_userscripts() {
    local scripts_dir="app/src/main/assets/userscripts"
    
    mkdir -p "$scripts_dir"
    
    if [ $# -eq 0 ] || [ -z "$1" ]; then
        if [ -n "$(ls -A $scripts_dir 2>/dev/null)" ]; then
            find "$scripts_dir" -mindepth 1 -delete
            log "Userscripts directory cleared"
        fi
        return 0
    fi

    local added=()
    local updated=()
    local removed=()
    
    local existing_scripts=()
    while IFS= read -r file; do
        existing_scripts+=("$(basename "$file")")
    done < <(find "$scripts_dir" -mindepth 1 -type f)

    local source_files=()
    for pattern in "$@"; do
        if [ -n "${CONFIG_DIR:-}" ] && [[ "$pattern" != /* ]]; then
            pattern="$CONFIG_DIR/$pattern"
        fi

        shopt -s nullglob
        for file in $pattern; do
            if [ -f "$file" ]; then
                source_files+=("$file")
            fi
        done
        shopt -u nullglob
    done

    local current_scripts=()
    for src_file in "${source_files[@]}"; do
        local base_name
        base_name=$(basename "$src_file")
        local dest_file="$scripts_dir/$base_name"
        
        current_scripts+=("$base_name")

        if [ ! -f "$dest_file" ]; then
            cp "$src_file" "$dest_file"
            added+=("$base_name")
        elif ! cmp -s "$src_file" "$dest_file"; then
            cp "$src_file" "$dest_file"
            updated+=("$base_name")
        fi
    done

    for script in "${existing_scripts[@]}"; do
        is_current=false
        for current in "${current_scripts[@]}"; do
            if [[ "$script" == "$current" ]]; then
                is_current=true
                break
            fi
        done
        if ! $is_current; then
            rm -f "$scripts_dir/$script"
            removed+=("$script")
        fi
    done

    if [ ${#removed[@]} -gt 0 ]; then
        for script in "${removed[@]}"; do
            log "Removed userscript: $script"
        done
    fi
    
    if [ ${#added[@]} -gt 0 ]; then
        for script in "${added[@]}"; do
            log "Added userscript: $script"
        done
    fi
    
    if [ ${#updated[@]} -gt 0 ]; then
        for script in "${updated[@]}"; do
            log "Updated userscript: $script"
        done
    fi

    if [ ${#removed[@]} -eq 0 ] && [ ${#added[@]} -eq 0 ] && [ ${#updated[@]} -eq 0 ]; then
        return 0
    fi
}


update_geolocation_permission() {
    local manifest_file="app/src/main/AndroidManifest.xml"
    local permission='<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />'
    local enabled="$1"

    local tmp_file=$(mktemp)

    if [ "$enabled" = "true" ]; then
        if ! grep -q "android.permission.ACCESS_FINE_LOCATION" "$manifest_file"; then
            awk -v perm="$permission" '
            {
                print $0
                if ($0 ~ /<manifest /) {
                    print "    " perm
                }
            }' "$manifest_file" > "$tmp_file"

            log "Added geolocation permission to AndroidManifest.xml"
            try mv "$tmp_file" "$manifest_file"
        fi
    else
        if grep -q "android.permission.ACCESS_FINE_LOCATION" "$manifest_file"; then
            grep -v "android.permission.ACCESS_FINE_LOCATION" "$manifest_file" > "$tmp_file"

            log "Removed geolocation permission from AndroidManifest.xml"
            try mv "$tmp_file" "$manifest_file"
        else
            rm "$tmp_file"
        fi
    fi
}


regradle() {
    info "Reinstalling Gradle..."
    try rm -rf gradle gradlew .gradle .gradle-cache
    try mkdir -p gradle/wrapper

    cat > gradle/wrapper/gradle-wrapper.properties << EOL
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-7.4-all.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOL

    try wget -q --show-progress https://raw.githubusercontent.com/gradle/gradle/v7.4.0/gradle/wrapper/gradle-wrapper.jar -O gradle/wrapper/gradle-wrapper.jar 
    try wget -q --show-progress https://raw.githubusercontent.com/gradle/gradle/v7.4.0/gradlew -O gradlew
    try chmod +x gradlew
    
    log "Gradle reinstalled successfully"
}


# FUNGSI UNTUK MENCARI JAVA HANYA DIGUNAKAN UNTUK MEMVERIFIKASI DI LOKAL.
# Di CI, ini akan selalu mengandalkan JAVA_HOME yang diset oleh action.
check_and_find_java() {
    # 1. Prioritas utama: Pastikan JAVA_HOME (dari CI atau lokal) adalah Java 17
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        local version
        version=$("$JAVA_HOME/bin/java" -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
        if [ "$version" = "17" ]; then
            info "Using system JAVA_HOME: $JAVA_HOME"
            export PATH="$JAVA_HOME/bin:$PATH"
            return 0
        fi
    fi

    # 2. Cek lokal/default Linux (Hanya dijalankan jika TIDAK di CI)
    if [ -z "${CI:-}" ]; then
        if command -v java >/dev/null 2>&1; then
            local version
            version=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
            if [ "$version" = "17" ]; then
                info "Found Java 17 in PATH."
                return 0
            fi
        fi
    fi
    
    return 1 # Java 17 tidak ditemukan atau tidak valid
}

download_java() {
    local install_dir="$PWD/jvm"
    local jdk_version="17.0.2"
    local jdk_hash="0022753d0cceecacdd3a795dd4cea2bd7ffdf9dc06e22ffd1be98411742fbb44"
    local jdk_url="https://download.java.net/java/GA/jdk17.0.2/dfd4a8d0985749f896bed50d7138ee7f/8/GPL/openjdk-17.0.2_linux-x64_bin.tar.gz"

    if [ -d "$install_dir/jdk-${jdk_version}" ]; then
        info "OpenJDK ${jdk_version} already downloaded"
        export JAVA_HOME="$install_dir/jdk-${jdk_version}"
        export PATH="$JAVA_HOME/bin:$PATH"
        return 0
    fi

    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"
    
    info "Downloading OpenJDK ${jdk_version}..."
    try "wget -q --show-progress '$jdk_url' -O openjdk.tar.gz"
    
    info "Verifying checksum..."
    try "echo '${jdk_hash} openjdk.tar.gz' | sha256sum -c -"
    
    info "Unpacking to ${install_dir}..."
    try "mkdir -p '$install_dir'"
    try "tar xf openjdk.tar.gz"
    try "mv jdk-${jdk_version} '$install_dir/'"
    
    cd "$OLDPWD"
    rm -rf "$tmp_dir"

    export JAVA_HOME="$install_dir/jdk-${jdk_version}"
    export PATH="$JAVA_HOME/bin:$PATH"
    
    log "OpenJDK ${jdk_version} downloaded successfully!"
}


build() {
    apply_config $@
    apk
}

debug() {
    apply_config $@
    info "Building debug APK..."
    try "./gradlew assembleDebug --no-daemon --quiet"
    if [ -f "app/build/outputs/apk/debug/app-debug.apk" ]; then
        log "Debug APK successfully built"
    else
        error "Debug build failed"
    fi
}

###############################################################################

ORIGINAL_PWD="$PWD"

# Change directory to the directory where make.sh resides (project root)
try cd "$(dirname "$0")"

# PERBAIKAN KRITIS UNTUK CI: JANGAN TIMPA ANDROID_HOME.
# CI akan selalu mengeset ANDROID_HOME. Kita hanya perlu ini di lokal.
if [ -z "${CI:-}" ]; then
    # Jika TIDAK di CI, periksa path lokal untuk ANDROID_HOME jika belum ada.
    if [ -d "$PWD/cmdline-tools" ]; then
        export ANDROID_HOME=$PWD/cmdline-tools/
    fi
fi

# Appname harus diambil dengan asumsi PACKAGE_SUFFIX default/lama (webtoapk)
# Ini penting karena apply_config yang mengubah PACKAGE_SUFFIX dipanggil setelah inisialisasi ini.
appname=$(grep -Po '(?<=applicationId "com\.)[^.]*' app/build.gradle)

# Set Gradle's cache directory to be local to the project
export GRADLE_USER_HOME=$PWD/.gradle-cache

command -v wget >/dev/null 2>&1 || error "wget not found. Please install wget"

# Java Check (Hanya memverifikasi, tidak lagi mengunduh secara otomatis)
if ! check_and_find_java; then
    if [ -z "${CI:-}" ]; then
        warn "Java 17 not found"
        read -p "Would you like to download OpenJDK 17 to ./jvm? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            download_java
            if ! command -v java >/dev/null 2>&1; then
                error "Java installation failed"
            fi
        else
            error "Java 17 is required"
        fi
    else
        error "Java 17 not found. GitHub Actions setup-java step failed."
    fi
fi

# Pengecekan Tools Android dan ADB (Di CI, akan dilewati jika sudah disiapkan)
if [ -z "${CI:-}" ]; then
    if ! command -v adb >/dev/null 2>&1; then
        warn "adb not found. './make.sh test' will not work"
    fi
    if [ -z "${ANDROID_HOME:-}" ] && ! command -v sdkmanager >/dev/null 2>&1; then
        error "Android Command Line Tools not found. Please set ANDROID_HOME or install sdkmanager."
    fi
fi

if [ $# -eq 0 ]; then
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ${BLUE}$0 keygen${NC}        - Generate signing key"
    echo -e "  ${BLUE}$0 build${NC} [config]  - Apply configuration and build Release APK"
    echo -e "  ${BLUE}$0 debug${NC} [config]  - Apply configuration and build Debug APK"
    echo -e "  ${BLUE}$0 test${NC}          - Install and test APK via adb, show logs"
    echo -e "  ${BLUE}$0 clean${NC}         - Clean build files, reset settings"
    echo 
    echo -e "  ${BLUE}$0 apk${NC}           - Build Release APK without apply_config"
    echo -e "  ${BLUE}$0 apply_config${NC}  - Apply settings from config file"
    echo -e "  ${BLUE}$0 download_java${NC} - Download OpenJDK 17 locally"
    echo -e "  ${BLUE}$0 regradle${NC}      - Reinstall gradle."
    exit 1
fi

# Jalankan perintah yang diberikan
eval "$@"

#!/bin/sh

set -e  # Exit on any error
set -u  # Treat unset variables as an error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
    exit 1
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
    fi
}

# Configuration
REPO_URL="https://raw.githubusercontent.com/soloviev6310/waytix/main"
TEMP_DIR="/tmp/waytix_install"
INSTALL_DIR="/usr/lib/lua/luci"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/var/log/waytix_install.log"

# Create log file
exec > >(tee -a "$LOG_FILE") 2>&1

log "Starting Waytix installation"
log "Working directory: $(pwd)"
log "Script directory: $SCRIPT_DIR"

# Create temporary directory
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR" || exit 1

echo "Starting installation in $TEMP_DIR"

# Function to download file from repository
download_file() {
    local src="$1"
    local dst="${2:-$(basename "$src")}"
    local dir
    dir=$(dirname "$dst")
    
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || error "Failed to create directory: $dir"
    fi
    
    log "Downloading $REPO_URL/$src to $dst"
    
    # Try wget first, fall back to curl if wget fails
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q "$REPO_URL/$src" -O "$dst"; then
            warn "wget failed, trying curl..."
            if ! curl -s -L "$REPO_URL/$src" -o "$dst"; then
                error "Failed to download $src using both wget and curl"
            fi
        fi
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -s -L "$REPO_URL/$src" -o "$dst"; then
            error "Failed to download $src using curl"
        fi
    else
        error "Neither wget nor curl is available. Please install one of them and try again."
    fi
    
    # Verify file was downloaded and has content
    if [ ! -s "$dst" ]; then
        error "Downloaded file is empty: $dst"
    fi
    
    return 0
}

# Function to download directory from repository (simplified for compatibility)
download_dir() {
    local dir="$1"
    log "Downloading directory $dir"
    
    # Create a list of files to download (simplified approach)
    # This is a hardcoded list of files to download
    local files=""
    files="$files luasrc/controller/waytix.lua"
    files="$files luasrc/model/cbi/waytix/waytix.lua"
    files="$files luasrc/view/waytix/control.htm"
    files="$files luasrc/view/waytix/status.htm"
    files="$files root/etc/waytix/connect.sh"
    files="$files root/etc/waytix/status.sh"
    files="$files root/etc/waytix/update.sh"
    files="$files root/etc/init.d/waytix"
    files="$files root/usr/sbin/waytixd"
    files="$files root/etc/config/waytix"
    files="$files root/usr/share/rpcd/acl.d/luci-app-waytix.json"
    files="$files root/usr/libexec/rpcd/waytix"
    files="$files root/etc/crontabs/root"
    
    # Process each file
    for file in $files; do
        # Skip empty entries
        [ -z "$file" ] && continue
        
        # Create directory if it doesn't exist
        local dir_path="$(dirname "$file")"
        if [ ! -d "$dir_path" ]; then
            mkdir -p "$dir_path" 2>/dev/null || {
                warn "Failed to create directory: $dir_path"
                continue
            }
        fi
        
        # Download the file
        download_file "$file" "$file"
    done
}

# Create directory structure
mkdir -p "luci-app-waytix/luasrc/controller"
mkdir -p "luci-app-waytix/luasrc/model/cbi/waytix"
mkdir -p "luci-app-waytix/luasrc/view/waytix"
mkdir -p "luci-app-waytix/root/etc/waytix"
mkdir -p "luci-app-waytix/root/etc/init.d"
mkdir -p "luci-app-waytix/root/usr/sbin"
mkdir -p "luci-app-waytix/root/usr/share/rpcd/acl.d"
mkdir -p "luci-app-waytix/root/usr/libexec/rpcd"
mkdir -p "luci-app-waytix/root/etc/crontabs"
mkdir -p "luci-app-waytix/root/etc/xray"
mkdir -p "luci-app-waytix/root/etc/config"

# Download controller files
echo "Downloading controller files..."
download_file "luci-app-waytix/luasrc/controller/waytix.lua" "luci-app-waytix/luasrc/controller/waytix.lua"

# Download model files
echo "Downloading model files..."
download_file "luci-app-waytix/luasrc/model/cbi/waytix/waytix.lua" "luci-app-waytix/luasrc/model/cbi/waytix/waytix.lua"

# Download view files
echo "Downloading view files..."
download_file "luci-app-waytix/luasrc/view/waytix/control.htm" "luci-app-waytix/luasrc/view/waytix/control.htm"
download_file "luci-app-waytix/luasrc/view/waytix/status.htm" "luci-app-waytix/luasrc/view/waytix/status.htm"

# Download system files
echo "Downloading system files..."
download_file "luci-app-waytix/root/etc/waytix/connect.sh" "luci-app-waytix/root/etc/waytix/connect.sh"
download_file "luci-app-waytix/root/etc/waytix/status.sh" "luci-app-waytix/root/etc/waytix/status.sh"
download_file "luci-app-waytix/root/etc/waytix/update.sh" "luci-app-waytix/root/etc/waytix/update.sh"

# Download init script
download_file "luci-app-waytix/root/etc/init.d/waytix" "luci-app-waytix/root/etc/init.d/waytix"

# Download daemon
download_file "luci-app-waytix/root/usr/sbin/waytixd" "luci-app-waytix/root/usr/sbin/waytixd"

# Download config files
download_file "luci-app-waytix/root/etc/config/waytix" "luci-app-waytix/root/etc/config/waytix"
download_file "luci-app-waytix/root/etc/xray/config.json" "luci-app-waytix/root/etc/xray/config.json"

# Download ACL file
download_file "luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json" "luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json"

# Download RPCD script
download_file "luci-app-waytix/root/usr/libexec/rpcd/waytix" "luci-app-waytix/root/usr/libexec/rpcd/waytix"

# Download crontab
download_file "luci-app-waytix/root/etc/crontabs/root" "luci-app-waytix/root/etc/crontabs/root"

# Check if all files were downloaded successfully
if [ ! -f "luci-app-waytix/luasrc/controller/waytix.lua" ] || \
   [ ! -f "luci-app-waytix/luasrc/model/cbi/waytix/waytix.lua" ] || \
   [ ! -f "luci-app-waytix/root/etc/init.d/waytix" ] || \
   [ ! -f "luci-app-waytix/root/usr/sbin/waytixd" ]; then
    echo "Error: Failed to download required files"
    exit 1
fi

# Function to fix UCI configuration
fix_uci_config() {
    echo "Fixing UCI configuration..."
    
    # Download the fix script
    if ! wget -q "$REPO_URL/fix_uci_config.sh" -O "/tmp/fix_uci_config.sh"; then
        echo "Warning: Failed to download UCI fix script"
        return 1
    fi
    
    # Make it executable
    chmod +x "/tmp/fix_uci_config.sh"
    
    # Run the fix script
    if "/tmp/fix_uci_config.sh"; then
        echo "UCI configuration fixed successfully"
        return 0
    else
        echo "Error: Failed to fix UCI configuration"
        return 1
        uci commit waytix
    fi
}

# Function to fix pgrep usage
fix_pgrep_usage() {
    echo "Fixing pgrep usage in scripts..."
    
    # Fix pgrep in init script
    if [ -f "luci-app-waytix/root/etc/init.d/waytix" ]; then
        sed -i 's/pgrep -F /pgrep -f "/' "luci-app-waytix/root/etc/init.d/waytix"
        sed -i 's/\$\([0-9]\+\)\([^0-9]\)/\1"\2/g' "luci-app-waytix/root/etc/init.d/waytix"
    fi
    
    # Fix pgrep in other scripts if needed
    for script in luci-app-waytix/root/etc/waytix/*.sh; do
        if [ -f "$script" ]; then
            sed -i 's/pgrep -F /pgrep -f "/' "$script"
            sed -i 's/\$\([0-9]\+\)\([^0-9]\)/\1"\2/g' "$script"
        fi
    done
}

# Fix known issues
fix_uci_config

# Create necessary directories
log "Creating directories..."
for dir in "$INSTALL_DIR/controller" \
           "$INSTALL_DIR/model/cbi/waytix" \
           "$INSTALL_DIR/view/waytix" \
           "/etc/waytix" \
           "$INIT_DIR"; do
    mkdir -p "$dir" || error "Failed to create directory: $dir"
done

# Download and install files
log "Downloading files from repository..."
for file in "luasrc/controller/waytix.lua" \
            "luasrc/model/cbi/waytix/" \
            "luasrc/view/waytix/" \
            "root/etc/init.d/waytix" \
            "root/etc/config/waytix" \
            "root/usr/bin/waytix-*"; do
    url="$REPO_URL/$file"
    dest="${file#root}"
    
    # Handle wildcards
    if [ -n "$(echo "$file" | grep '\*')" ]; then
        for f in $file; do
            filename=$(basename "$f")
            wget -q -P "$TEMP_DIR" "$REPO_URL/$f" || error "Failed to download $f"
            install -m 755 "$TEMP_DIR/$filename" "$BIN_DIR/" || error "Failed to install $filename"
        done
    else
        wget -q -P "$TEMP_DIR" "$url" || error "Failed to download $file"
        
        # Handle directories
        if [ "${file%${file#?}}" = "/" ]; then
            mkdir -p "$INSTALL_DIR/$dest"
            cp -r "$TEMP_DIR/$(basename "$file")" "$INSTALL_DIR/$dest"
        else
            install -m 644 "$TEMP_DIR/$(basename "$file")" "/$dest" || \
                error "Failed to install $file to /$dest"
        fi
    fi
done

# Copy daemon
cp -v "luci-app-waytix/root/usr/sbin/waytixd" "/usr/sbin/"
chmod +x "/usr/sbin/waytixd"

# Copy config files
[ -f "luci-app-waytix/root/etc/config/waytix" ] && cp -v "luci-app-waytix/root/etc/config/waytix" "/etc/config/"
[ -f "luci-app-waytix/root/etc/xray/config.json" ] && cp -v "luci-app-waytix/root/etc/xray/config.json" "/etc/xray/"

# Copy ACL file
cp -v "luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json" "/usr/share/rpcd/acl.d/"

# Copy RPCD script
cp -v "luci-app-waytix/root/usr/libexec/rpcd/waytix" "/usr/libexec/rpcd/"
chmod +x "/usr/libexec/rpcd/waytix"

# Copy crontab
[ -f "luci-app-waytix/root/etc/crontabs/root" ] && cp -v "luci-app-waytix/root/etc/crontabs/root" "/etc/crontabs/"

# Set permissions
echo "Setting permissions..."
chmod 755 "/usr/sbin/waytixd"
chmod 755 "/etc/init.d/waytix"
chmod 755 "/usr/libexec/rpcd/waytix"
chmod 644 "/etc/config/waytix" 2>/dev/null || true
chmod 644 "/etc/xray/config.json" 2>/dev/null || true

# Enable and start service
echo "Enabling and starting service..."
/etc/init.d/waytix enable

# Check if service is already running
if ! /etc/init.d/waytix running; then
    /etc/init.d/waytix start
else
    /etc/init.d/waytix restart
fi

# Clean up
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

echo ""
echo "========================================"
echo "Waytix VPN installation completed!"
echo "Please refresh your browser to see the changes in LuCI."
echo ""
echo "If you encounter any issues, please check the logs:"
echo "- Logs: /var/log/waytix.log"
echo "- Service status: /etc/init.d/waytix status"
echo "========================================"
echo ""

# Проверяем, что скрипт запущен от root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен от имени root"
    exit 1
fi

# Обновляем список пакетов
opkg update

# Устанавливаем необходимые зависимости
for pkg in curl jq luci-compat luci-mod-admin-full luci-lib-ipkg luci-lib-nixio; do
    if ! opkg list-installed | grep -q "^$pkg"; then
        echo "Устанавливаем $pkg..."
        opkg install $pkg || {
            echo "Ошибка при установке $pkg"
            exit 1
        }
    fi
done

# Create temporary directory
log "Creating temporary directory: $TEMP_DIR"
mkdir -p "$TEMP_DIR" || error "Failed to create temporary directory"

# Cleanup function
cleanup() {
    log "Cleaning up temporary files"
    rm -rf "$TEMP_DIR"
    log "Cleanup complete"
}

# Register cleanup on exit
trap cleanup EXIT

# Скачиваем Xray
XRAY_VERSION="1.8.4"
XRAY_ARCH=""

# Определяем архитектуру
case "$(uname -m)" in
    "x86_64") XRAY_ARCH="64" ;;
    "i386" | "i686") XRAY_ARCH="32" ;;
    "aarch64" | "armv8" | "arm64") XRAY_ARCH="arm64-v8a" ;;
    "armv7" | "armv7l") XRAY_ARCH="arm32-v7a" ;;
    "mips") XRAY_ARCH="mips32" ;;
    "mips64") XRAY_ARCH="mips64" ;;
    *) echo "Неподдерживаемая архитектура: $(uname -m)"; exit 1 ;;
esac

XRAY_PKG="Xray-linux-${XRAY_ARCH}.zip"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_PKG}"

echo "Скачиваем Xray..."
if ! curl -L "$XRAY_URL" -o "$TMP_DIR/xray.zip"; then
    echo "Ошибка при скачивании Xray"
    exit 1
fi

# Устанавливаем Xray
echo "Устанавливаем Xray..."
unzip -o "$TMP_DIR/xray.zip" -d "$TMP_DIR/xray"
install -m 755 "$TMP_DIR/xray/xray" /usr/bin/
install -d /etc/xray
install -m 644 "$TMP_DIR/xray/*.json" /etc/xray/ 2>/dev/null || true

# Install luci-app-waytix
log "Installing luci-app-waytix..."

# Ensure INSTALL_DIR exists
mkdir -p "$INSTALL_DIR" || error "Failed to create installation directory"

# Выводим отладочную информацию
echo "Working directory: $(pwd)"
echo "Repository root: $SCRIPT_DIR"

# Проверяем существование исходных директорий
for dir in \
    "luci-app-waytix/luasrc/controller" \
    "luci-app-waytix/luasrc/model/cbi/waytix" \
    "luci-app-waytix/luasrc/view/waytix" \
    "luci-app-waytix/root/etc/waytix" \
    "luci-app-waytix/root/etc/init.d" \
    "luci-app-waytix/root/usr/sbin" \
    "luci-app-waytix/root/usr/share/rpcd/acl.d" \
    "luci-app-waytix/root/usr/libexec/rpcd" \
    "luci-app-waytix/root/etc/crontabs"; do
    if [ ! -d "$dir" ]; then
        echo "Error: Directory $dir not found"
        exit 1
    fi
done

# Создаем целевые директории
mkdir -p "${INSTALL_DIR}/controller"
mkdir -p "${INSTALL_DIR}/model/cbi/waytix"
mkdir -p "${INSTALL_DIR}/view/waytix"

# Копируем файлы контроллера
echo "Копируем контроллер..."
cp -v "${SCRIPT_DIR}/luci-app-waytix/luasrc/controller/waytix.lua" "${INSTALL_DIR}/controller/"

# Копируем модель
echo "Копируем модель..."
cp -v "${SCRIPT_DIR}/luci-app-waytix/luasrc/model/cbi/waytix/waytix.lua" "${INSTALL_DIR}/model/cbi/waytix/"

# Копируем шаблоны
echo "Копируем шаблоны..."
for file in "${SCRIPT_DIR}/luci-app-waytix/luasrc/view/waytix/"*.htm; do
    cp -v "$file" "${INSTALL_DIR}/view/waytix/"
done

# Устанавливаем системные файлы
echo "Устанавливаем системные файлы..."
mkdir -p /etc/waytix
for file in "${SCRIPT_DIR}/luci-app-waytix/root/etc/waytix/"*.sh; do
    cp -v "$file" /etc/waytix/
    chmod +x "/etc/waytix/$(basename "$file")"
done

# Устанавливаем конфигурацию Xray
echo "Устанавливаем конфигурацию Xray..."
mkdir -p /etc/xray
cp -v "${SCRIPT_DIR}/luci-app-waytix/root/etc/xray/config.json" /etc/xray/

# Устанавливаем init скрипт
echo "Устанавливаем init скрипт..."
cp -v "${SCRIPT_DIR}/luci-app-waytix/root/etc/init.d/waytix" /etc/init.d/
chmod +x /etc/init.d/waytix

# Устанавливаем демона
echo "Устанавливаем демона..."
mkdir -p /usr/sbin
cp -v "${SCRIPT_DIR}/luci-app-waytix/root/usr/sbin/waytixd" /usr/sbin/
chmod +x /usr/sbin/waytixd

# Устанавливаем конфигурацию
echo "Устанавливаем конфигурацию..."
mkdir -p /etc/config
cp -v "${SCRIPT_DIR}/luci-app-waytix/root/etc/config/waytix" /etc/config/

# Добавляем права доступа
echo "Настраиваем права доступа..."
mkdir -p /usr/share/rpcd/acl.d
cp -v "${SCRIPT_DIR}/luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json" /usr/share/rpcd/acl.d/

# Устанавливаем RPCD скрипт
echo "Устанавливаем RPCD скрипт..."
mkdir -p /usr/libexec/rpcd
cp -v "${SCRIPT_DIR}/luci-app-waytix/root/usr/libexec/rpcd/waytix" /usr/libexec/rpcd/
chmod +x /usr/libexec/rpcd/waytix

# Устанавливаем крон-задачу
echo "Настраиваем крон-задачу..."
cp -v "${SCRIPT_DIR}/luci-app-waytix/root/etc/crontabs/root" /etc/crontabs/

# Включаем и запускаем сервис
if [ -f "/etc/init.d/waytix" ]; then
    /etc/init.d/waytix enable
    /etc/init.d/waytix start
fi

# Очищаем временные файлы
rm -rf "$TMP_DIR"

echo ""
echo "========================================"
echo "Установка завершена успешно!"
echo "Откройте веб-интерфейс LuCI и перейдите в раздел:"
echo "Сервисы -> Шарманка 3000"
echo "========================================"
echo ""

log "Installation completed successfully"
log "Please open LuCI web interface and navigate to: Services -> Waytix VPN"
log "Installation log saved to: $LOG_FILE"

echo -e "\n${GREEN}========================================"
echo "Waytix VPN has been installed successfully!"
echo "Please refresh your browser to see the changes in LuCI."
echo ""
echo "If you encounter any issues, please check the logs:"
echo "- Installation log: $LOG_FILE"
echo "- Service logs: /var/log/waytix.log"
echo "- Service status: /etc/init.d/waytix status"
echo "========================================${NC}\n"

exit 0

#!/bin/sh
# Fix UCI configuration issues
# This script is automatically called from install.sh

set -e

BACKUP_FILE="/etc/config/waytix.backup.$(date +%s)"
TEMP_FILE="/tmp/waytix.config.$$"
UCI_TEMP="/tmp/uci.$$"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to clean up temp files
cleanup() {
    rm -f "$TEMP_FILE" "$UCI_TEMP"
}

# Set up trap to clean up temp files on exit
trap cleanup EXIT

# Create backup of current config
log "Creating backup of current configuration to $BACKUP_FILE"
cp /etc/config/waytix "$BACKUP_FILE"

# Create clean config
log "Generating new configuration..."
cat > "$TEMP_FILE" << 'EOF'
# Основные настройки Waytix
config waytix 'config'
    # Ссылка на подписку vless
    option sub_link ''
    
    # Выбранный сервер (ID из секции server)
    option selected_server ''
    
    # Автозапуск при загрузке (1 - включен, 0 - выключен)
    option auto_start '1'
    
    # Режим отладки (1 - включен, 0 - выключен)
    option debug '0'

# Правила маршрутизации
config routing 'rules'
    # Перенаправлять DNS-запросы через VPN (1 - включить, 0 - выключить)
    option dns_through_vpn '1'
    
    # Обход локальных сетей (1 - включить, 0 - выключить)
    option bypass_private '1'
    
    # Обход кириллических доменов (1 - включить, 0 - выключить)
    option bypass_cyrillic '1'

# Настройки Xray
config xray 'settings'
    # Уровень логирования (debug, info, warning, error, none)
    option loglevel 'warning'
    
    # Порт для API (если нужно)
    option api_port '10085'
    
    # Включить статистику (1 - включить, 0 - выключить)
    option enable_stats '1'

# Настройки DNS
config dns 'settings'
    # DNS-серверы (через запятую)
    option servers '1.1.1.1, 8.8.8.8, 1.0.0.1, 8.8.4.4'
    
    # Включить DNS через TCP (1 - включить, 0 - выключить)
    option tcp_dns '1'

# Настройки мониторинга
config monitoring 'status'
    # Включить мониторинг трафика (1 - включить, 0 - выключить)
    option enable_traffic '1'
    
    # Интервал обновления статистики (в секундах)
    option update_interval '10'
    
    # Сохранять историю трафика (1 - включить, 0 - выключить)
    option save_history '1'
EOF

# Function to safely get config value
get_config_value() {
    local file=$1
    local section=$2
    local option=$3
    
    awk -v section="$section" -v option="$option" '
    $0 ~ "^[[:space:]]*config[[:space:]]+[^[:space:]]+[[:space:]]+\"?" section "\"?" {
        in_section = 1
        next
    }
    in_section && $1 == "option" && $2 == option {
        gsub(/^[^\"]*\"|"[^\"]*$/, "")
        print $0
        exit
    }
    ' "$BACKUP_FILE"
}

# Function to get server sections
get_server_sections() {
    awk '
    $0 ~ "^[[:space:]]*config[[:space:]]+server[[:space:]]+\"?[^\"]*\"?" {
        in_server = 1
        print "config server"
        next
    }
    in_server && /^[[:space:]]*option/ {
        print "    " $0
    }
    in_server && /^[[:space:]]*$/ {
        in_server = 0
        print ""
    }
    ' "$BACKUP_FILE"
}

# Add server sections if they exist
log "Processing server configurations..."
SERVER_SECTIONS=$(get_server_sections)
if [ -n "$SERVER_SECTIONS" ]; then
    echo "" >> "$TEMP_FILE"
    echo "# Секции серверов (добавляются автоматически при загрузке подписки)" >> "$TEMP_FILE"
    echo "$SERVER_SECTIONS" >> "$TEMP_FILE"
fi

# Save the generated config for debugging
DEBUG_FILE="/tmp/waytix.debug.$$"
cp "$TEMP_FILE" "$DEBUG_FILE"
log "Generated config saved to $DEBUG_FILE"

# Debug: Show file permissions and content
log "Debug: File info - $(ls -la "$TEMP_FILE")"
log "Debug: First 20 lines of generated config:"
head -n 20 "$TEMP_FILE" | while read -r line; do
    log "  $line"
done

# Create a temporary directory for UCI config
UCI_TEMP_DIR="/tmp/uci_temp_$$"
mkdir -p "$UCI_TEMP_DIR"
cp "$TEMP_FILE" "$UCI_TEMP_DIR/waytix"

# Validate the new config
log "Validating new configuration in $UCI_TEMP_DIR..."
VALIDATE_OUTPUT=$(cd "$UCI_TEMP_DIR" && uci -c "$UCI_TEMP_DIR" validate 2>&1)
VALIDATE_EXIT_CODE=$?

# Save validation output for debugging
log "Validation output:"
echo "$VALIDATE_OUTPUT" | while read -r line; do
    log "  $line"
done

# Show the full config if validation fails
if [ $VALIDATE_EXIT_CODE -ne 0 ]; then
    log "Full config for debugging:"
    cat "$TEMP_FILE" | while read -r line; do
        log "  $line"
    done
fi

if [ $VALIDATE_EXIT_CODE -eq 0 ]; then
    log "Configuration is valid, applying changes..."
    mv "$TEMP_FILE" /etc/config/waytix
    uci commit waytix || {
        log "Error: Failed to commit UCI changes"
        exit 1
    }
    log "Configuration updated successfully"
    
    # Restart the service to apply changes
    if [ -x "/etc/init.d/waytix" ]; then
        log "Restarting waytix service..."
        /etc/init.d/waytix restart || {
            log "Warning: Failed to restart waytix service"
            exit 1
        }
    fi
    
    exit 0
else
    log "Error: Generated configuration is invalid"
    log "Keeping the original configuration at $BACKUP_FILE"
    
    # Show validation error if possible
    log "Validation errors:"
    uci -c /tmp validate < "$TEMP_FILE" 2>&1 | while read -r line; do
        log "  $line"
    done
    
    exit 1
fi

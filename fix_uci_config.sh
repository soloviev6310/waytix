#!/bin/sh
# Fix UCI configuration issues
# This script is automatically called from install.sh

set -e

BACKUP_FILE="/etc/config/waytix.backup.$(date +%s)"
TEMP_FILE="/tmp/waytix.config.$$"
UCI_TEMP="/tmp/uci.$$"

# Function to log messages (compatible with BusyBox)
log() {
    # Use a simpler date format that works with BusyBox
    TIMESTAMP=$(date +'%Y-%m-%d %H:%M')
    echo "[$TIMESTAMP] $1"
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

# Create a new config file with valid UCI format
log "Generating new configuration..."
cat > "$TEMP_FILE" << 'EOF'
package waytix

config waytix 'config'
    option sub_link ''
    option selected_server ''
    option auto_start '1'
    option debug '0'

config routing 'rules'
    option dns_through_vpn '1'
    option bypass_private '1'
    option bypass_cyrillic '1'

config xray 'settings'
    option loglevel 'warning'
    option api_port '10085'
    option enable_stats '1'

config dns 'settings'
    option servers '1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4'
    option tcp_dns '1'

config monitoring 'status'
    option enable_traffic '1'
    option update_interval '10'
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

# Validate the new config using uci show
log "Validating new configuration in $UCI_TEMP_DIR..."

# First, try to show the config to check for syntax errors
VALIDATE_OUTPUT=$(cd "$UCI_TEMP_DIR" && uci -c "$UCI_TEMP_DIR" show waytix 2>&1)
VALIDATE_EXIT_CODE=$?

# Save validation output for debugging
log "Validation output (uci show):"
echo "$VALIDATE_OUTPUT" | while read -r line; do
    log "  $line"
done

# If uci show fails, try to get more detailed error
if [ $VALIDATE_EXIT_CODE -ne 0 ]; then
    log "uci show failed, trying to get more detailed error..."
    DEBUG_OUTPUT=$(cd "$UCI_TEMP_DIR" && uci -c "$UCI_TEMP_DIR" show 2>&1)
    log "Debug output (uci show without parameters):"
    echo "$DEBUG_OUTPUT" | while read -r line; do
        log "  $line"
    done
    
    # Show the full config for debugging
    log "Full config for debugging:"
    cat "$TEMP_FILE" | while read -r line; do
        log "  $line"
    done
    
    # Try to validate using uci import
    log "Trying to validate using uci import..."
    IMPORT_OUTPUT=$(cd "$UCI_TEMP_DIR" && uci -c "$UCI_TEMP_DIR" import < waytix 2>&1)
    log "Import output:"
    echo "$IMPORT_OUTPUT" | while read -r line; do
        log "  $line"
    done
    
    # If we got here, validation failed
    VALIDATE_EXIT_CODE=1
else
    # If uci show succeeded, try to validate the config
    log "uci show succeeded, checking config structure..."
    
    # Check if config has required sections
    if ! grep -q "^config " "$TEMP_FILE"; then
        log "Error: No config sections found in the generated file"
        VALIDATE_EXIT_CODE=1
    fi
    
    # Check for common UCI syntax errors
    if grep -q "^[^#].*[{}]" "$TEMP_FILE"; then
        log "Warning: Found curly braces in config, which are not standard UCI syntax"
    fi
    
    # If we got here, validation passed
    if [ $VALIDATE_EXIT_CODE -eq 0 ]; then
        log "Config structure appears to be valid"
    fi
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

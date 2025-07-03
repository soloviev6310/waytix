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

# Get list of all sections in the current config
log "Analyzing current configuration..."
uci show waytix > "$UCI_TEMP" 2>&1 || {
    log "Warning: Failed to read current UCI configuration"
    # Continue with empty config if we can't read it
    echo "" > "$UCI_TEMP"
}

# Create clean config
log "Generating new configuration..."
cat > "$TEMP_FILE" << 'EOF'
# Main configuration
config waytix 'config'
    option sub_link ''
    option selected_server ''
    option auto_start '1'
    option debug '0'

# Routing rules
config routing 'rules'
    option dns_through_vpn '1'
    option bypass_private '1'
    option bypass_cyrillic '1'

# Xray settings
config xray 'settings'
    option loglevel 'warning'
    option api_port '10085'
    option enable_stats '1'

# DNS settings
config dns 'settings'
    option servers '1.1.1.1, 8.8.8.8, 1.0.0.1, 8.8.4.4'
    option tcp_dns '1'

# Monitoring settings
config monitoring 'status'
    option enable_traffic '1'
    option update_interval '10'
    option save_history '1'
EOF

# Function to safely get UCI value
get_uci_value() {
    local section=$1
    local option=$2
    uci -q get "waytix.$section.$option" 2>/dev/null || echo ""
}

# Preserve existing server configurations
log "Processing server configurations..."
grep -E "^waytix\.@server" "$UCI_TEMP" | while read -r line; do
    section_id=$(echo "$line" | cut -d'=' -f1 | cut -d'[' -f2 | cut -d']' -f1)
    section_name=$(get_uci_value "@server[$section_id]" "name")
    section_url=$(get_uci_value "@server[$section_id]" "url")
    
    if [ -n "$section_url" ]; then
        {
            echo ""
            echo "config server"
            echo "    option name '${section_name:-Server $section_id}'"
            echo "    option url '$section_url'"
            
            # Get all options for this server
            grep -E "^waytix\.@server\[$section_id\]" "$UCI_TEMP" | \
                grep -v "\.name=" | \
                grep -v "\.url=" | \
                sed -e 's/^[^=]*=//' -e 's/^/    option /' -e 's/=/ "/' -e 's/$/"/'
        } >> "$TEMP_FILE"
    fi
done

# Validate the new config
log "Validating new configuration..."
if uci -c /tmp validate < "$TEMP_FILE" 2>/dev/null; then
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

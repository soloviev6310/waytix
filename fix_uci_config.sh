#!/bin/sh
# Fix duplicate UCI configuration sections
# This script is automatically called from install.sh

BACKUP_FILE="/etc/config/waytix.backup.$(date +%s)"
TEMP_FILE="/tmp/waytix.config.$$"

# Create backup of current config
cp /etc/config/waytix "$BACKUP_FILE"

# Create clean config
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

# Preserve existing server configurations
uci show waytix | grep -E "^waytix\.@server" | while read -r line; do
    section_id=$(echo "$line" | cut -d'=' -f1 | cut -d'[' -f2 | cut -d']' -f1)
    section_name=$(uci get "waytix.@server[$section_id].name" 2>/dev/null || echo "")
    section_url=$(uci get "waytix.@server[$section_id].url" 2>/dev/null || echo "")
    
    if [ -n "$section_url" ]; then
        echo ""
        echo "config server '$section_id'"
        uci show waytix | grep -E "^waytix\.@server\[$section_id\]" | \
            sed -e 's/^[^=]*=//' -e 's/^/    option /' -e 's/=/ "/' -e 's/$/"/'
    fi
done >> "$TEMP_FILE"

# Validate config before applying
if uci -c /tmp validate < "$TEMP_FILE" 2>/dev/null; then
    # Apply new config
    mv "$TEMP_FILE" /etc/config/waytix
    uci commit waytix
    echo "Configuration updated successfully"
    exit 0
else
    echo "Error: Invalid configuration. Restoring backup."
    mv "$BACKUP_FILE" /etc/config/waytix
    exit 1
fi

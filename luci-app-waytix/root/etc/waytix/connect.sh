#!/bin/sh

# Логирование
LOG_FILE="/var/log/waytix.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "Starting connect.sh with args: $@"

# Проверяем, запущен ли уже xray
if pidof xray >/dev/null; then
    log "Stopping existing xray process..."
    killall xray
    sleep 1
fi

# Проверяем аргументы
ACTION="$1"
if [ "$ACTION" = "stop" ]; then
    log "Stopping xray service"
    exit 0
elif [ "$ACTION" != "start" ] && [ "$ACTION" != "restart" ]; then
    log "Invalid action: $ACTION. Use 'start', 'stop' or 'restart'"
    exit 1
fi

# Получаем выбранный сервер из конфига
SERVER_ID=$(uci get waytix.config.selected_server 2>/dev/null)
if [ -z "$SERVER_ID" ]; then
    log "No server selected in config"
    exit 1
fi

# Получаем настройки сервера
SERVER_HOST=$(uci get "waytix.$SERVER_ID.host" 2>/dev/null)
SERVER_PORT=$(uci get "waytix.$SERVER_ID.port" 2>/dev/null)
SERVER_ID_UUID=$(uci get "waytix.$SERVER_ID.id" 2>/dev/null)

if [ -z "$SERVER_HOST" ] || [ -z "$SERVER_PORT" ] || [ -z "$SERVER_ID_UUID" ]; then
    log "Invalid server configuration for $SERVER_ID"
    log "Host: $SERVER_HOST, Port: $SERVER_PORT, ID: $SERVER_ID_UUID"
    exit 1
fi

# Создаем временный конфиг для xray
XRAY_CONFIG="/tmp/xray-config.json"
cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 1080,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true,
        "ip": "127.0.0.1"
      }
    },
    {
      "port": 1081,
      "listen": "0.0.0.0",
      "protocol": "http",
      "settings": {
        "timeout": 300
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER_HOST",
            "port": $SERVER_PORT,
            "users": [
              {
                "id": "$SERVER_ID_UUID",
                "encryption": "none",
                "level": 0
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$SERVER_HOST",
          "allowInsecure": false
        },
        "wsSettings": {
          "path": "/ws",
          "headers": {
            "Host": "$SERVER_HOST"
          }
        }
      },
      "tag": "proxy"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

# Создаем директорию для логов, если её нет
mkdir -p /var/log/xray

# Запускаем xray с новым конфигом
log "Starting xray with config for server: $SERVER_HOST:$SERVER_PORT"
nohup /usr/bin/xray -config "$XRAY_CONFIG" >> "$LOG_FILE" 2>&1 &

# Проверяем, запустился ли xray
sleep 1
if ! pgrep -x "xray" > /dev/null; then
    log "Failed to start xray"
    exit 1
fi

log "xray started successfully"
exit 0

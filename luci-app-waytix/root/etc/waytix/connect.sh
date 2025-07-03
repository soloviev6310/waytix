#!/bin/sh

# Проверяем, запущен ли уже xray
if pidof xray >/dev/null; then
    killall xray
    sleep 1
fi

# Получаем выбранный сервер из конфига
SERVER_ID=$(uci get waytix.config.selected_server 2>/dev/null)
[ -z "$SERVER_ID" ] && exit 1

# Получаем настройки сервера
SERVER_CONFIG=$(uci get waytix.servers.$SERVER_ID 2>/dev/null)
[ -z "$SERVER_CONFIG" ] && exit 1

# Создаем временный конфиг для xray
XRAY_CONFIG="/tmp/xray-config.json"
cat > $XRAY_CONFIG <<EOF
{
  "inbounds": [
    {
      "port": 1080,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER_CONFIG",
            "port": 443,
            "users": [
              {
                "id": "$SERVER_ID",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$SERVER_CONFIG"
        },
        "wsSettings": {
          "path": "/ws"
        }
      }
    }
  ]
}
EOF

# Запускаем xray с новым конфигом
/usr/bin/xray -config $XRAY_CONFIG >/dev/null 2>&1 &

exit 0

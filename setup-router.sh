#!/bin/sh

# Проверяем, что скрипт запущен от root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен от имени root"
    exit 1
fi

# Обновляем список пакетов и устанавливаем необходимые зависимости
echo "Обновление списка пакетов и установка зависимостей..."
opkg update
opkg install \
    luci \
    luci-compat \
    luci-lib-ipkg \
    luci-lib-nixio \
    curl \
    jq \
    unzip \
    coreutils-base64 \
    openssl-util \
    ip-full \
    iptables-mod-tproxy \
    kmod-ipt-tproxy \
    ip6tables-mod-nat \
    kmod-ipt-nat6 \
    luci-proto-ipv6 \
    luci-theme-bootstrap

# Создаем директорию для временных файлов
TMP_DIR="/tmp/waytix-setup"
mkdir -p "$TMP_DIR"

# Устанавливаем Xray
echo "Установка Xray..."
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

if ! curl -L "$XRAY_URL" -o "$TMP_DIR/xray.zip"; then
    echo "Ошибка при скачивании Xray"
    exit 1
fi

unzip -o "$TMP_DIR/xray.zip" -d "$TMP_DIR/xray"
install -m 755 "$TMP_DIR/xray/xray" /usr/bin/
install -d /etc/xray

# Создаем базовую конфигурацию Xray
cat > /etc/xray/config.json << 'EOL'
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": 1080,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": true
            },
            "tag": "socks-in"
        },
        {
            "port": 1081,
            "protocol": "http",
            "settings": {
                "timeout": 300
            },
            "tag": "http-in"
        }
    ],
    "outbounds": [
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
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "blocked"
            }
        ]
    }
}
EOL

# Создаем конфигурацию приложения
mkdir -p /etc/waytix
cat > /etc/config/waytix << 'EOL'
config waytix 'config'
    option enabled '1'
    option sub_link ''
    option selected_server ''

config servers
    option name 'example-server'
    option address 'example.com'
    option port '443'
    option security 'tls'
    option type 'ws'
    option path '/path'
    option host 'example.com'
EOL

# Устанавливаем скрипты
cat > /etc/waytix/connect.sh << 'EOL'
#!/bin/sh

. /etc/waytix/status.sh

if [ "$1" = "--daemon" ]; then
    while true; do
        connect_vpn
        sleep 60
done
else
    connect_vpn
fi
EOL

chmod +x /etc/waytix/connect.sh

# Создаем init скрипт
cat > /etc/init.d/waytix << 'EOL'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    /etc/waytix/connect.sh --daemon &
}

stop() {
    killall xray 2>/dev/null
}

restart() {
    stop
    sleep 1
    start
}
EOL

chmod +x /etc/init.d/waytix

# Включаем и запускаем сервис
/etc/init.d/waytix enable
/etc/init.d/waytix start

# Настраиваем брандмауэр
cat > /etc/firewall.waytix << 'EOL'
# Правила для Waytix
config include
    option path '/etc/firewall.waytix'

config zone
    option name 'vpn'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '1'
    option mtu_fix '1'

config forwarding
    option src 'lan'
    option dest 'vpn'
EOL

# Добавляем загрузку правил в конфиг брандмауэра
if ! grep -q '/etc/firewall.waytix' /etc/config/firewall; then
    echo "include '/etc/firewall.waytix'" >> /etc/config/firewall
fi

# Перезапускаем брандмауэр
/etc/init.d/firewall restart

echo ""
echo "========================================"
echo "Настройка роутера завершена успешно!"
echo ""
echo "Для завершения настройки:"
echo "1. Откройте веб-интерфейс по адресу http://192.168.1.1"
echo "2. Перейдите в раздел Сервисы -> Шарманка 3000"
echo "3. Введите ссылку на подписку и настройте подключение"
echo "========================================"
echo ""

# Очищаем временные файлы
rm -rf "$TMP_DIR"

exit 0

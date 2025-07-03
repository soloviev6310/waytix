#!/bin/sh

# Функция для вывода ошибок и выхода
error_exit() {
    echo "ОШИБКА: $1" >&2
    exit 1
}

# Проверяем, что скрипт запущен от root
if [ "$(id -u)" -ne 0 ]; then
    error_exit "Этот скрипт должен быть запущен от имени root"
fi

# Создаем лог-файл
LOG_FILE="/tmp/waytix-setup.log"
echo "=== Начало установки Waytix VPN ===" > "$LOG_FILE"
exec 2>>"$LOG_FILE"

# Функция для логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Начало установки..."

# Обновляем список пакетов
log "Обновление списка пакетов..."
if ! opkg update >> "$LOG_FILE" 2>&1; then
    log "Ошибка при обновлении списка пакетов"
    error_exit "Не удалось обновить список пакетов. Проверьте подключение к интернету."
fi

# Устанавливаем необходимые пакеты
log "Установка зависимостей..."
for pkg in curl jq unzip coreutils-base64 openssl-util ip-full iptables-mod-tproxy kmod-ipt-tproxy ip6tables-mod-nat kmod-ipt-nat6 luci-proto-ipv6 luci-theme-bootstrap; do
    if ! opkg list-installed | grep -q "^$pkg "; then
        log "Установка $pkg..."
        if ! opkg install "$pkg" >> "$LOG_FILE" 2>&1; then
            log "Ошибка при установке $pkg"
            error_exit "Не удалось установить пакет $pkg"
        fi
    fi
done

# Создаем директорию для временных файлов
TMP_DIR="/tmp/waytix-setup"
mkdir -p "$TMP_DIR" || error_exit "Не удалось создать временную директорию"

# Устанавливаем Xray
log "Установка Xray..."
XRAY_VERSION="1.8.4"
XRAY_ARCH=""

# Определяем архитектуру процессора
case $(uname -m) in
    "x86_64") XRAY_ARCH="64" ;;
    "i386" | "i686") XRAY_ARCH="32" ;;
    "aarch64" | "armv8" | "arm64") XRAY_ARCH="arm64-v8a" ;;
    "armv7" | "armv7l") XRAY_ARCH="arm32-v7a" ;;
    "mips") XRAY_ARCH="mips32" ;;
    "mips64") XRAY_ARCH="mips64" ;;
    *) error_exit "Неподдерживаемая архитектура: $(uname -m)" ;;
esac

# Создаем необходимые директории
mkdir -p "/usr/bin" "/etc/waytix" "/etc/xray" "$TMP_DIR/xray" || error_exit "Не удалось создать системные директории"

XRAY_VERSION="1.8.3"
XRAY_PKG="Xray-linux-${XRAY_ARCH}.zip"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_PKG}"
XRAY_TMP="$TMP_DIR/xray.zip"
XRAY_DIR="$TMP_DIR/xray"

log "Скачивание Xray для архитектуры $XRAY_ARCH..."
if ! curl -L "$XRAY_URL" -o "$XRAY_TMP"; then
    error_exit "Не удалось скачать Xray"
fi

log "Распаковка Xray..."
if ! unzip -o "$XRAY_TMP" -d "$XRAY_DIR"; then
    error_exit "Не удалось распаковать Xray"
fi

# Копируем Xray
if [ -f "$XRAY_DIR/xray" ]; then
    cp -f "$XRAY_DIR/xray" "/usr/bin/xray" || error_exit "Не удалось скопировать Xray"
    chmod +x "/usr/bin/xray" || error_exit "Не удалось установить права на Xray"
    log "Xray успешно установлен в /usr/bin/xray"
else
    error_exit "Файл Xray не найден в распакованных файлах"
fi

# Создаем базовую конфигурацию Xray
log "Создание конфигурации Xray..."
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
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOL

# Создаем конфигурацию приложения
log "Создание конфигурации приложения..."
mkdir -p /etc/waytix || error_exit "Не удалось создать директорию /etc/waytix"

cat > /etc/config/waytix << 'EOL'
config waytix 'config'
    option enabled '0'
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

# Создаем скрипты
log "Создание скриптов..."
mkdir -p /etc/waytix

cat > /etc/waytix/status.sh << 'EOL'
#!/bin/sh
. /lib/functions.sh
config_load waytix
config_get enabled config enabled
[ "$enabled" = "1" ] && echo "enabled" || echo "disabled"
EOL

cat > /etc/waytix/connect.sh << 'EOL'
#!/bin/sh
. /lib/functions.sh

connect_vpn() {
    echo "Подключение к VPN..."
    # Здесь будет логика подключения
}

if [ "$1" = "--daemon" ]; then
    while true; do
        connect_vpn
        sleep 60
    done
else
    connect_vpn
fi
EOL

chmod +x /etc/waytix/*.sh

# Создаем init скрипт
log "Создание init скрипта..."
cat > /etc/init.d/waytix << 'EOL'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    echo "Запуск Waytix VPN..."
    /etc/waytix/connect.sh --daemon &
}

stop() {
    echo "Остановка Waytix VPN..."
    killall xray 2>/dev/null
}

restart() {
    stop
    sleep 1
    start
}
EOL

chmod +x /etc/init.d/waytix

# Устанавливаем luci-app-waytix
log "Установка luci-app-waytix..."
LUCI_DIR="/usr/lib/lua/luci"
LUCI_APP_DIR="$LUCI_DIR/controller"
LUCI_MODEL_DIR="$LUCI_DIR/model/cbi/waytix"
LUCI_VIEW_DIR="$LUCI_DIR/view/waytix"
LUCI_ACL_DIR="/usr/share/rpcd/acl.d"

# Создаем необходимые директории
mkdir -p "$LUCI_APP_DIR" "$LUCI_MODEL_DIR" "$LUCI_VIEW_DIR" "$LUCI_ACL_DIR" || error_exit "Не удалось создать директории LuCI"

# Скачиваем репозиторий
REPO_URL="https://github.com/soloviev6310/waytix/archive/refs/heads/main.zip"
REPO_ZIP="$TMP_DIR/repo.zip"
REPO_DIR="$TMP_DIR/waytix-main"

log "Скачивание репозитория..."
if ! curl -L "$REPO_URL" -o "$REPO_ZIP"; then
    error_exit "Не удалось скачать репозиторий"
fi

log "Распаковка репозитория..."
if ! unzip -o "$REPO_ZIP" -d "$TMP_DIR"; then
    error_exit "Не удалось распаковать репозиторий"
fi

# Копируем файлы LuCI
log "Копирование файлов LuCI..."

# Копируем контроллер
if [ -f "$REPO_DIR/luci-app-waytix/luasrc/controller/waytix.lua" ]; then
    cp -f "$REPO_DIR/luci-app-waytix/luasrc/controller/waytix.lua" "$LUCI_APP_DIR/" || error_exit "Не удалось скопировать контроллер"
else
    error_exit "Файл контроллера не найден"
fi

# Копируем модель
if [ -f "$REPO_DIR/luci-app-waytix/luasrc/model/cbi/waytix/waytix.lua" ]; then
    mkdir -p "$LUCI_MODEL_DIR"
    cp -f "$REPO_DIR/luci-app-waytix/luasrc/model/cbi/waytix/waytix.lua" "$LUCI_MODEL_DIR/" || error_exit "Не удалось скопировать модель"
else
    error_exit "Файл модели не найден"
fi

# Копируем представления
if [ -d "$REPO_DIR/luci-app-waytix/luasrc/view/waytix" ]; then
    mkdir -p "$LUCI_VIEW_DIR"
    cp -r "$REPO_DIR/luci-app-waytix/luasrc/view/waytix/"* "$LUCI_VIEW_DIR/" || error_exit "Не удалось скопировать представления"
else
    error_exit "Директория представлений не найдена"
fi

# Копируем ACL
if [ -f "$REPO_DIR/luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json" ]; then
    mkdir -p "$LUCI_ACL_DIR"
    cp -f "$REPO_DIR/luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json" "$LUCI_ACL_DIR/" || error_exit "Не удалось скопировать ACL"
else
    error_exit "Файл ACL не найден"
fi

log "Файлы LuCI успешно скопированы"

# Перезапускаем веб-сервер
log "Перезапуск веб-сервера..."
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

# Включаем автозапуск сервиса
/etc/init.d/waytix enable

# Очищаем временные файлы
log "Очистка временных файлов..."
rm -rf "$TMP_DIR"

log ""
log "========================================"
log "Установка завершена успешно!"
log ""
log "Для завершения настройки:"
log "1. Откройте веб-интерфейс по адресу http://192.168.1.1"
log "2. Перейдите в раздел Сервисы -> Шарманка 3000"
log "3. Включите и настройте подключение"
log "========================================"
log ""

exit 0

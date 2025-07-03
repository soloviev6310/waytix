#!/bin/sh

set -e  # Exit on any error
set -x  # Debug output

# Get the directory where the script is located
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

echo "Current directory: $(pwd)"
echo "Script directory: $SCRIPT_DIR"

# Check if we're in the right directory
if [ ! -d "luci-app-waytix" ]; then
    echo "Error: luci-app-waytix directory not found in $(pwd)"
    echo "Please run this script from the repository root directory"
    exit 1
fi

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

# Создаем временную директорию
TMP_DIR="/tmp/waytix-install"
mkdir -p "$TMP_DIR"

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

# Устанавливаем luci-app-waytix
echo "Устанавливаем luci-app-waytix..."
INSTALL_DIR="/usr/lib/lua/luci"

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

exit 0

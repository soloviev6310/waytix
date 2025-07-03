#!/bin/sh

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

# Создаем директории
for dir in controller model/cbi/waytix view; do
    mkdir -p "${INSTALL_DIR}/${dir}"
done

# Копируем файлы
cp -r luci-app-waytix/luasrc/controller/* "${INSTALL_DIR}/controller/"
cp -r luci-app-waytix/luasrc/model/cbi/waytix "${INSTALL_DIR}/model/cbi/"
cp -r luci-app-waytix/luasrc/view/waytix "${INSTALL_DIR}/view/"

# Устанавливаем системные файлы
mkdir -p /etc/waytix
cp luci-app-waytix/root/etc/waytix/*.sh /etc/waytix/
chmod +x /etc/waytix/*.sh

# Устанавливаем init скрипт
cp luci-app-waytix/root/etc/init.d/waytix /etc/init.d/
chmod +x /etc/init.d/waytix

# Устанавливаем демон
mkdir -p /usr/sbin
cp luci-app-waytix/root/usr/sbin/waytixd /usr/sbin/
chmod +x /usr/sbin/waytixd

# Устанавливаем конфигурацию
if [ ! -f /etc/config/waytix ]; then
    cp luci-app-waytix/root/etc/config/waytix /etc/config/
fi

# Добавляем права доступа
mkdir -p /usr/share/rpcd/acl.d
cp luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json /usr/share/rpcd/acl.d/

# Включаем и запускаем сервис
/etc/init.d/waytix enable
/etc/init.d/waytix start

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

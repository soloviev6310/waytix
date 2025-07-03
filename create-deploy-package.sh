#!/bin/sh

# Создаем временную директорию
TMP_DIR="/tmp/waytix-deploy-$(date +%s)"
PKG_DIR="$TMP_DIR/waytix"
mkdir -p "$PKG_DIR"

# Копируем все необходимые файлы
cp luci-app-waytix/luasrc/controller/waytix.lua "$PKG_DIR/luci-app-waytix.lua"
cp luci-app-waytix/luasrc/model/cbi/waytix/waytix.lua "$PKG_DIR/waytix-cbi.lua"
cp luci-app-waytix/luasrc/view/waytix/control.htm "$PKG_DIR/waytix-view-ctrl.htm"
cp luci-app-waytix/luasrc/view/waytix/status.htm "$PKG_DIR/waytix-view-status.htm"
cp luci-app-waytix/root/etc/waytix/connect.sh "$PKG_DIR/"
cp luci-app-waytix/root/etc/waytix/update.sh "$PKG_DIR/"
cp luci-app-waytix/root/etc/waytix/status.sh "$PKG_DIR/"
cp luci-app-waytix/root/usr/sbin/waytixd "$PKG_DIR/"
cp luci-app-waytix/root/etc/init.d/waytix "$PKG_DIR/waytix.init"
cp luci-app-waytix/root/usr/share/rpcd/acl.d/luci-app-waytix.json "$PKG_DIR/"

# Создаем архив
cd "$TMP_DIR"
tar -czvf waytix-package.tar.gz waytix/*

# Копируем архив в текущую директорию
cp waytix-package.tar.gz "$OLDPWD/"

# Создаем скрипт для загрузки на сервер
cat > "$OLDPWD/upload-to-server.sh" << 'EOF'
#!/bin/sh

# Настройки сервера (замените на свои)
SERVER="user@your-server.com"
REMOTE_DIR="/var/www/waytix"
LOCAL_DIR="."

# Проверяем наличие утилиты rsync
if ! command -v rsync >/dev/null 2>&1; then
    echo "Установка rsync..."
    if [ "$(uname)" = "Linux" ]; then
        sudo apt-get update && sudo apt-get install -y rsync
    elif [ "$(uname)" = "Darwin" ]; then
        brew install rsync
    else
        echo "Установите rsync вручную"
        exit 1
    fi
fi

# Синхронизируем файлы
echo "Загружаем файлы на сервер..."
rsync -avz --progress "$LOCAL_DIR/waytix-package.tar.gz" "$SERVER:$REMOTE_DIR/"
rsync -avz --progress "$LOCAL_DIR/waytix-install" "$SERVER:$REMOTE_DIR/"

# Загружаем бинарники Xray для разных архитектур
for arch in amd64 arm arm64 mips mips64; do
    if [ -f "xray-$arch" ]; then
        rsync -avz --progress "xray-$arch" "$SERVER:$REMOTE_DIR/"
    fi
done

echo ""
echo "========================================"
echo "Файлы успешно загружены на сервер!"
echo "Для установки на устройство выполните:"
echo "wget -O - https://your-server.com/waytix/waytix-install | sh"
echo "========================================"
echo ""
EOF

chmod +x "$OLDPWD/upload-to-server.sh"

# Очищаем временные файлы
rm -rf "$TMP_DIR"

echo ""
echo "========================================"
echo "Пакет для развертывания создан:"
echo "1. waytix-package.tar.gz - архив с файлами"
echo "2. upload-to-server.sh - скрипт для загрузки на сервер"
echo ""
echo "Для загрузки на сервер выполните:"
echo "./upload-to-server.sh"
echo ""
echo "Для установки на устройство:"
echo "wget -O - https://your-server.com/waytix/waytix-install | sh"
echo "========================================"
echo ""

exit 0

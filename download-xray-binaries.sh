#!/bin/sh

# Версия Xray для загрузки
XRAY_VERSION="1.8.4"

# URL для загрузки Xray
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}"

# Создаем директорию для бинарников
mkdir -p xray-binaries
cd xray-binaries

# Функция для загрузки и переименования бинарника
download_xray() {
    local arch=$1
    local file="Xray-linux-${arch}.zip"
    local url="${BASE_URL}/${file}"
    
    echo "Загружаем Xray для ${arch}..."
    if wget -q --show-progress "$url"; then
        unzip -j "$file" "xray" -d ./
        mv xray "../xray-${arch}"
        rm -f "$file"
        echo "Готово: xray-${arch}"
    else
        echo "Ошибка при загрузке ${file}"
    fi
}

# Скачиваем бинарники для всех архитектур
download_xray "amd64"
download_xray "arm"
download_xray "arm64"
download_xray "mips"
download_xray "mips64"

# Возвращаемся в исходную директорию
cd ..

# Удаляем временную директорию
rm -rf xray-binaries

echo ""
echo "========================================"
echo "Все бинарники Xray загружены!"
echo "Теперь вы можете создать пакет для развертывания:"
echo "./create-deploy-package.sh"
echo "========================================"
echo ""

exit 0

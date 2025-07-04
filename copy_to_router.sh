#!/bin/sh
# Скрипт для копирования обновленных файлов на роутер

# Параметры подключения
ROUTER_IP="192.168.100.1"
ROUTER_USER="root"
ROOT_DIR="/Users/andrey/CascadeProjects/waytix-router"

# Функция для копирования файла на роутер
copy_file() {
    local src_file="$1"
    local dst_file="$2"
    local dst_dir="$(dirname "$dst_file")"
    
    echo "Копирование $src_file -> $ROUTER_IP:$dst_file"
    
    # Создаем каталог на роутере, если его нет
    sshpass -p 35408055 ssh -o StrictHostKeyChecking=no $ROUTER_USER@$ROUTER_IP "mkdir -p $dst_dir"
    
    # Копируем файл
    cat "$src_file" | sshpass -p 35408055 ssh -o StrictHostKeyChecking=no $ROUTER_USER@$ROUTER_IP "cat > '$dst_file'"
    
    # Устанавливаем права на выполнение, если это скрипт
    if [[ "$src_file" == *.sh || "$src_file" == *"waytixd" ]]; then
        sshpass -p 35408055 ssh -o StrictHostKeyChecking=no $ROUTER_USER@$ROUTER_IP "chmod +x '$dst_file'"
    fi
}

# Основные файлы для копирования
FILES=(
    "luci-app-waytix/root/etc/waytix/connect.sh:/etc/waytix/connect.sh"
    "luci-app-waytix/root/etc/waytix/update.sh:/etc/waytix/update.sh"
    "luci-app-waytix/root/etc/waytix/status.sh:/etc/waytix/status.sh"
    "luci-app-waytix/root/usr/sbin/waytixd:/usr/sbin/waytixd"
    "luci-app-waytix/root/etc/init.d/waytix:/etc/init.d/waytix"
)

# Копируем файлы
for file_pair in "${FILES[@]}"; do
    src="${file_pair%%:*}"
    dst="${file_pair#*:}"
    copy_file "$ROOT_DIR/$src" "$dst"
done

echo "\nГотово! Все файлы успешно скопированы на роутер."
echo "Для применения изменений выполните на роутере:"
echo "1. /etc/init.d/waytix restart"
echo "2. /etc/init.d/waytix enable"

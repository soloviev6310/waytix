#!/bin/sh

# Пути к файлам на роутере
CONTROLLER_PATH="/usr/lib/lua/luci/controller/waytix.lua"
TEMPLATES_DIR="/www/luci-static/resources/view/waytix"
CONFIG_PATH="/etc/config/waytix"
BACKUP_DIR="/tmp/waytix_backup_$(date +%s)"

# Функция для создания бэкапа
backup() {
    echo "Создание бэкапа текущих файлов..."
    mkdir -p "$BACKUP_DIR"
    
    # Копируем файлы, если они существуют
    [ -f "$CONTROLLER_PATH" ] && cp "$CONTROLLER_PATH" "$BACKUP_DIR/"
    [ -d "$TEMPLATES_DIR" ] && cp -r "$TEMPLATES_DIR" "$BACKUP_DIR/"
    [ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "$BACKUP_DIR/"
    
    # Сохраняем список установленных пакетов
    opkg list-installed | grep -E 'lua-sec|luasocket' > "$BACKUP_DIR/packages.list"
    
    echo "Бэкап создан в $BACKUP_DIR"
}

# Функция для восстановления из бэкапа
restore() {
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Ошибка: директория бэкапа не найдена"
        exit 1
    fi
    
    echo "Восстановление файлов из бэкапа..."
    
    # Восстанавливаем файлы, если они есть в бэкапе
    [ -f "$BACKUP_DIR/waytix.lua" ] && cp "$BACKUP_DIR/waytix.lua" "$CONTROLLER_PATH"
    [ -d "$BACKUP_DIR/waytix" ] && cp -r "$BACKUP_DIR/waytix" "$(dirname "$TEMPLATES_DIR")/"
    [ -f "$BACKUP_DIR/waytix" ] && cp "$BACKUP_DIR/waytix" "$CONFIG_PATH"
    
    # Восстанавливаем пакеты
    if [ -f "$BACKUP_DIR/packages.list" ]; then
        echo "Установка зависимостей..."
        opkg update
        cat "$BACKUP_DIR/packages.list" | xargs opkg install
    fi
    
    # Устанавливаем правильные права
    [ -f "$CONTROLLER_PATH" ] && chmod 644 "$CONTROLLER_PATH"
    [ -d "$TEMPLATES_DIR" ] && chmod -R 755 "$TEMPLATES_DIR"
    [ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH"
    
    # Перезапускаем сервисы
    /etc/init.d/rpcd restart
    /etc/init.d/uhttpd restart
    
    echo "Восстановление завершено"
}

# Проверяем аргументы командной строки
case "$1" in
    backup)
        backup
        ;;
    restore)
        restore
        ;;
    *)
        echo "Использование: $0 {backup|restore}"
        exit 1
        ;;
esac

exit 0

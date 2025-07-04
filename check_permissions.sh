#!/bin/sh
# Скрипт для проверки и установки прав доступа на файлы Waytix

# Параметры подключения
ROUTER_IP="192.168.100.1"
ROUTER_USER="root"
PASSWORD="35408055"

# Функция для проверки прав доступа
check_permissions() {
    local file="$1"
    local expected_perm="$2"
    
    echo "Проверка прав доступа для $file..."
    
    # Получаем текущие права доступа
    local current_perm=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$ROUTER_USER@$ROUTER_IP" "ls -l $file | awk '{print \$1}'" 2>/dev/null)
    
    if [ -z "$current_perm" ]; then
        echo "  Ошибка: файл $file не найден на роутере"
        return 1
    fi
    
    echo "  Текущие права: $current_perm"
    
    # Проверяем, соответствуют ли права ожидаемым
    if [ "$current_perm" != "$expected_perm" ]; then
        echo "  Внимание: права доступа не соответствуют ожидаемым (ожидается: $expected_perm)"
        return 1
    else
        echo "  Права доступа в порядке"
        return 0
    fi
}

# Функция для установки прав доступа
set_permissions() {
    local file="$1"
    local perm="$2"
    
    echo "Установка прав $perm для $file..."
    
    # Устанавливаем права доступа
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$ROUTER_USER@$ROUTER_IP" "chmod $perm \"$file\""
    
    # Проверяем результат
    if [ $? -eq 0 ]; then
        echo "  Права успешно установлены"
        return 0
    else
        echo "  Ошибка при установке прав"
        return 1
    fi
}

# Основные файлы и их ожидаемые права доступа
declare -A FILES=(
    ["/etc/waytix/connect.sh"]="-rwxr-xr-x"
    ["/etc/waytix/update.sh"]="-rwxr-xr-x"
    ["/etc/waytix/status.sh"]="-rwxr-xr-x"
    ["/usr/sbin/waytixd"]="-rwxr-xr-x"
    ["/etc/init.d/waytix"]="-rwxr-xr--"
    ["/etc/config/waytix"]="-rw-r--r--"
)

# Проверяем и устанавливаем права доступа
for file in "${!FILES[@]}"; do
    expected_perm="${FILES[$file]}"
    
    # Проверяем текущие права
    if ! check_permissions "$file" "$expected_perm"; then
        # Если права не соответствуют, предлагаем их исправить
        read -p "  Исправить права доступа для $file? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Преобразуем символьное представление прав в числовое
            perm_num=0
            perm_str=$(echo "$expected_perm" | sed 's/^.//')
            
            # Вычисляем числовое представление прав
            for ((i=0; i<9; i++)); do
                char="${perm_str:$i:1}"
                if [ "$char" != "-" ]; then
                    case $((i % 3)) in
                        0) perm_num=$((perm_num + 4)) ;; # r
                        1) perm_num=$((perm_num + 2)) ;; # w
                        2) perm_num=$((perm_num + 1)) ;; # x
                    esac
                fi
                
                if [ $(((i+1) % 3)) -eq 0 ]; then
                    perm_num_str="${perm_num_str}${perm_num}"
                    perm_num=0
                fi
            done
            
            # Устанавливаем права
            set_permissions "$file" "$perm_num_str"
        fi
    fi
done

echo "\nПроверка завершена."

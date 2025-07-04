#!/bin/sh

# Получаем ссылку на подписку
SUBSCRIPTION_URL=$(uci get waytix.config.sub_link 2>/dev/null)
[ -z "$SUBSCRIPTION_URL" ] && { echo "Не указана ссылка на подписку"; exit 1; }

# Скачиваем подписку
TEMP_FILE=$(mktemp)
if ! wget -qO- "$SUBSCRIPTION_URL" | base64 -d > "$TEMP_FILE" 2>/dev/null; then
    echo "Ошибка при загрузке подписки"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Очищаем старые серверы
for section in $(uci show waytix | grep -o "waytix.@server\[[0-9]\+\]"); do
    uci delete "$section"
done

# Парсим vless-ссылки
SERVER_COUNT=0
while IFS= read -r line; do
    if echo "$line" | grep -q '^vless://'; then
        # Извлекаем данные из vless-ссылки
        DATA=$(echo "$line" | cut -d'@' -f2- | cut -d'#' -f1)
        SERVER=$(echo "$DATA" | cut -d':' -f1)
        PORT=$(echo "$DATA" | cut -d':' -f2 | cut -d'?' -f1)
        ID=$(echo "$line" | cut -d'@' -f1 | cut -d':' -f4)
        
        # Извлекаем имя сервера из комментария (часть после #)
        NAME=$(echo "$line" | grep -o '#.*$' | cut -d'#' -f2- | tr -d '\r')
        
        # Если имя не указано в комментарии, используем sni или host
        if [ -z "$NAME" ]; then
            # Пробуем извлечь имя из параметров URL
            SNI=$(echo "$line" | grep -o 'sni=[^&]*' | cut -d'=' -f2)
            HOST=$(echo "$line" | grep -o 'host=[^&]*' | cut -d'=' -f2)
            
            if [ -n "$SNI" ]; then
                NAME="$SNI"
            elif [ -n "$HOST" ]; then
                NAME="$HOST"
            else
                NAME="$SERVER"
            fi
        fi
        
        # Декодируем URL-кодированные символы в имени
        NAME=$(printf '%b' "${NAME//%/\\x}" 2>/dev/null || echo "$NAME")
        
        # Удаляем лишние пробелы и переносы строк
        NAME=$(echo "$NAME" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Если имя пустое, используем общее имя
        [ -z "$NAME" ] && NAME="Сервер $((SERVER_COUNT + 1))"
        
        # Добавляем сервер в конфиг
        uci add waytix server
        uci set "waytix.@server[-1].name=$NAME"
        uci set "waytix.@server[-1].host=$SERVER"
        uci set "waytix.@server[-1].port=$PORT"
        uci set "waytix.@server[-1].id=$ID"
        uci set "waytix.@server[-1].url=$line"
        
        # Выводим отладочную информацию
        echo "Добавлен сервер: $NAME ($SERVER:$PORT)"
        
        SERVER_COUNT=$((SERVER_COUNT + 1))
    fi
done < "$TEMP_FILE"

# Сохраняем изменения
if [ $SERVER_COUNT -gt 0 ]; then
    uci commit waytix
    echo "Успешно загружено серверов: $SERVER_COUNT"
else
    echo "Не удалось найти серверы в подписке"
    rm -f "$TEMP_FILE"
    exit 1
fi

rm -f "$TEMP_FILE"
exit 0

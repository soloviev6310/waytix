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
uci delete waytix.servers 2>/dev/null
uci add waytix servers

# Парсим vless-ссылки
SERVER_COUNT=0
while IFS= read -r line; do
    if echo "$line" | grep -q '^vless://'; then
        # Извлекаем данные из vless-ссылки
        DATA=$(echo "$line" | cut -d'@' -f2- | cut -d'#' -f1)
        SERVER=$(echo "$DATA" | cut -d':' -f1)
        PORT=$(echo "$DATA" | cut -d':' -f2 | cut -d'?' -f1)
        ID=$(echo "$line" | cut -d'@' -f1 | cut -d':' -f4)
        
        # Извлекаем имя сервера (если есть)
        NAME=$(echo "$line" | grep -o '#.*$' | cut -d'#' -f2-)
        [ -z "$NAME" ] && NAME="Сервер $((SERVER_COUNT + 1))"
        
        # Добавляем сервер в конфиг
        SERVER_ID="server_$(printf "%03d" $SERVER_COUNT)"
        uci set "waytix.$SERVER_ID=server"
        uci set "waytix.$SERVER_ID.name=$NAME"
        uci set "waytix.$SERVER_ID.host=$SERVER"
        uci set "waytix.$SERVER_ID.port=$PORT"
        uci set "waytix.$SERVER_ID.id=$ID"
        
        # Добавляем сервер в список
        uci add_list waytix.servers.servers="$SERVER_ID"
        
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

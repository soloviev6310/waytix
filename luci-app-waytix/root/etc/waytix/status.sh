#!/bin/sh

# Проверяем, запущен ли xray
if ! pidof xray >/dev/null; then
    echo "DOWN:0 B"
    echo "UP:0 B"
    exit 0
fi

# Получаем PID xray
XRAY_PID=$(pidof xray)

# Получаем статистику сети
STATS_FILE="/proc/$XRAY_PID/net/dev"
if [ -f "$STATS_FILE" ]; then
    # Ищем интерфейс tun0 или аналогичный
    IFACE=$(ip -o link show | grep -E 'tun[0-9]+' | awk '{print $2}' | cut -d: -f1 | head -n1)
    
    if [ -n "$IFACE" ]; then
        # Получаем статистику по интерфейсу
        STATS=$(grep "$IFACE" "$STATS_FILE" 2>/dev/null)
        if [ -n "$STATS" ]; then
            # Форматируем вывод
            DOWN=$(echo "$STATS" | awk '{print $2}' | awk '{
                if ($1 > 1024*1024*1024) {
                    printf "%.2f GB", $1/1024/1024/1024
                } else if ($1 > 1024*1024) {
                    printf "%.2f MB", $1/1024/1024
                } else if ($1 > 1024) {
                    printf "%.2f KB", $1/1024
                } else {
                    printf "%d B", $1
                }
            }')
            
            UP=$(echo "$STATS" | awk '{print $10}' | awk '{
                if ($1 > 1024*1024*1024) {
                    printf "%.2f GB", $1/1024/1024/1024
                } else if ($1 > 1024*1024) {
                    printf "%.2f MB", $1/1024/1024
                } else if ($1 > 1024) {
                    printf "%.2f KB", $1/1024
                } else {
                    printf "%d B", $1
                }
            }')
            
            echo "DOWN:$DOWN"
            echo "UP:$UP"
            exit 0
        fi
    fi
fi

# Если не удалось получить статистику, возвращаем нули
echo "DOWN:0 B"
echo "UP:0 B"

exit 0

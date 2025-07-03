#!/bin/sh

# Создаем временную директорию
TMP_DIR="/tmp/waytix-package"
PKG_DIR="$TMP_DIR/waytix-vpn"

# Очищаем предыдущую сборку
rm -rf "$TMP_DIR"
mkdir -p "$PKG_DIR"

# Копируем все необходимые файлы
cp -r luci-app-waytix "$PKG_DIR/"
cp install-waytix.sh "$PKG_DIR/"

# Создаем README
cat > "$PKG_DIR/README.md" << 'EOF'
# Waytix VPN для OpenWrt

Установщик пакета Waytix VPN для OpenWrt, включающий:

- Xray клиент
- Web-интерфейс управления
- Скрипты автоматического подключения

## Установка

1. Загрузите пакет на устройство с OpenWrt
2. Установите права на выполнение:
   ```bash
   chmod +x install-waytix.sh
   ```
3. Запустите установщик от root:
   ```bash
   ./install-waytix.sh
   ```
4. Откройте веб-интерфейс LuCI и перейдите в раздел:
   `Сервисы -> Шарманка 3000`

## Требования

- OpenWrt 21.02 или новее
- Минимум 16 МБ свободного места
- Доступ в интернет для загрузки зависимостей

## Поддерживаемые архитектуры

- x86_64
- ARM (armv7, aarch64)
- MIPS (mips, mips64)
- Другие архитектуры с поддержкой Xray

## Лицензия

GPL-3.0

## Разработчик

Waytix Team <support@waytix.org>
EOF

# Создаем архив
cd "$TMP_DIR"
tar -czvf "waytix-vpn-$(date +%Y%m%d).tar.gz" waytix-vpn/

# Копируем архив в текущую директорию
cp "waytix-vpn-$(date +%Y%m%d).tar.gz" "$OLDPWD/"

# Очищаем временные файлы
rm -rf "$TMP_DIR"

echo ""
echo "========================================"
echo "Пакет успешно создан: waytix-vpn-$(date +%Y%m%d).tar.gz"
echo "Для установки выполните:"
echo "1. Распакуйте архив на устройстве с OpenWrt"
echo "2. Запустите: ./install-waytix.sh"
echo "========================================"
echo ""

exit 0

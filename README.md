# Waytix VPN для OpenWrt

Полностью автоматизированное решение для развертывания VPN-клиента на устройствах с OpenWrt.

## Установка на устройство с OpenWrt

1. Подключитесь к устройству по SSH
2. Выполните команду для установки:

```bash
opkg update
opkg install wget unzip
wget -O /tmp/waytix.zip https://github.com/soloviev6310/waytix/archive/refs/heads/main.zip
unzip /tmp/waytix.zip -d /tmp/
cd /tmp/waytix-main
chmod +x install.sh
./install.sh
```

Или одной командой:

```bash
opkg update && opkg install wget unzip && wget -O /tmp/waytix.zip https://github.com/soloviev6310/waytix/archive/refs/heads/main.zip && unzip /tmp/waytix.zip -d /tmp/ && cd /tmp/waytix-main && chmod +x install.sh && ./install.sh
```

## Разработка и сборка

Для разработки и сборки пакетов:

1. Клонируйте репозиторий:
   ```bash
   git clone https://github.com/soloviev6310/waytix.git
   cd waytix
   ```

2. Скачайте бинарники Xray для всех архитектур:
   ```bash
   chmod +x download-xray-binaries.sh
   ./download-xray-binaries.sh
   ```

3. Соберите пакеты:
   ```bash
   chmod +x build-packages.sh
   ./build-packages.sh
   ```

## Обновление

Для обновления выполните те же команды, что и при установке.

## Структура проекта

- `luci-app-waytix/` - Исходный код LuCI-приложения
- `xray/` - Исходный код Xray (для сборки из исходников)
- `waytix-install` - Установочный скрипт
- `create-deploy-package.sh` - Скрипт для создания пакета развертывания
- `download-xray-binaries.sh` - Скрипт для загрузки бинарников Xray
- `upload-to-server.sh` - Скрипт для загрузки файлов на сервер (генерируется автоматически)

## Настройка веб-сервера

Убедитесь, что веб-сервер правильно настроен для раздачи файлов:

1. Разрешите доступ к файлам в конфигурации веб-сервера
2. Настройте MIME-типы для .sh и бинарных файлов
3. Убедитесь, что файлы доступны по HTTPS

## Безопасность

- Все загрузки должны производиться по HTTPS
- Ограничьте доступ к каталогу с бинарниками
- Регулярно обновляйте пакеты

## Лицензия

GPL-3.0

## Поддержка

По вопросам поддержки обращайтесь: support@waytix.org

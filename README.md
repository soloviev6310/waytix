# Waytix VPN для OpenWrt

Полностью автоматизированное решение для развертывания VPN-клиента на устройствах с OpenWrt.

## Первоначальная настройка роутера

1. Подключитесь к роутеру по SSH
2. Выполните команды для настройки с нуля:

```bash
# Установка необходимых пакетов
opkg update
opkg install wget unzip

# Скачивание и запуск скрипта настройки
wget -O /tmp/setup-router.sh https://raw.githubusercontent.com/soloviev6310/waytix/main/setup-router.sh
chmod +x /tmp/setup-router.sh
/tmp/setup-router.sh
```

Или одной командой:

```bash
opkg update && opkg install wget unzip && wget -O /tmp/setup-router.sh https://raw.githubusercontent.com/soloviev6310/waytix/main/setup-router.sh && chmod +x /tmp/setup-router.sh && /tmp/setup-router.sh
```

После выполнения скрипта:
1. Откройте веб-интерфейс по адресу http://192.168.1.1
2. Перейдите в раздел "Сервисы" -> "Шарманка 3000"
3. Введите ссылку на подписку и настройте подключение

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

## Миграция настроек

При обновлении с GitHub могут быть перезаписаны настройки, внесенные вручную. Для сохранения настроек используйте скрипт миграции:

### Перед обновлением:
1. Создайте бэкап текущих настроек:
   ```bash
   wget -O /tmp/migrate.sh https://raw.githubusercontent.com/soloviev6310/waytix/main/migrate.sh
   chmod +x /tmp/migrate.sh
   /tmp/migrate.sh backup
   ```

2. Выполните обновление системы

3. Восстановите настройки:
   ```bash
   /tmp/migrate.sh restore
   ```

### Что сохраняется в бэкап:
- Контроллер LuCI (`/usr/lib/lua/luci/controller/waytix.lua`)
- Шаблоны веб-интерфейса (`/www/luci-static/resources/view/waytix/`)
- Конфигурация (`/etc/config/waytix`)
- Установленные зависимости (lua-sec, luasocket)

Бэкап сохраняется в `/tmp/waytix_backup_<timestamp>`

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

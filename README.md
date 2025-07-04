# Waytix VPN для OpenWrt

Полностью автоматизированное решение для развертывания VPN-клиента на устройствах с OpenWrt.

## ВАЖНО: СИНХРОНИЗАЦИЯ ИЗМЕНЕНИЙ

Перед любыми изменениями в репозитории ОБЯЗАТЕЛЬНО выполните следующие шаги:

1. Синхронизируйте текущие изменения с роутера:
   ```bash
   # Контроллер
   sshpass -p 35408055 ssh root@192.168.100.1 "cat /usr/lib/lua/luci/controller/waytix.lua" > luci-app-waytix/luasrc/controller/waytix.lua
   
   # Шаблоны
   mkdir -p luci-app-waytix/htdocs/luci-static/resources/view/waytix
   sshpass -p 35408055 ssh root@192.168.100.1 "cat /www/luci-static/resources/view/waytix/control.htm" > luci-app-waytix/htdocs/luci-static/resources/view/waytix/control.htm
   sshpass -p 35408055 ssh root@192.168.100.1 "cat /www/luci-static/resources/view/waytix/status.htm" > luci-app-waytix/htdocs/luci-static/resources/view/waytix/status.htm
   
   # Конфигурация
   sshpass -p 35408055 ssh root@192.168.100.1 "uci export waytix" > luci-app-waytix/root/etc/config/waytix
   
   # Системные скрипты
   sshpass -p 35408055 ssh root@192.168.100.1 "cat /etc/waytix/connect.sh" > luci-app-waytix/root/etc/waytix/connect.sh
   sshpass -p 35408055 ssh root@192.168.100.1 "cat /etc/waytix/status.sh" > luci-app-waytix/root/etc/waytix/status.sh
   sshpass -p 35408055 ssh root@192.168.100.1 "cat /etc/waytix/update.sh" > luci-app-waytix/root/etc/waytix/update.sh
   
   # Коммит изменений
   git add .
   git commit -m "Синхронизация с текущей версией с роутера"
   ```

2. Убедитесь, что все изменения закоммичены перед продолжением работы.

3. Только после этого приступайте к внесению изменений в код.

Пропуск этого шага может привести к потере важных изменений и неработоспособности системы!

## Зависимости Lua

Для работы LuCI-интерфейса "Шарманка 3000" необходимы следующие пакеты Lua:

```bash
opkg update
opkg install lua lua-cjson luasocket luci-lib-nixio luci-lua-runtime luci-lib-ip luci-lib-jsonc luci-compat luci-theme-bootstrap luasec
```

Полный список зависимостей можно найти в файле `requirements.txt`.

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

## Структура конфигурации

Конфигурация приложения хранится в файле `/etc/config/waytix` и имеет следующую структуру:

```
config waytix 'config'
    option sub_link ''           # Ссылка на подписку
    option selected_server ''    # ID выбранного сервера
    option auto_start '1'        # Автозапуск при загрузке
    option debug '0'             # Режим отладки

config routing 'rules'           # Настройки маршрутизации
    option dns_through_vpn '1'   # Перенаправлять DNS через VPN
    option bypass_private '1'    # Обходить приватные сети
    option bypass_cyrillic '1'   # Обходить кириллические домены

config xray 'settings'           # Настройки Xray
    option loglevel 'warning'    # Уровень логирования
    option api_port '10085'      # Порт API Xray
    option enable_stats '1'      # Включить статистику

config dns_settings 'dns'        # Настройки DNS
    option servers '1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4'  # DNS-серверы
    option tcp_dns '1'           # Использовать TCP для DNS

config monitoring_status 'monitoring'  # Настройки мониторинга
    option enable_traffic '1'    # Включить мониторинг трафика
    option update_interval '10'  # Интервал обновления (сек)
    option save_history '1'      # Сохранять историю

# Секции серверов (добавляются автоматически)
config server
    option name 'Сервер 1'       # Название сервера
    option host 'example.com'    # Адрес сервера
    option port '443'            # Порт сервера
    option id 'uuid-here'        # UUID пользователя
```

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

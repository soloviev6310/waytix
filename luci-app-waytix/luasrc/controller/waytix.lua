module("luci.controller.waytix", package.seeall)

-- Инициализация глобальных переменных
local http, sys, uci, json, nixio, util, nixio_fs, nixio_proc
local XRAY_BIN = "/usr/bin/xray"
local XRAY_CONFIG = "/etc/xray/config.json"
local LOG_FILE = "/var/log/waytix.log"
local PID_FILE = "/var/run/waytix.pid"
local UCI_CONFIG = "waytix"

-- Ленивая загрузка модулей
local function require_modules()
    if not http then http = require "luci.http" end
    if not sys then sys = require "luci.sys" end
    if not uci then uci = require "luci.model.uci".cursor() end
    if not json then json = require "luci.jsonc" end
    if not nixio then 
        nixio = require "nixio" 
        nixio_fs = nixio.fs
        nixio_proc = nixio.proc
    end
    if not util then util = require "luci.util" end
end

-- Регистрация страниц и API-эндпоинтов
function index()
    require_modules()
    
    -- Главная страница
    entry({"admin", "services", "waytix"}, 
         template("waytix/control"), 
         _("Шарманка 3000"), 60).dependent = true
    
    -- API-эндпоинты
    local api = {
        {"status",    "action_status"},
        {"toggle",    "action_toggle"},
        {"update",    "action_update"},
        {"servers",   "action_servers"},
        {"savesub",   "action_savesub"},
        {"select",    "action_select"},
        {"traffic",   "action_traffic"},
        {"settings",  "action_settings"},
        {"logs",      "action_logs"},
        {"restart",   "action_restart"},
        {"test",      "action_test_connection"}
    }
    
    for _, endpoint in ipairs(api) do
        entry({"admin", "services", "waytix", endpoint[1]}, 
             call("action_" .. endpoint[2]:gsub("^action_", ""))).leaf = true
    end
    
    -- Статические страницы
    entry({"admin", "services", "waytix", "help"}, 
         template("waytix/help"), 
         _("Помощь"), 70)
end

-- Вспомогательные функции
local function json_response(data, status)
    require_modules()
    http.prepare_content("application/json")
    http.write_json(data or {})
    return status or 200
end

local function log_message(level, message)
    local log_levels = {error = 1, warn = 2, info = 3, debug = 4}
    local current_level = uci:get(UCI_CONFIG, "config", "log_level") or "info"
    
    if log_levels[level] <= (log_levels[current_level:lower()] or 2) then
        local log_entry = string.format("[%s] [%s] %s\n", 
            os.date("%Y-%m-%d %H:%M:%S"), 
            level:upper(), 
            tostring(message)
        )
        
        -- Записываем в системный лог
        nixio.syslog(level, "waytix: " .. tostring(message))
        
        -- Дополнительно пишем в файл лога
        local log_fd = nixio.open(LOG_FILE, "a+")
        if log_fd then
            log_fd:write(log_entry)
            log_fd:close()
        end
    end
end

local function exec(cmd, timeout)
    require_modules()
    
    local output = {}
    local exit_code = 0
    local timer = nixio.timer()
    local max_time = timeout or 30 -- 30 секунд по умолчанию
    
    local function read_output(fd)
        local chunk = fd:read(2048, 10)
        if chunk and #chunk > 0 then
            table.insert(output, chunk)
            return true
        end
        return false
    end
    
    local function handle_timeout()
        timer:set(max_time * 1000, function()
            log_message("warn", string.format("Таймаут выполнения команды: %s", cmd))
            return false -- останавливаем таймер
        end)
    end
    
    log_message("debug", "Выполнение команды: " .. cmd)
    
    local pid = nixio_proc.exec(cmd, "sh", "-c", cmd)
    if not pid then
        local err = "Не удалось выполнить команду: " .. tostring(pid)
        log_message("error", err)
        return nil, err
    end
    
    local fd = nixio.pipe()
    if not fd then
        return nil, "Не удалось создать канал для чтения вывода"
    end
    
    -- Настраиваем неблокирующее чтение
    fd:nonblock(true)
    
    -- Запускаем таймер
    handle_timeout()
    
    -- Ожидаем завершения процесса или таймаута
    local running = true
    while running do
        local _, status = nixio_proc.wait(pid, "nohang")
        
        if status == "exited" or status == "signaled" then
            exit_code = nixio_proc.wexitstatus(status)
            running = false
        end
        
        -- Читаем вывод, если есть
        while read_output(fd) do end
        
        -- Не нагружаем процессор
        nixio.nanosleep(0.1)
    end
    
    -- Читаем оставшийся вывод
    while read_output(fd) do end
    
    -- Закрываем файловые дескрипторы
    fd:close()
    
    -- Останавливаем таймер, если он еще работает
    if timer:status() == "pending" then
        timer:stop()
    end
    
    local result = table.concat(output)
    log_message("debug", string.format("Команда завершена с кодом %d: %s", exit_code, result))
    
    if exit_code ~= 0 then
        return nil, string.format("Код ошибки %d: %s", exit_code, result)
    end
    
    return result
end

local function is_xray_running()
    local pid = nixio.fs.readfile(PID_FILE)
    if pid and #pid > 0 then
        pid = pid:match("%d+")
        if pid and nixio.fs.access("/proc/" .. pid) then
            return true, tonumber(pid)
        end
    end
    return false
end

local function get_xray_stats()
    local stats = {
        uptime = 0,
        upload = 0,
        download = 0,
        connections = 0
    }
    
    -- Получаем статистику из Xray API, если включено
    if uci:get(UCI_CONFIG, "xray", "enable_stats") == "1" then
        local api_port = uci:get(UCI_CONFIG, "xray", "api_port") or "10085"
        local cmd = string.format(
            "curl -s http://127.0.0.1:%s/stats -d '\
            {\"name\": \"inbound>>>proxy>>>traffic>>>downlink\", \"reset\": false}, \
            {\"name\": \"inbound>>>proxy>>>traffic>>>uplink\", \"reset\": false}, \
            {\"name\": \"inbound>>>proxy>>>traffic>>>connection\", \"reset\": false}'",
            api_port
        )
        
        local result, err = exec(cmd)
        if result then
            local ok, data = pcall(json.parse, result)
            if ok and type(data) == "table" then
                for _, stat in ipairs(data) do
                    if stat.name == "inbound>>>proxy>>>traffic>>>downlink" then
                        stats.download = tonumber(stat.value) or 0
                    elseif stat.name == "inbound>>>proxy>>>traffic>>>uplink" then
                        stats.upload = tonumber(stat.value) or 0
                    elseif stat.name == "inbound>>>proxy>>>traffic>>>connection" then
                        stats.connections = tonumber(stat.value) or 0
                    end
                end
            end
        end
    end
    
    -- Получаем время работы процесса
    local is_running, pid = is_xray_running()
    if is_running then
        local uptime_cmd = string.format("ps -o etimes= -p %d 2>/dev/null", pid)
        local uptime = exec(uptime_cmd)
        stats.uptime = tonumber(uptime) or 0
    end
    
    return stats
end

-- Получение статуса сервиса
function action_status()
    require_modules()
    
    local is_running, pid = is_xray_running()
    local stats = get_xray_stats()
    
    local status = {
        success = true,
        running = is_running,
        server = uci:get(UCI_CONFIG, "config", "selected_server") or "Не подключено",
        uptime = stats.uptime,
        upload = stats.upload,
        download = stats.download,
        connections = stats.connections,
        version = "1.0.0"
    }
    
    return json_response(status)
end

-- Переключение состояния сервиса (вкл/выкл)
function action_toggle()
    require_modules()
    
    local is_running, pid = is_xray_running()
    local result = { success = true }
    
    if is_running then
        -- Останавливаем сервис
        local ok, err = exec("/etc/init.d/waytix stop")
        if not ok then
            log_message("error", "Ошибка при остановке сервиса: " .. tostring(err))
            return json_response({ success = false, error = "Ошибка при остановке: " .. tostring(err) }, 500)
        end
        result.message = "Сервис успешно остановлен"
    else
        -- Запускаем сервис
        local ok, err = exec("/etc/init.d/waytix start")
        if not ok then
            log_message("error", "Ошибка при запуске сервиса: " .. tostring(err))
            return json_response({ success = false, error = "Ошибка при запуске: " .. tostring(err) }, 500)
        end
        result.message = "Сервис успешно запущен"
    end
    
    -- Обновляем статус
    result.running = not is_running
    return json_response(result)
end

-- Обновление списка серверов из подписки
function action_update()
    require_modules()
    
    local sub_link = uci:get(UCI_CONFIG, "config", "sub_link")
    if not sub_link or sub_link == "" then
        return json_response({ success = false, error = "Не задана ссылка на подписку" }, 400)
    end
    
    -- Скачиваем подписку
    local cmd = string.format("curl -s '%s' | base64 -d 2>/dev/null || curl -s '%s'", sub_link, sub_link)
    local subscription, err = exec(cmd, 60) -- Таймаут 60 секунд
    
    if not subscription then
        log_message("error", "Ошибка при загрузке подписки: " .. tostring(err))
        return json_response({ success = false, error = "Ошибка при загрузке подписки: " .. tostring(err) }, 500)
    end
    
    -- Парсим серверы из подписки
    local servers = {}
    for server in subscription:gmatch("vless://([^\r\n]+)") do
        table.insert(servers, "vless://" .. server)
    end
    
    if #servers == 0 then
        log_message("error", "Не удалось найти серверы в подписке")
        return json_response({ success = false, error = "Не удалось найти серверы в подписке" }, 400)
    end
    
    -- Сохраняем серверы в конфиг
    uci:delete(UCI_CONFIG, "@servers")
    
    for i, server_url in ipairs(servers) do
        local id = "server" .. i
        uci:set(UCI_CONFIG, id, "server")
        uci:set(UCI_CONFIG, id, "url", server_url)
        
        -- Парсим URL для извлечения дополнительных параметров
        local parsed = parse_vless_url(server_url)
        if parsed then
            uci:set(UCI_CONFIG, id, "name", parsed.name or ("Сервер " .. i))
            uci:set(UCI_CONFIG, id, "address", parsed.address or "")
            uci:set(UCI_CONFIG, id, "port", tostring(parsed.port or 443))
            uci:set(UCI_CONFIG, id, "user_id", parsed.user_id or "")
            uci:set(UCI_CONFIG, id, "flow", parsed.flow or "")
            uci:set(UCI_CONFIG, id, "encryption", parsed.encryption or "none")
            uci:set(UCI_CONFIG, id, "security", parsed.security or "tls")
            uci:set(UCI_CONFIG, id, "fingerprint", parsed.fingerprint or "chrome")
            uci:set(UCI_CONFIG, id, "public_key", parsed.public_key or "")
            uci:set(UCI_CONFIG, id, "short_id", parsed.short_id or "")
            uci:set(UCI_CONFIG, id, "spider_y", parsed.spider_y or "0")
        end
    end
    
    -- Сохраняем изменения
    uci:commit(UCI_CONFIG)
    
    log_message("info", string.format("Обновлен список серверов: %d серверов загружено", #servers))
    return json_response({ 
        success = true, 
        count = #servers,
        message = string.format("Загружено %d серверов", #servers)
    })
end

-- Парсинг URL VLESS
local function parse_vless_url(url)
    if not url or type(url) ~= "string" then
        return nil
    end
    
    -- Формат: vless://[user@]host:port?param1=value1&param2=value2#name
    local pattern = "^vless://([^@]+)@([^:]+):(\d+)\??([^#]*)#?([^\s]*)"
    local user, host, port, params, name = url:match(pattern)
    
    if not user or not host or not port then
        return nil
    end
    
    -- Разбираем параметры
    local result = {
        name = name ~= "" and name or nil,
        address = host,
        port = tonumber(port),
        user_id = user,
        security = "tls",
        encryption = "none",
        flow = "xtls-rprx-vision",
        fingerprint = "chrome",
        public_key = "",
        short_id = "",
        spider_y = "0"
    }
    
    -- Обрабатываем параметры запроса
    for key, value in params:gmatch("([^&=]+)=([^&]*)") do
        key = key:lower()
        if key == "security" then
            result.security = value
        elseif key == "type" then
            result.type = value
        elseif key == "flow" then
            result.flow = value
        elseif key == "encryption" then
            result.encryption = value
        elseif key == "fp" or key == "fingerprint" then
            result.fingerprint = value
        elseif key == "pbk" or key == "publickey" then
            result.public_key = value
        elseif key == "sid" or key == "shortid" then
            result.short_id = value
        elseif key == "spidery" then
            result.spider_y = value
        end
    end
    
    return result
end

-- Получение списка серверов
function action_servers()
    require_modules()
    
    local servers = {}
    uci:foreach(UCI_CONFIG, "server", 
        function(section)
            if section[".name"] and section.url then
                table.insert(servers, {
                    id = section[".name"],
                    name = section.name or section[".name"],
                    url = section.url,
                    address = section.address or "",
                    port = tonumber(section.port) or 443,
                    selected = (section[".name"] == uci:get(UCI_CONFIG, "config", "selected_server"))
                })
            end
        end
    )
    
    return json_response({ success = true, servers = servers })
end


-- Выбор сервера
function action_select()
    require_modules()
    
    local http = luci.http
    local server_id = http.formvalue("server_id")
    
    if not server_id or server_id == "" then
        return json_response({ success = false, error = "Не указан ID сервера" }, 400)
    end
    
    -- Проверяем существование сервера
    local server_url = uci:get(UCI_CONFIG, server_id, "url")
    if not server_url then
        return json_response({ success = false, error = "Указанный сервер не найден" }, 404)
    end
    
    -- Обновляем выбранный сервер
    uci:set(UCI_CONFIG, "config", UCI_CONFIG)
    uci:set(UCI_CONFIG, "config", "selected_server", server_id)
    uci:commit(UCI_CONFIG)
    
    log_message("info", "Выбран сервер: " .. server_id)
    
    -- Перезапускаем сервис, если он запущен
    local is_running = is_xray_running()
    if is_running then
        os.execute("/etc/init.d/waytix restart >/dev/null 2>&1 &")
    end
    
    return json_response({ 
        success = true, 
        message = "Сервер выбран",
        restart_required = is_running
    })
end



-- Тестирование соединения
function action_test_connection()
    require_modules()
    
    local test_url = uci:get(UCI_CONFIG, "config", "test_url") or "https://www.google.com"
    local timeout = tonumber(uci:get(UCI_CONFIG, "config", "test_timeout")) or 10
    
    local cmd = string.format("curl -s -o /dev/null -w '%%{http_code}' --connect-timeout %d --max-time %d '%s'", 
        timeout, timeout, test_url)
    
    local result, err = exec(cmd, timeout + 2)
    
    if not result then
        return json_response({
            success = false,
            error = "Ошибка тестирования соединения: " .. tostring(err)
        }, 500)
    end
    
    local status_code = tonumber(result) or 0
    local success = status_code >= 200 and status_code < 400
    
    return json_response({
        success = success,
        status_code = status_code,
        message = success and "Соединение установлено" or "Ошибка соединения"
    })
end

-- Перезапуск сервиса
function action_restart()
    require_modules()
    
    local ok, err = exec("/etc/init.d/waytix restart")
    if not ok then
        log_message("error", "Ошибка при перезапуске сервиса: " .. tostring(err))
        return json_response({ 
            success = false, 
            error = "Ошибка при перезапуске: " .. tostring(err) 
        }, 500)
    end
    
    log_message("info", "Сервис успешно перезапущен")
    return json_response({ 
        success = true, 
        message = "Сервис перезапущен"
    })
end

-- Получение логов
function action_logs()
    require_modules()
    
    local lines = tonumber(luci.http.formvalue("lines") or "100")
    local log_file = LOG_FILE
    
    -- Если файл лога не существует, возвращаем пустой результат
    if not nixio.fs.access(log_file) then
        return json_response({
            success = true,
            logs = "",
            truncated = false
        })
    end
    
    -- Читаем логи с конца файла
    local cmd = string.format("tail -n %d '%s' 2>/dev/null || cat '%s' 2>/dev/null", 
        lines, log_file, log_file)
    
    local logs = exec(cmd) or ""
    
    -- Проверяем, были ли логи обрезаны
    local line_count = select(2, logs:gsub("\n", "\n")) + 1
    local truncated = line_count >= lines
    
    return json_response({
        success = true,
        logs = logs,
        truncated = truncated
    })
end

-- Получение и сохранение настроек
function action_settings()
    require_modules()
    
    local http = luci.http
    local method = http.getenv("REQUEST_METHOD"):upper()
    
    if method == "GET" then
        -- Возвращаем текущие настройки
        local settings = {
            auto_start = uci:get(UCI_CONFIG, "config", "auto_start") or "1",
            log_level = uci:get(UCI_CONFIG, "config", "log_level") or "info",
            test_url = uci:get(UCI_CONFIG, "config", "test_url") or "https://www.google.com",
            test_timeout = tonumber(uci:get(UCI_CONFIG, "config", "test_timeout")) or 10,
            update_interval = tonumber(uci:get(UCI_CONFIG, "monitoring", "update_interval")) or 10,
            enable_traffic = uci:get(UCI_CONFIG, "monitoring", "enable_traffic") or "1",
            save_history = uci:get(UCI_CONFIG, "monitoring", "save_history") or "1",
            dns_through_vpn = uci:get(UCI_CONFIG, "routing", "dns_through_vpn") or "1",
            bypass_private = uci:get(UCI_CONFIG, "routing", "bypass_private") or "1",
            bypass_cyrillic = uci:get(UCI_CONFIG, "routing", "bypass_cyrillic") or "1"
        }
        
        return json_response({
            success = true,
            settings = settings
        })
    elseif method == "POST" then
        -- Сохраняем настройки
        local settings = {
            auto_start = http.formvalue("auto_start") or "1",
            log_level = http.formvalue("log_level") or "info",
            test_url = http.formvalue("test_url") or "https://www.google.com",
            test_timeout = tonumber(http.formvalue("test_timeout")) or 10,
            update_interval = tonumber(http.formvalue("update_interval")) or 10,
            enable_traffic = http.formvalue("enable_traffic") or "1",
            save_history = http.formvalue("save_history") or "1",
            dns_through_vpn = http.formvalue("dns_through_vpn") or "1",
            bypass_private = http.formvalue("bypass_private") or "1",
            bypass_cyrillic = http.formvalue("bypass_cyrillic") or "1"
        }
        
        -- Сохраняем настройки в UCI
        uci:set(UCI_CONFIG, "config", UCI_CONFIG)
        uci:set(UCI_CONFIG, "config", "auto_start", settings.auto_start)
        uci:set(UCI_CONFIG, "config", "log_level", settings.log_level)
        uci:set(UCI_CONFIG, "config", "test_url", settings.test_url)
        uci:set(UCI_CONFIG, "config", "test_timeout", tostring(settings.test_timeout))
        
        uci:set(UCI_CONFIG, "monitoring", "monitoring", "settings")
        uci:set(UCI_CONFIG, "monitoring", "update_interval", tostring(settings.update_interval))
        uci:set(UCI_CONFIG, "monitoring", "enable_traffic", settings.enable_traffic)
        uci:set(UCI_CONFIG, "monitoring", "save_history", settings.save_history)
        
        uci:set(UCI_CONFIG, "routing", "routing", "rules")
        uci:set(UCI_CONFIG, "routing", "dns_through_vpn", settings.dns_through_vpn)
        uci:set(UCI_CONFIG, "routing", "bypass_private", settings.bypass_private)
        uci:set(UCI_CONFIG, "routing", "bypass_cyrillic", settings.bypass_cyrillic)
        
        uci:commit(UCI_CONFIG)
        
        log_message("info", "Настройки успешно обновлены")
        return json_response({
            success = true,
            message = "Настройки сохранены"
        })
    else
        return json_response({
            success = false,
            error = "Метод не поддерживается"
        }, 405)
    end
end

function action_select()
    local server = http.formvalue("server")
    if not server or server == "" then
        return json_response({ success = false, error = "Не выбран сервер" }, 400)
    end
    
    -- Сохраняем выбранный сервер
    uci:set("waytix", "config", "selected_server", server)
    uci:commit("waytix")
    
    -- Перезапускаем сервис
    os.execute("/etc/init.d/waytix restart")
    
    json_response({ 
        success = true,
        message = "Сервер успешно выбран"
    })
end

function action_traffic()
    local stats = { up = 0, down = 0 }
    
    -- Получаем статистику из iptables
    local cmd = "iptables -nvx -L XRAY_OUT 2>/dev/null | grep '^[ ]*[0-9]' | awk '{print $2}' | head -1"
    local out = io.popen(cmd)
    if out then
        stats.down = tonumber(out:read("*a") or 0) or 0
        out:close()
    end
    
    cmd = "iptables -nvx -L XRAY_IN 2>/dev/null | grep '^[ ]*[0-9]' | awk '{print $2}' | head -1"
    out = io.popen(cmd)
    if out then
        stats.up = tonumber(out:read("*a") or 0) or 0
        out:close()
    end
    
    -- Добавляем человекочитаемый формат
    local function format_bytes(bytes)
        local units = {"B", "KB", "MB", "GB", "TB"}
        local i = 1
        while bytes > 1024 and i < #units do
            bytes = bytes / 1024
            i = i + 1
        end
        return string.format("%.2f %s", bytes, units[i])
    end
    
    stats.formatted = {
        up = format_bytes(stats.up),
        down = format_bytes(stats.down)
    }
    
    json_response(stats)
end

function action_update()
    local sub_link = uci:get("waytix", "config", "sub_link")
    if not sub_link or sub_link == "" then
        return json_response({ 
            success = false, 
            error = "Не задана ссылка на подписку" 
        }, 400)
    end
    
    -- Скачиваем подписку
    local cmd = string.format("curl -s '%s' | base64 -d 2>/dev/null || curl -s '%s'", sub_link, sub_link)
    local handle = io.popen(cmd)
    if not handle then
        return json_response({ 
            success = false, 
            error = "Ошибка при загрузке подписки" 
        }, 500)
    end
    
    local subscription = handle:read("*a")
    handle:close()
    
    if not subscription or subscription == "" then
        return json_response({ 
            success = false, 
            error = "Не удалось загрузить подписку" 
        }, 500)
    end
    
    -- Разбираем подписку
    local servers = {}
    for server in subscription:gmatch("vless://([^\r\n]+)") do
        table.insert(servers, "vless://" .. server)
    end
    
    if #servers == 0 then
        return json_response({ 
            success = false, 
            error = "Не найдено серверов в подписке" 
        }, 400)
    end
    
    -- Сохраняем серверы в конфиг
    uci:delete("waytix", "@servers")
    
    for i, server in ipairs(servers) do
        local id = "server" .. i
        uci:set("waytix", id, "server")
        uci:set("waytix", id, "url", server)
        uci:set("waytix", id, "name", "Сервер " .. i)
    end
    
    uci:commit("waytix")
    
    json_response({ 
        success = true, 
        count = #servers,
        message = string.format("Обновлено %d серверов", #servers)
    })
end

-- Функция для обновления конфигурации Xray
local function update_xray_config()
    local uci = require "luci.model.uci".cursor()
    local json = require "luci.jsonc"
    local nixio = require "nixio"
    
    -- Получаем выбранный сервер
    local selected = uci:get("waytix", "config", "selected_server")
    if not selected then
        return false
    end
    
    -- Получаем данные сервера
    local server = {
        uuid = uci:get("waytix", selected, "uuid"),
        host = uci:get("waytix", selected, "host"),
        port = tonumber(uci:get("waytix", selected, "port")),
        type = uci:get("waytix", selected, "type") or "tcp",
        security = uci:get("waytix", selected, "security") or "none",
        path = uci:get("waytix", selected, "path") or "",
        sni = uci:get("waytix", selected, "sni") or "",
        fp = uci:get("waytix", selected, "fp") or "",
        alpn = uci:get("waytix", selected, "alpn") or "",
        pbk = uci:get("waytix", selected, "pbk") or "",
        sid = uci:get("waytix", selected, "sid") or "",
        flow = uci:get("waytix", selected, "flow") or ""
    }
    
    if not server.uuid or not server.host or not server.port then
        return false
    end
    
    -- Собираем конфиг Xray
    local config = {
        log = {
            loglevel = "warning"
        },
        inbounds = {
            {
                port = 1080,
                listen = "0.0.0.0",
                protocol = "socks",
                settings = {
                    auth = "noauth",
                    udp = true,
                    ip = "127.0.0.1"
                }
            }
        },
        outbounds = {
            {
                protocol = "vless",
                settings = {
                    vnext = {
                        {
                            address = server.host,
                            port = server.port,
                            users = {
                                {
                                    id = server.uuid,
                                    flow = server.flow ~= "" and server.flow or nil,
                                    encryption = "none"
                                }
                            }
                        }
                    }
                },
                streamSettings = {
                    network = server.type,
                    security = server.security ~= "none" and server.security or nil,
                    tlsSettings = (server.security == "tls" or server.security == "xtls") and {
                        serverName = server.sni ~= "" and server.sni or nil,
                        fingerprint = server.fp ~= "" and server.fp or nil,
                        alpn = server.alpn ~= "" and {server.alpn} or nil
                    } or nil,
                    wsSettings = server.type == "ws" and {
                        path = server.path ~= "" and server.path or "/",
                        headers = {
                            Host = server.host
                        }
                    } or nil,
                    grpcSettings = server.type == "grpc" and {
                        serviceName = server.path ~= "" and server.path:gsub("^/+", "") or nil
                    } or nil
                }
            }
        }, {
            protocol = "freedom",
            tag = "direct"
        }, {
            protocol = "blackhole",
            tag = "blocked"
        }],
        routing = {
            domainStrategy = "IPOnDemand",
            rules = [{
                type = "field",
                ip = ["geoip:private"],
                outboundTag = "blocked"
            }]
        }
    }
    
    -- Записываем конфиг в файл
    local config_file = "/etc/xray/config.json"
    local fd = nixio.open(config_file, "w")
    if fd then
        fd:write(json.stringify(config, true))
        fd:close()
        return true
    end
    
    return false
end

function action_servers()
    local servers = {}
    local selected = uci:get("waytix", "config", "selected_server")
    
    -- Получаем список серверов из конфигурации
    uci:foreach("waytix", "server", function(s)
        table.insert(servers, {
            id = s[".name"],
            name = s.name or s.host or s[".name"],
            host = s.host,
            port = tonumber(s.port) or 0,
            type = s.type or "tcp",
            security = s.security or "none",
            selected = (selected == s[".name"])
        })
    end)
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json(servers)
end

function action_savesub()
    local http = require "luci.http"
    local uci = require "luci.model.uci".cursor()
    
    -- Получаем ссылку из POST-запроса
    local sub_link = http.formvalue("sub_link")
    
    if not sub_link or sub_link == "" then
        http.status(400, "Bad Request")
        http.prepare_content("application/json")
        http.write_json({success = false, message = "Не указана ссылка на подписку"})
        return
    end
    
    -- Сохраняем ссылку в конфиг
    uci:set("waytix", "config", "waytix")
    uci:set("waytix", "config", "sub_link", sub_link)
    uci:save("waytix")
    uci:commit("waytix")
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json({success = true, message = "Ссылка на подписку сохранена"})
end

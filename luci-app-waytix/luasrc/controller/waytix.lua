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
        connections = 0,
        total_upload = 0,
        total_download = 0,
        last_updated = os.time()
    }
    
    -- Получаем общий трафик из iptables
    local function get_iptables_traffic()
        local cmd = "iptables -nvx -L XRAY_OUT 2>/dev/null | grep '^[ ]*[0-9]' | awk '{print $2}' | head -1"
        local out = io.popen(cmd)
        if out then
            stats.total_download = tonumber(out:read("*a") or 0) or 0
            out:close()
        end
        
        cmd = "iptables -nvx -L XRAY_IN 2>/dev/null | grep '^[ ]*[0-9]' | awk '{print $2}' | head -1"
        out = io.popen(cmd)
        if out then
            stats.total_upload = tonumber(out:read("*a") or 0) or 0
            out:close()
        end
    end
    
    -- Получаем статистику из Xray API, если включено
    get_iptables_traffic()
    
    -- Пробуем получить статистику из Xray API, если включено
    if uci:get(UCI_CONFIG, "xray", "enable_stats") ~= "0" then
        local api_port = uci:get(UCI_CONFIG, "xray", "api_port") or "10085"
        local cmd = string.format(
            "curl -s http://127.0.0.1:%s/stats -d '{\"pattern\":\"\",\"reset\":false}' 2>/dev/null || \
             curl -s http://127.0.0.1:%s/stats -d '\\
             {\\\"name\\\": \\\"inbound>>proxy>>>traffic>>>downlink\\\", \\\"reset\\\": false}, \\
             {\\\"name\\\": \\\"inbound>>proxy>>>traffic>>>uplink\\\", \\\"reset\\\": false}, \\
             {\\\"name\\\": \\\"inbound>>proxy>>>traffic>>>>connection\\\", \\\"reset\\\": false}'",
            api_port, api_port
        )
        
        local result, err = exec(cmd, 5) -- Таймаут 5 секунд
        if result then
            local ok, data = pcall(json.parse, result)
            if ok and data then
                -- Обработка нового формата ответа (Xray 1.8.0+)
                if data.stat then
                    for _, stat in ipairs(data.stat) do
                        if stat.name:find("downlink$") then
                            stats.download = tonumber(stat.value) or 0
                        elseif stat.name:find("uplink$") then
                            stats.upload = tonumber(stat.value) or 0
                        elseif stat.name:find("connection$") then
                            stats.connections = tonumber(stat.value) or 0
                        end
                    end
                -- Обработка старого формата ответа
                elseif data["inbound>>proxy>>>traffic>>>downlink"] then
                    stats.download = tonumber(data["inbound>>proxy>>>traffic>>>downlink"]) or 0
                    stats.upload = tonumber(data["inbound>>proxy>>>traffic>>>uplink"]) or 0
                    stats.connections = tonumber(data["inbound>>proxy>>>traffic>>>>connection"]) or 0
                end
            end
        else
            log_message("warn", "Не удалось получить статистику из Xray API: " .. tostring(err))
        end
    end
    
    -- Получаем время работы процесса
    local is_running, pid = is_xray_running()
    if is_running then
        -- Используем /proc для получения времени работы процесса (более надежно)
        local uptime_cmd = string.format("cat /proc/%d/stat 2>/dev/null | awk '{print $22}' || ps -o etimes= -p %d 2>/dev/null", pid, pid)
        local uptime = exec(uptime_cmd)
        if uptime then
            -- Если получили время из /proc, переводим тики в секунды
            local uptime_ticks = tonumber(uptime) or 0
            if uptime_ticks > 0 then
                -- Получаем количество тиков в секунду
                local ticks_per_sec = tonumber(exec("getconf CLK_TCK 2>/dev/null") or 100)
                stats.uptime = math.floor(uptime_ticks / ticks_per_sec)
            else
                -- Если не получилось с /proc, используем значение из ps
                stats.uptime = tonumber(uptime) or 0
            end
        end
        
        -- Если не удалось получить время работы, пробуем через ps
        if stats.uptime <= 0 then
            uptime = exec(string.format("ps -o etimes= -p %d 2>/dev/null", pid))
            stats.uptime = tonumber(uptime) or 0
        end
    end
    
    -- Добавляем человекочитаемый формат времени работы
    if stats.uptime > 0 then
        local days = math.floor(stats.uptime / 86400)
        local hours = math.floor((stats.uptime % 86400) / 3600)
        local minutes = math.floor((stats.uptime % 3600) / 60)
        local seconds = stats.uptime % 60
        
        stats.uptime_text = string.format("%dд %02d:%02d:%02d", days, hours, minutes, seconds)
    else
        stats.uptime_text = "00:00:00"
    end
    
    return stats
end

-- Получение статуса сервиса
function action_status()
    require_modules()
    
    -- Получаем текущий статус Xray
    local is_running, pid = is_xray_running()
    local stats = get_xray_stats()
    local selected_server = uci:get(UCI_CONFIG, "config", "selected_server")
    local server_info = {}
    
    -- Получаем информацию о выбранном сервере
    if selected_server and selected_server ~= "" then
        local server = uci:get_all(UCI_CONFIG, selected_server) or {}
        if server and server.host then
            server_info = {
                id = selected_server,
                name = server.name or selected_server,
                host = server.host,
                port = tonumber(server.port) or 443,
                type = server.type or "tcp",
                security = server.security or "tls",
                sni = server.sni or "",
                last_used = tonumber(server.last_used) or 0
            }
            
            -- Форматируем дату последнего использования
            if server_info.last_used > 0 then
                server_info.last_used_text = os.date("%Y-%m-%d %H:%M:%S", server_info.last_used)
            else
                server_info.last_used_text = "никогда"
            end
        end
    end
    
    -- Формируем ответ
    local response = {
        success = true,
        running = is_running,
        pid = pid,
        server = server_info,
        stats = stats,
        timestamp = os.time(),
        version = "1.0.0"
    }
    
    -- Добавляем информацию о системе
    local meminfo = nixio.fs.readfile("/proc/meminfo")
    if meminfo then
        local total_mem = meminfo:match("MemTotal:%s*(%d+)")
        local free_mem = meminfo:match("MemFree:%s*(%d+)")
        local buffers = meminfo:match("Buffers:%s*(%d+)")
        local cached = meminfo:match("Cached:%s*(%d+)")
        
        if total_mem and free_mem and buffers and cached then
            total_mem = tonumber(total_mem)
            free_mem = tonumber(free_mem) + tonumber(buffers) + tonumber(cached)
            response.system = {
                memory = {
                    total = total_mem,
                    free = free_mem,
                    used = total_mem - free_mem,
                    usage = math.floor(((total_mem - free_mem) / total_mem) * 100)
                },
                uptime = nixio.sysinfo().uptime,
                loadavg = nixio.sysinfo().load
            }
        end
    end
    
    return json_response(response)
    
    local is_running, pid = is_xray_running()
    local stats = get_xray_stats()
    local selected_server = uci:get(UCI_CONFIG, "config", "selected_server")
    local server_name = "Не подключено"
    local server_address = ""
    
    -- Получаем информацию о выбранном сервере, если он есть
    if selected_server and selected_server ~= "" then
        local server_id = selected_server:match("^server(%d+)$")
        if server_id then
            local server = uci:get_all(UCI_CONFIG, selected_server)
            if server and server.name then
                server_name = server.name
                if server.address and server.port then
                    server_address = server.address .. ":" .. server.port
                end
            end
        end
    end
    
    local status = {
        success = true,
        running = is_running,
        server = {
            id = selected_server or "",
            name = server_name,
            address = server_address,
            selected = selected_server or ""
        },
        stats = {
            uptime = stats.uptime or 0,
            upload = stats.upload or 0,
            download = stats.download or 0,
            connections = stats.connections or 0,
            total_upload = stats.total_upload or 0,
            total_download = stats.total_download or 0
        },
        version = "1.0.0",
        timestamp = os.time()
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
    local selected_server = uci:get(UCI_CONFIG, "config", "selected_server")
    local is_running = is_xray_running()
    
    -- Получаем текущую статистику трафика для серверов
    local stats = {}
    if is_running and uci:get(UCI_CONFIG, "xray", "enable_stats") ~= "0" then
        local api_port = uci:get(UCI_CONFIG, "xray", "api_port") or "10085"
        local cmd = string.format(
            "curl -s http://127.0.0.1:%s/stats -d '{\"pattern\":\"\",\"reset\":false}' 2>/dev/null || true",
            api_port
        )
        local result = exec(cmd, 5) -- Таймаут 5 секунд
        if result then
            local ok, data = pcall(json.parse, result)
            if ok and data and data.stat then
                for _, stat in ipairs(data.stat) do
                    -- Пример имени: "inbound>>>api>>>downlink>>>tag=server1"
                    local tag = stat.name:match(">>>tag=([^>]+)$")
                    if tag and (stat.name:find("downlink$") or stat.name:find("uplink$")) then
                        stats[tag] = stats[tag] or { download = 0, upload = 0 }
                        if stat.name:find("downlink$") then
                            stats[tag].download = tonumber(stat.value) or 0
                        elseif stat.name:find("uplink$") then
                            stats[tag].upload = tonumber(stat.value) or 0
                        end
                    end
                end
            end
        end
    end
    
    -- Получаем список серверов
    uci:foreach(UCI_CONFIG, "server", 
        function(section)
            if section[".name"] and section.url then
                local server_id = section[".name"]
                local is_selected = (server_id == selected_server)
                local server_stats = stats[server_id] or { download = 0, upload = 0 }
                
                table.insert(servers, {
                    id = server_id,
                    name = section.name or "Сервер " .. #servers + 1,
                    url = section.url,
                    address = section.address or "",
                    port = tonumber(section.port) or 443,
                    type = section.type or "tcp",
                    security = section.security or "tls",
                    selected = is_selected,
                    active = is_selected and is_running,
                    stats = {
                        download = server_stats.download,
                        upload = server_stats.upload,
                        total = server_stats.download + server_stats.upload
                    },
                    last_used = is_selected and os.time() or nil,
                    latency = nil, -- Можно добавить пинг при необходимости
                    tags = section.tags and section.tags:split(" ") or {}
                })
            end
        end
    )
    
    -- Сортируем серверы: выбранный сервер первый, затем по имени
    table.sort(servers, function(a, b)
        if a.selected then return true end
        if b.selected then return false end
        return a.name:lower() < b.name:lower()
    end)
    
    return json_response({ 
        success = true, 
        servers = servers,
        total = #servers,
        selected = selected_server,
        is_running = is_running
    })
end


-- Выбор сервера
function action_select()
    require_modules()
    
    local http = luci.http
    local server_id = http.formvalue("server")
    
    if not server_id or server_id == "" then
        return json_response({ success = false, error = "Не указан ID сервера" }, 400)
    end
    
    -- Проверяем существование сервера
    local server = uci:get_all(UCI_CONFIG, server_id)
    if not server or not server.url then
        return json_response({ success = false, error = "Указанный сервер не найден" }, 404)
    end
    
    -- Получаем текущий выбранный сервер
    local current_server = uci:get(UCI_CONFIG, "config", "selected_server")
    
    -- Если выбран тот же сервер, просто возвращаем успех
    if current_server == server_id then
        return json_response({ 
            success = true, 
            message = "Сервер уже выбран",
            server_id = server_id,
            server_name = server.name or server_id,
            restart_required = false
        })
    end
    
    -- Сохраняем выбранный сервер
    uci:set(UCI_CONFIG, "config", "selected_server", server_id)
    
    -- Обновляем время последнего использования сервера
    uci:set(UCI_CONFIG, server_id, "last_used", os.time())
    
    -- Сохраняем изменения
    uci:commit(UCI_CONFIG)
    
    log_message("info", "Выбран сервер: " .. server_id .. (server.name and (" (" .. server.name .. ")") or ""))
    
    -- Проверяем, запущен ли Xray
    local is_running = is_xray_running()
    local restart_required = false
    
    -- Если сервис запущен, обновляем конфигурацию и перезапускаем
    if is_running then
        -- Генерируем новый конфиг Xray
        local config_updated = update_xray_config()
        
        if config_updated then
            -- Пытаемся плавно перезагрузить конфиг (SIGHUP)
            local pid = nixio.fs.readfile(PID_FILE)
            if pid and #pid > 0 then
                pid = pid:match("%d+")
                if pid then
                    log_message("info", "Отправляем SIGHUP процессу Xray для перезагрузки конфигурации")
                    os.execute("kill -HUP " .. pid .. " 2>/dev/null")
                    
                    -- Проверяем, успешно ли перезагрузился конфиг
                    nixio.nanosleep(1) -- Даем время на применение конфига
                    
                    -- Если конфиг не применился, перезапускаем сервис полностью
                    if not is_xray_running() then
                        log_message("warn", "Не удалось перезагрузить конфиг, перезапускаем сервис")
                        os.execute("/etc/init.d/waytix restart >/dev/null 2>&1 &")
                        restart_required = true
                    end
                end
            else
                -- Если не удалось отправить SIGHUP, перезапускаем сервис
                log_message("warn", "Не удалось отправить SIGHUP процессу Xray, перезапускаем сервис")
                os.execute("/etc/init.d/waytix restart >/dev/null 2>&1 &")
                restart_required = true
            end
        else
            log_message("error", "Не удалось обновить конфигурацию Xray")
            return json_response({ 
                success = false, 
                error = "Ошибка обновления конфигурации Xray" 
            }, 500)
        end
    end
    
    -- Возвращаем информацию о выбранном сервере
    return json_response({ 
        success = true, 
        message = "Сервер успешно выбран",
        server_id = server_id,
        server_name = server.name or server_id,
        server_address = server.address or "",
        server_port = tonumber(server.port) or 443,
        restart_required = restart_required,
        is_running = is_running
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

function action_toggle()
    require_modules()
    
    local is_running, pid = is_xray_running()
    local selected_server = uci:get(UCI_CONFIG, "config", "selected_server")
    local server_name = ""
    
    -- Получаем имя сервера для логирования
    if selected_server and selected_server ~= "" then
        local server = uci:get_all(UCI_CONFIG, selected_server) or {}
        server_name = server.name or selected_server
    end
    
    local result = {}
    
    if is_running then
        -- Останавливаем сервис
        log_message("info", "Остановка VPN сервиса (PID: " .. (pid or "?") .. ")")
        
        -- Плавная остановка с таймаутом
        local stop_cmd = "/etc/init.d/waytix stop"
        local ok, err = exec(stop_cmd, 10) -- 10 секунд на остановку
        
        if ok then
            log_message("info", "VPN сервис успешно остановлен")
            result = { 
                success = true, 
                action = "stopped",
                message = "VPN сервис успешно остановлен",
                server_id = selected_server,
                server_name = server_name,
                timestamp = os.time()
            }
        else
            log_message("error", "Ошибка при остановке VPN: " .. (err or "неизвестная ошибка"))
            return json_response({ 
                success = false, 
                error = "Не удалось остановить VPN сервис: " .. (err or "неизвестная ошибка"),
                server_id = selected_server,
                server_name = server_name
            }, 500)
        end
    else
        -- Проверяем, выбран ли сервер
        if not selected_server or selected_server == "" then
            return json_response({ 
                success = false, 
                error = "Не выбран сервер для подключения" 
            }, 400)
        end
        
        -- Запускаем сервис
        log_message("info", "Запуск VPN сервиса (Сервер: " .. server_name .. ")")
        
        -- 1. Обновляем конфигурацию Xray
        log_message("debug", "Обновление конфигурации Xray...")
        local config_updated, config_error = update_xray_config()
        
        if not config_updated then
            local err_msg = "Ошибка обновления конфигурации Xray: " .. (config_error or "неизвестная ошибка")
            log_message("error", err_msg)
            return json_response({ 
                success = false, 
                error = err_msg,
                server_id = selected_server,
                server_name = server_name
            }, 500)
        end
        
        -- 2. Запускаем сервис
        log_message("debug", "Запуск сервиса waytix...")
        local start_cmd = "/etc/init.d/waytix start"
        local start_ok, start_err = exec(start_cmd, 10) -- 10 секунд на запуск
        
        -- 3. Проверяем, запустился ли сервис
        nixio.nanosleep(1) -- Даем время на запуск
        
        local new_running, new_pid = is_xray_running()
        
        if new_running then
            log_message("info", "VPN сервис успешно запущен (PID: " .. (new_pid or "?") .. ")")
            
            -- Обновляем время последнего использования сервера
            uci:set(UCI_CONFIG, selected_server, "last_used", os.time())
            uci:commit(UCI_CONFIG)
            
            -- Получаем обновленную статистику
            local stats = get_xray_stats()
            
            result = { 
                success = true, 
                action = "started",
                message = "VPN сервис успешно запущен",
                server_id = selected_server,
                server_name = server_name,
                pid = new_pid,
                stats = stats,
                timestamp = os.time()
            }
        else
            -- Пытаемся получить логи для диагностики
            local log_tail = ""
            if nixio.fs.access("/var/log/xray.log") then
                log_tail = exec("tail -n 20 /var/log/xray.log 2>/dev/null || echo 'Логи недоступны'")
            end
            
            log_message("error", "Не удалось запустить VPN сервис. Логи:\n" .. (log_tail or "Логи недоступны"))
            
            result = { 
                success = false, 
                error = "Не удалось запустить VPN сервис. Проверьте логи для подробностей.",
                server_id = selected_server,
                server_name = server_name,
                log_tail = log_tail
            }
        end
    end
    
    -- Добавляем информацию о текущем статусе
    result.running = not is_running
    
    return json_response(result)
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
-- Функция для обновления конфигурации Xray
local function update_xray_config()
    require_modules()
    
    -- Получаем выбранный сервер
    local server_id = uci:get(UCI_CONFIG, "config", "selected_server")
    if not server_id or server_id == "" then
        log_message("error", "Не выбран сервер для обновления конфигурации")
        return false, "Не выбран сервер для обновления конфигурации"
    end
    
    -- Получаем настройки сервера
    local server = uci:get_all(UCI_CONFIG, server_id)
    if not server then
        log_message("error", "Конфигурация сервера не найдена: " .. tostring(server_id))
        return false, "Конфигурация сервера не найдена"
    end
    
    -- Парсим URL сервера, если он есть
    if server.url and server.url ~= "" then
        -- Пример: vmess://uuid@host:port?security=...
        if server.url:match("^vmess://") then
            local base64 = server.url:match("^vmess://([^/]+)")
            if base64 then
                local json_ok, json_data = pcall(function()
                    local base64_decoded = nixio.bin.b64decode(base64)
                    return json.parse(base64_decoded)
                end)
                
                if json_ok and json_data then
                    -- Обновляем параметры сервера из URL
                    server.host = json_data.add or server.host
                    server.port = tonumber(json_data.port) or server.port or 443
                    server.uuid = json_data.id or server.uuid
                    server.alterId = tonumber(json_data.aid) or server.alterId or 0
                    server.security = json_data.scy or server.security or "auto"
                    server.network = json_data.net or server.network or "tcp"
                    server.type = json_data.type or server.type or "none"
                    server.path = json_data.path or server.path or ""
                    server.hostname = json_data.host or server.hostname or ""
                    server.tls = (json_data.tls == "tls") and "1" or "0"
                    server.sni = json_data.sni or server.sni or ""
                end
            end
        end
    end
    
    -- Базовая конфигурация Xray
    local config = {
        log = {
            loglevel = uci:get(UCI_CONFIG, "xray", "log_level") or "warning",
            access = "/var/log/xray/access.log",
            error = "/var/log/xray/error.log"
        },
        inbounds = {},
        outbounds = {},
        routing = {
            domainStrategy = "IPIfNonMatch",
            rules = {}
        },
        policy = {
            levels = {
                [0] = {
                    handshake = 4,
                    connIdle = 300,
                    uplinkOnly = 2,
                    downlinkOnly = 5,
                    statsUserUplink = true,
                    statsUserDownlink = true
                }
            },
            system = {
                statsInboundUplink = true,
                statsInboundDownlink = true
            }
        }
    }
    
    -- Настройки API для статистики
    if uci:get(UCI_CONFIG, "xray", "enable_stats") == "1" then
        local api_port = tonumber(uci:get(UCI_CONFIG, "xray", "api_port") or "10085")
        config.api = {
            tag = "api",
            services = {"HandlerService", "LoggerService", "StatsService"}
        }
        
        config.stats = {}
        
        table.insert(config.inbounds, {
            listen = "127.0.0.1",
            port = api_port,
            protocol = "dokodemo-door",
            settings = {address = "127.0.0.1"},
            tag = "api"
        })
        
        table.insert(config.routing.rules, {
            type = "field",
            inboundTag = {"api"},
            outboundTag = "api"
        })
    end
    
    -- Настройки DNS
    local dns_servers = {}
    local dns_server = uci:get(UCI_CONFIG, "config", "dns_server") or "1.1.1.1"
    for server in dns_server:gmatch("[^, ]+") do
        table.insert(dns_servers, server)
    end
    
    if #dns_servers > 0 then
        config.dns = {
            servers = dns_servers
        }
    end
    
    -- Настройки исходящего подключения (основной сервер)
    local outbound = {
        protocol = "vmess",
        tag = "proxy",
        settings = {
            vnext = {
                {
                    address = server.host or "",
                    port = tonumber(server.port) or 443,
                    users = {
                        {
                            id = server.uuid or "",
                            alterId = tonumber(server.alterId) or 0,
                            security = server.security or "auto",
                            level = 0
                        }
                    }
                }
            }
        },
        streamSettings = {
            network = server.network or "tcp",
            security = (server.tls == "1") and "tls" or "none",
            tlsSettings = {},
            tcpSettings = {},
            wsSettings = {},
            httpSettings = {},
            kcpSettings = {},
            quicSettings = {},
            dsSettings = {}
        }
    }
    
    -- Настройка TLS
    if server.tls == "1" then
        outbound.streamSettings.tlsSettings = {
            serverName = server.sni or server.host or "",
            allowInsecure = server.insecure == "1" or false,
            alpn = {"h2", "http/1.1"}
        }
    end
    
    -- Настройки для разных типов транспорта
    local network = server.network or "tcp"
    if network == "ws" then
        outbound.streamSettings.wsSettings = {
            path = server.path or "/",
            headers = {
                Host = server.host or ""
            }
        }
    elseif network == "http" then
        outbound.streamSettings.httpSettings = {
            path = {server.path or "/"},
            host = {server.host or ""}
        }
    elseif network == "kcp" then
        outbound.streamSettings.kcpSettings = {
            mtu = 1350,
            tti = 20,
            uplinkCapacity = 5,
            downlinkCapacity = 20,
            congestion = false,
            readBufferSize = 1,
            writeBufferSize = 1,
            header = {
                type = server.type or "none"
            }
        }
    end
    
    -- Добавляем исходящее подключение в конфигурацию
    table.insert(config.outbounds, outbound)
    
    -- Добавляем правило для маршрутизации всего трафика через прокси
    table.insert(config.routing.rules, {
        type = "field",
        outboundTag = "proxy",
        network = "tcp,udp"
    })
    
    -- Создаем директорию для логов, если не существует
    nixio.fs.mkdirr("/var/log/xray")
    
    -- Записываем конфигурацию в файл
    local config_dir = "/etc/xray"
    if not nixio.fs.stat(config_dir) then
        nixio.fs.mkdirr(config_dir)
    end
    
    -- Создаем резервную копию старой конфигурации
    if nixio.fs.access(XRAY_CONFIG) then
        os.execute(string.format("cp %s %s.bak", XRAY_CONFIG, XRAY_CONFIG))
    end
    
    -- Записываем новую конфигурацию
    local config_json = json.stringify(config, true, 2)
    local config_file = io.open(XRAY_CONFIG, "w")
    if not config_file then
        log_message("error", "Не удалось открыть файл конфигурации для записи: " .. XRAY_CONFIG)
        return false, "Не удалось открыть файл конфигурации для записи"
    end
    
    config_file:write(config_json)
    config_file:close()
    
    log_message("info", "Конфигурация Xray успешно обновлена для сервера: " .. (server.name or server_id))
    return true
end

function action_servers()
    local servers = {}
    local selected = uci:get(UCI_CONFIG, "config", "selected_server")
    
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

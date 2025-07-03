module("luci.controller.waytix", package.seeall)

local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local util = require "luci.util"
local json = require "luci.jsonc"
local nixio = require "nixio"
local fs = require "nixio.fs"

-- Константы
local UCI_CONFIG = "waytix"
local XRAY_CONFIG = "/etc/xray/config.json"
local LOG_FILE = "/var/log/waytix.log"

-- Инициализация логгера
local function log(level, message)
    local log_levels = {debug = 1, info = 2, warning = 3, error = 4}
    local current_level = uci:get(UCI_CONFIG, "config", "log_level") or "warning"
    
    if log_levels[level] >= (log_levels[current_level:lower()] or 2) then
        local log_entry = string.format("[%s] [%s] %s\n", 
            os.date("%Y-%m-%d %H:%M:%S"), 
            level:upper(), 
            tostring(message))
        
        -- Пишем в системный лог
        nixio.syslog("info", "waytix: " .. message)
        
        -- Пишем в файл лога
        local log_fd = nixio.open(LOG_FILE, "a")
        if log_fd then
            log_fd:write(log_entry)
            log_fd:close()
        end
    end
end

-- Вспомогательная функция для выполнения команд
local function exec(command)
    local pp = io.popen(command .. " 2>&1")
    local result = pp:read("*a")
    local success = pp:close()
    return success, result
end

-- Проверка работы сервиса
local function is_running()
    return nixio.fs.access("/var/run/waytix.pid")
end

-- Получение списка серверов
local function get_servers()
    local servers = {}
    uci:foreach(UCI_CONFIG, "server", function(s)
        if s[".name"] and s.url then
            table.insert(servers, {
                id = s[".name"],
                name = s.name or s[".name"],
                host = s.host or "",
                port = tonumber(s.port) or 0,
                type = s.type or "tcp",
                security = s.security or "none",
                selected = (s[".name"] == uci:get(UCI_CONFIG, "config", "selected_server"))
            })
        end
    end)
    return servers
end

-- Получение статистики трафика
local function get_traffic()
    local function get_bytes(chain)
        local cmd = string.format("iptables -nvx -L %s 2>/dev/null | grep '^[ ]*[0-9]' | awk '{print $2}' | head -1", chain)
        local fd = io.popen(cmd)
        local bytes = tonumber(fd:read("*a")) or 0
        fd:close()
        return bytes
    end
    
    local function format_bytes(bytes)
        if not bytes or bytes == 0 then return "0 B" end
        local units = {"B", "KB", "MB", "GB", "TB"}
        local i = 1
        while bytes > 1024 and i < #units do
            bytes = bytes / 1024
            i = i + 1
        end
        return string.format("%.2f %s", bytes, units[i])
    end
    
    local up = get_bytes("XRAY_OUT") or 0
    local down = get_bytes("XRAY_IN") or 0
    
    return {
        up = up,
        down = down,
        formatted = {
            up = format_bytes(up),
            down = format_bytes(down)
        }
    }
end

-- Основные маршруты
function index()
    entry({"admin", "services", "waytix"}, 
         template("waytix/control"), 
         _("Шарманка 3000"), 60).dependent = true
    
    entry({"admin", "services", "waytix", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "waytix", "toggle"}, call("action_toggle")).leaf = true
    entry({"admin", "services", "waytix", "update"}, call("action_update")).leaf = true
    entry({"admin", "services", "waytix", "servers"}, call("action_servers")).leaf = true
    entry({"admin", "services", "waytix", "savesub"}, call("action_savesub")).leaf = true
    entry({"admin", "services", "waytix", "select"}, call("action_select")).leaf = true
    entry({"admin", "services", "waytix", "traffic"}, call("action_traffic")).leaf = true
end

-- API методы
function action_status()
    return json_response({
        running = is_running(),
        servers = get_servers(),
        selected = uci:get(UCI_CONFIG, "config", "selected_server"),
        traffic = get_traffic()
    })
end

function action_toggle()
    local running = is_running()
    local cmd = running and "stop" or "start"
    
    local result = os.execute(string.format("/etc/init.d/waytix %s", cmd))
    
    return json_response({
        success = result == true or result == 0,
        running = not running
    })
end

function action_servers()
    return json_response(get_servers())
end

function action_traffic()
    return json_response(get_traffic())
end

function action_select()
    local server = http.formvalue("server")
    if not server then
        return json_response({success = false, error = "Не указан сервер"}, 400)
    end
    
    uci:set(UCI_CONFIG, "config", "selected_server", server)
    uci:commit(UCI_CONFIG)
    
    if is_running() then
        os.execute("/etc/init.d/waytix restart")
    end
    
    return json_response({success = true})
end

function action_savesub()
    local sub_link = http.formvalue("sub_link")
    if not sub_link then
        return json_response({success = false, error = "Не указана ссылка на подписку"}, 400)
    end
    
    -- Сохраняем ссылку в конфиг
    uci:set(UCI_CONFIG, "config", "sub_link", sub_link)
    uci:commit(UCI_CONFIG)
    
    return action_update()
end

function action_update()
    local sub_link = uci:get(UCI_CONFIG, "config", "sub_link")
    if not sub_link then
        return json_response({success = false, error = "Не задана ссылка на подписку"}, 400)
    end
    
    -- Скачиваем подписку
    local cmd = string.format("curl -s '%s' | base64 -d 2>/dev/null || curl -s '%s'", sub_link, sub_link)
    local handle = io.popen(cmd)
    local subscription = handle:read("*a")
    handle:close()
    
    -- Парсим серверы
    local servers = {}
    for server in subscription:gmatch("vless://([^\r\n]+)") do
        table.insert(servers, "vless://" .. server)
    end
    
    -- Сохраняем серверы в конфиг
    uci:delete_all(UCI_CONFIG, "server")
    for i, server in ipairs(servers) do
        local id = "server" .. i
        uci:set(UCI_CONFIG, id, "server")
        uci:set(UCI_CONFIG, id, "url", server)
    end
    
    uci:commit(UCI_CONFIG)
    
    return json_response({
        success = true,
        count = #servers
    })
end

-- Вспомогательная функция для JSON-ответов
function json_response(data, status)
    http.prepare_content("application/json")
    http.write_json(data or {})
    return status or 200
end

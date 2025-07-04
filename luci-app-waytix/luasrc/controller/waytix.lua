module("luci.controller.waytix", package.seeall)

local uci = require "luci.model.uci".cursor()
local json = require "luci.jsonc"
local nixio = require "nixio"
local http = require "luci.http"
local util = require "luci.util"

-- Константы
local UCI_CONFIG = "waytix"
local XRAY_CONFIG = "/etc/xray/config.json"
local LOG_FILE = "/var/log/waytix.log"
local SCRIPTS_DIR = "/etc/waytix/"

-- Вспомогательные функции
local function log(level, message)
    local log_fd = nixio.open(LOG_FILE, "a")
    if log_fd then
        log_fd:write(string.format("[%s] [%s] %s\n", 
            os.date("%Y-%m-%d %H:%M:%S"), 
            level:upper(), 
            tostring(message)))
        log_fd:close()
    end
end

local function exec(command)
    local pp = io.popen(command .. " 2>&1")
    local result = pp:read("*a")
    local success = pp:close()
    return success, result
end

local function is_running()
    -- Check if PID file exists and process is running
    local pid_file = "/var/run/xray.pid"
    if not nixio.fs.access(pid_file) then
        return false
    end
    
    -- Read PID from file
    local pid_fd = nixio.open(pid_file, "r")
    if not pid_fd then
        return false
    end
    
    local pid = pid_fd:read("*a"):match("(%d+)")
    pid_fd:close()
    
    if not pid then
        return false
    end
    
    -- Check if process exists
    return nixio.fs.access("/proc/" .. pid)
end

local function get_servers()
    local servers = {}
    local selected_server = uci:get(UCI_CONFIG, "config", "selected_server")
    
    uci:foreach(UCI_CONFIG, "server", function(s)
        if s[".name"] and s.host and s.port then
            -- Get the server name from UCI option 'name' or extract from URL or use host as fallback
            local server_name = uci:get(UCI_CONFIG, s[".name"], "name")
            
            -- If name is not set, try to extract it from the URL (after #)
            if not server_name and s.url then
                local name_from_url = s.url:match("#([^#]+)$")
                if name_from_url and #name_from_url > 0 then
                    -- URL-decode the name
                    server_name = name_from_url:gsub("%%(%x%x)", function(h)
                        return string.char(tonumber(h, 16))
                    end)
                end
            end
            
            -- If still no name, use host or section name as fallback
            server_name = server_name or s.host or s[".name"]
            
            table.insert(servers, {
                id = s[".name"],
                name = server_name,
                host = s.host,
                port = tonumber(s.port) or 0,
                selected = (s[".name"] == selected_server),
                url = s.url or ""  -- Add URL for frontend display if needed
            })
        end
    end)
    
    return servers
end

local function get_traffic()
    local function get_bytes(chain)
        local cmd = string.format("iptables -nvx -L %s 2>/dev/null | grep '^[ ]*[0-9]' | awk '{print $2}' | head -1", chain)
        local fd = io.popen(cmd)
        local bytes = tonumber(fd:read("*a")) or 0
        fd:close()
        return bytes
    end
    
    -- Get process uptime in seconds
    local function get_uptime()
        if not is_running() then
            return 0
        end
        
        local pid_file = "/var/run/xray.pid"
        local pid_fd = nixio.open(pid_file, "r")
        if not pid_fd then
            return 0
        end
        
        local pid = pid_fd:read("*a"):match("(%d+)")
        pid_fd:close()
        
        if not pid then
            return 0
        end
        
        -- Read process start time from /proc/pid/stat
        local stat_fd = io.open("/proc/" .. pid .. "/stat", "r")
        if not stat_fd then
            return 0
        end
        
        local stat_data = stat_fd:read("*a")
        stat_fd:close()
        
        -- 22nd field is starttime
        local starttime = tonumber(stat_data:match("%d+%s+%S+%s+%S+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)"))
        if not starttime then
            return 0
        end
        
        -- Get system uptime
        local uptime_fd = io.open("/proc/uptime", "r")
        if not uptime_fd then
            return 0
        end
        
        local uptime = tonumber(uptime_fd:read("*a"):match("([%d.]+)"))
        uptime_fd:close()
        
        if not uptime then
            return 0
        end
        
        -- Calculate process uptime
        local hertz = 100  -- usually 100 on most systems
        local clk_tck = nixio.sysconf(nixio.CLK_TCK) or hertz
        local process_uptime = uptime - (starttime / clk_tck)
        
        return math.floor(process_uptime)
    end
    
    local up = get_bytes("XRAY_OUT") or 0
    local down = get_bytes("XRAY_IN") or 0
    
    return {
        upload = up,
        download = down,
        total = up + down,
        uptime = get_uptime()
    }
end

-- Чтение логов
local function read_logs(lines)
    local log_file = "/var/log/xray/access.log"
    if not nixio.fs.access(log_file) then
        return {}
    end
    
    local result = {}
    local cmd = string.format("tail -n %d %s 2>/dev/null", tonumber(lines) or 100, log_file)
    
    local fd = io.popen(cmd)
    if fd then
        for line in fd:lines() do
            table.insert(result, line)
        end
        fd:close()
    end
    
    return result
end

-- Очистка логов
local function clear_logs()
    local log_file = "/var/log/xray/access.log"
    if nixio.fs.access(log_file) then
        local fd = io.open(log_file, "w")
        if fd then
            fd:write("")
            fd:close()
            return true
        end
    end
    return false
end

-- Основные обработчики
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
    entry({"admin", "services", "waytix", "logs"}, call("action_logs")).leaf = true
    entry({"admin", "services", "waytix", "clearlogs"}, call("action_clearlogs")).leaf = true
end

function action_status()
    local selected = uci:get(UCI_CONFIG, "config", "selected_server")
    local current_server = nil
    
    if selected then
        uci:foreach(UCI_CONFIG, "server", function(s)
            if s[".name"] == selected then
                current_server = {
                    id = s[".name"],
                    name = s.name or s.host or s[".name"],
                    host = s.host or "",
                    port = tonumber(s.port) or 0
                }
            end
        end)
    end
    
    return json_response({
        running = is_running(),
        servers = get_servers(),
        selected = current_server and current_server.name or nil,
        traffic = get_traffic()
    })
end

function action_toggle()
    local running = is_running()
    local cmd = running and "stop" or "start"
    local success, result
    
    if cmd == "start" and not uci:get(UCI_CONFIG, "config", "selected_server") then
        return json_response({
            success = false,
            error = "No server selected",
            running = false
        })
    end
    
    success = os.execute(string.format("%sconnect.sh %s 2>&1 >/dev/null", SCRIPTS_DIR, cmd)) == 0
    
    -- Add small delay to let the service start/stop
    nixio.nanosleep(1)
    
    return json_response({
        success = success,
        running = not running,
        message = success and ("Successfully %s"):format(cmd) .. "ped" or ("Failed to %s"):format(cmd)
    })
end

function action_update()
    local result = os.execute(SCRIPTS_DIR .. "update.sh")
    
    return json_response({
        success = result == true or result == 0,
        count = #get_servers()
    })
end

function action_servers()
    return json_response(get_servers())
end

function action_savesub()
    local sub_link = http.formvalue("sub_link")
    if not sub_link then
        return json_response({success = false, error = "No subscription link provided"}, 400)
    end
    
    uci:set(UCI_CONFIG, "config", "sub_link", sub_link)
    uci:commit(UCI_CONFIG)
    
    return action_update()
end

function action_select()
    local server = http.formvalue("server")
    if not server then
        return json_response({success = false, error = "No server selected"}, 400)
    end
    
    uci:set(UCI_CONFIG, "config", "selected_server", server)
    uci:commit(UCI_CONFIG)
    
    if is_running() then
        os.execute(SCRIPTS_DIR .. "connect.sh restart")
    end
    
    return json_response({success = true})
end

function action_traffic()
    return json_response(get_traffic())
end

-- Получение логов
function action_logs()
    local logs = read_logs(100)  -- Последние 100 строк лога
    http.prepare_content("text/plain")
    http.write(table.concat(logs, "\n"))
    return http.close()
end

-- Очистка логов
function action_clearlogs()
    local success = clear_logs()
    return json_response({
        success = success,
        message = success and "Logs cleared successfully" or "Failed to clear logs"
    })
end

-- Вспомогательная функция для JSON-ответов
function json_response(data, status)
    http.prepare_content("application/json")
    http.write_json(data or {})
    return status or 200
end
            down = "0 B"
        }
    }) 
end

function action_test_connection() 
    return json_response({}) 
end

function action_restart() 
    return json_response({}) 
end

-- Вспомогательная функция для JSON-ответов
function json_response(data, status)
    require "luci.http"
    luci.http.prepare_content("application/json")
    luci.http.write_json(data or {})
    return status or 200
end

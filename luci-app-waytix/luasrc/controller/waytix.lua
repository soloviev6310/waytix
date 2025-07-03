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
    return nixio.fs.access("/var/run/xray.pid")
end

local function get_servers()
    local servers = {}
    uci:foreach(UCI_CONFIG, "server", function(s)
        if s[".name"] and s.url then
            table.insert(servers, {
                id = s[".name"],
                name = s.name or s.host or s[".name"],
                host = s.host or "",
                port = tonumber(s.port) or 0,
                selected = (s[".name"] == uci:get(UCI_CONFIG, "config", "selected_server"))
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
    
    local result = os.execute(string.format("%sconnect.sh %s", SCRIPTS_DIR, cmd))
    
    return json_response({
        success = result == true or result == 0,
        running = not running
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

module("luci.controller.waytix", package.seeall)

function index()
    local page
    
    page = entry({"admin", "services", "waytix"}, 
                template("waytix/control"), 
                _("Шарманка 3000"), 60)
    page.dependent = true
    
    page = entry({"admin", "services", "waytix", "status"}, 
                call("action_status"))
    page.leaf = true
    
    page = entry({"admin", "services", "waytix", "toggle"}, 
                call("action_toggle"))
    page.leaf = true
    
    page = entry({"admin", "services", "waytix", "update"}, 
                call("action_update"))
    page.leaf = true
    
    page = entry({"admin", "services", "waytix", "servers"}, 
                call("action_servers"))
    page.leaf = true
end

local http = require "luci.http"
local sys = require "luci.sys"
local uci = luci.model.uci.cursor()

function action_status()
    local status = {
        running = sys.call("pidof xray >/dev/null") == 0,
        server = uci:get("waytix", "config", "selected_server") or "Не подключено"
    }
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json(status)
end

function action_toggle()
    local is_running = sys.call("pidof xray >/dev/null") == 0
    local result
    
    if is_running then
        result = sys.call("killall xray 2>/dev/null")
    else
        result = sys.call("/etc/init.d/waytix start >/dev/null 2>&1")
    end
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json({success = result == 0})
end

function action_update()
    local result = sys.call("/etc/waytix/update.sh >/tmp/waytix-update.log 2>&1 &")
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json({success = result == 0})
end

function action_servers()
    local servers = {}
    
    -- Здесь можно добавить логику получения списка серверов
    -- Например, из конфигурации или внешнего источника
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json(servers)
end

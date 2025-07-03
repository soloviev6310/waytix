module("luci.controller.waytix", package.seeall)

function index()
    entry({"admin", "services", "waytix"}, cbi("waytix/waytix"), _("Шарманка 3000"), 60).dependent = true
    entry({"admin", "services", "waytix", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "waytix", "update"}, call("action_update")).leaf = true
    entry({"admin", "services", "waytix", "connect"}, call("action_connect")).leaf = true
end

function action_status()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local status = {
        running = sys.call("pidof xray >/dev/null") == 0,
        server = "Не подключено"
    }
    
    if status.running then
        local uci = require "luci.model.uci".cursor()
        status.server = uci:get("waytix", "config", "selected_server") or "Неизвестный сервер"
    end
    
    http.prepare_content("application/json")
    http.write_json(status)
end

function action_update()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local result = sys.call("/etc/waytix/update.sh >/tmp/waytix-update.log 2>&1 &")
    
    http.prepare_content("application/json")
    http.write_json({success = result == 0})
end

function action_connect()
    local http = require "luci.http"
    local sys = require "luci.sys"
    
    local server = http.formvalue("server")
    if server then
        local uci = require "luci.model.uci".cursor()
        uci:set("waytix", "config", "selected_server", server)
        uci:commit("waytix")
    end
    
    local result = sys.call("/etc/waytix/connect.sh >/tmp/waytix-connect.log 2>&1 &")
    
    http.prepare_content("application/json")
    http.write_json({success = result == 0})
end

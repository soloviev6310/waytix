module("luci.controller.waytix", package.seeall)

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
    entry({"admin", "services", "waytix", "test"}, call("action_test_connection")).leaf = true
    entry({"admin", "services", "waytix", "restart"}, call("action_restart")).leaf = true
end

-- Заглушки для API-методов
function action_status() 
    return json_response({
        running = false,
        servers = {},
        selected = nil
    }) 
end

function action_toggle() 
    return json_response({}) 
end

function action_update() 
    return json_response({success = true, count = 0}) 
end

function action_servers() 
    return json_response({}) 
end

function action_savesub() 
    return json_response({success = true}) 
end

function action_select() 
    return json_response({success = true}) 
end

function action_traffic() 
    return json_response({
        up = 0,
        down = 0,
        formatted = {
            up = "0 B",
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

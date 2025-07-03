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
    
    page = entry({"admin", "services", "waytix", "savesub"}, 
                call("action_savesub"))
    page.leaf = true
end

local http = require "luci.http"
local sys = require "luci.sys"
local uci = luci.model.uci.cursor()
local json = require "luci.jsonc"
local nixio = require "nixio"

function action_status()
    local status = {
        running = sys.call("pidof xray >/dev/null") == 0,
        server = uci:get("waytix", "config", "selected_server") or "Не подключено"
    }
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json(status)
end

function action_update()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    
    -- Получаем ссылку на подписку
    local sub_url = uci:get("waytix", "config", "sub_link")
    if not sub_url or sub_url == "" then
        http.status(400, "Bad Request")
        http.prepare_content("application/json")
        http.write_json({success = false, message = "Не указана ссылка на подписку"})
        return
    end
    
    -- Скачиваем подписку
    local cmd = string.format("curl -s '%s' | base64 -d", sub_url)
    local handle = io.popen(cmd)
    local content = handle:read("*a")
    handle:close()
    
    if not content or content == "" then
        http.status(500, "Internal Server Error")
        http.prepare_content("application/json")
        http.write_json({success = false, message = "Не удалось загрузить подписку"})
        return
    end
    
    -- Очищаем старые серверы
    uci:delete_all("waytix", "servers")
    
    -- Парсим серверы из подписки
    local servers = {}
    for line in content:gmatch("[^\r\n]+") do
        if line:match("^vless://") then
            local server = {}
            -- Парсим vless ссылку
            -- Формат: vless://uuid@host:port?type=ws&security=tls&path=/path&host=host#name
            local uuid = line:match("vless://([^@]+)")
            local host = line:match("@([^:]+)")
            local port = line:match(":(%d+)/?")
            local name = line:match("#([^#]+)$") or host
            
            if uuid and host and port then
                -- Сохраняем сервер в конфиг
                local sid = "server_" .. #servers + 1
                uci:set("waytix", sid, "server")
                uci:set("waytix", sid, "uuid", uuid)
                uci:set("waytix", sid, "host", host)
                uci:set("waytix", sid, "port", port)
                uci:set("waytix", sid, "name", name)
                table.insert(servers, {id = sid, name = name})
            end
        end
    end
    
    -- Сохраняем изменения
    uci:save("waytix")
    uci:commit("waytix")
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json({
        success = true,
        message = string.format("Обновлено %d серверов", #servers),
        servers = servers
    })
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
    
    -- Получаем список серверов из конфигурации
    uci:foreach("waytix", "server", function(s)
        table.insert(servers, {
            id = s[".name"],
            name = s.name or s.host or s[".name"],
            host = s.host,
            port = s.port
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

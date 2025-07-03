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
    local cmd = string.format("curl -s '%s' | base64 -d 2>/dev/null || curl -s '%s' | base64 -d 2>/dev/null", sub_url, sub_url)
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
    uci:delete_all("waytix", "server")
    
    -- Парсим серверы из подписки
    local servers = {}
    for line in content:gmatch("[^\r\n]+") do
        if line:match("^vless://") then
            -- Парсим vless ссылку
            -- Формат: vless://uuid@host:port?type=ws&security=tls&path=/path&host=host#name
            local uuid = line:match("vless://([^@]+)")
            local credentials = line:match("@([^#?]+)")
            local host, port = "", ""
            
            if credentials then
                host, port = credentials:match("([^:]+):?(%d*)")
            end
            
            -- Парсим параметры
            local params = {}
            for k, v in line:gmatch("([%w_]+)=([^&#]*)") do
                params[k] = v
            end
            
            -- Получаем имя сервера (после #)
            local name = line:match("#([^#]+)$") or host or "Без имени"
            
            if uuid and host and port ~= "" then
                -- Сохраняем сервер в конфиг
                local sid = "server_" .. #servers + 1
                uci:section("waytix", "server", sid, {
                    uuid = uuid,
                    host = host,
                    port = port,
                    name = name,
                    type = params.type or "tcp",
                    security = params.security or "none",
                    path = params.path or "",
                    sni = params.sni or "",
                    fp = params.fp or "",
                    alpn = params.alpn or "",
                    pbk = params.pbk or "",
                    sid = params.sid or "",
                    flow = params.flow or ""
                })
                
                table.insert(servers, {
                    id = sid,
                    name = name,
                    host = host,
                    port = port
                })
            end
        end
    end
    
    -- Сохраняем изменения
    uci:save("waytix")
    uci:commit("waytix")
    
    -- Обновляем конфиг Xray
    update_xray_config()
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json({
        success = true,
        message = string.format("Обновлено %d серверов", #servers),
        servers = servers
    })
end

-- Функция для переключения на указанный сервер
local function switch_server(server_id)
    local uci = require "luci.model.uci".cursor()
    
    -- Проверяем существование сервера
    if not uci:get("waytix", server_id) then
        return false, "Сервер не найден"
    end
    
    -- Обновляем выбранный сервер
    uci:set("waytix", "config", "waytix")
    uci:set("waytix", "config", "selected_server", server_id)
    uci:save("waytix")
    uci:commit("waytix")
    
    -- Обновляем конфиг Xray
    if not update_xray_config() then
        return false, "Ошибка обновления конфигурации Xray"
    end
    
    -- Перезапускаем Xray, если он запущен
    if sys.call("pidof xray >/dev/null") == 0 then
        sys.call("/etc/init.d/waytix restart >/dev/null 2>&1")
    end
    
    return true, "Сервер успешно изменен"
end

function action_toggle()
    local is_running = sys.call("pidof xray >/dev/null") == 0
    local result, message
    
    if is_running then
        result = sys.call("/etc/init.d/waytix stop >/dev/null 2>&1")
        message = "Сервис остановлен"
    else
        -- Проверяем, выбран ли сервер
        local selected = uci:get("waytix", "config", "selected_server")
        if not selected then
            http.status(400, "Bad Request")
            http.prepare_content("application/json")
            http.write_json({success = false, message = "Не выбран сервер для подключения"})
            return
        end
        
        -- Обновляем конфиг перед запуском
        if not update_xray_config() then
            http.status(500, "Internal Server Error")
            http.prepare_content("application/json")
            http.write_json({success = false, message = "Ошибка обновления конфигурации Xray"})
            return
        end
        
        result = sys.call("/etc/init.d/waytix start >/dev/null 2>&1")
        message = "Сервис запущен"
    end
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json({
        success = result == 0,
        message = result == 0 and message or "Ошибка выполнения операции",
        running = not is_running
    })
end

function action_update()
    local result = sys.call("/etc/waytix/update.sh >/tmp/waytix-update.log 2>&1 &")
    
    http.status(200, "OK")
    http.prepare_content("application/json")
    http.write_json({success = result == 0})
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
        inbounds = [{
            port = 1080,
            listen = "0.0.0.0",
            protocol = "socks",
            settings = {
                auth = "noauth",
                udp = true,
                ip = "127.0.0.1"
            }
        }],
        outbounds = [{
            protocol = "vless",
            settings = {
                vnext = [{
                    address = server.host,
                    port = server.port,
                    users = [{
                        id = server.uuid,
                        flow = server.flow ~= "" and server.flow or nil,
                        encryption = "none"
                    }]
                }]
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
